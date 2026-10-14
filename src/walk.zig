//! Parallel recursive directory walk on `std.Io`.
//!
//! A fixed pool of `jobs` worker tasks shares one queue of work items: a
//! directory to read, or a batch of files to visit. Every worker both reads
//! directories and visits files, taking whatever is on the queue, so a
//! directory holding thousands of files no longer pins the one thread that
//! happened to find it (EXPERIMENTS.md, Experiment 15).
//!
//! Moving files to another thread costs a copy of their names, so a worker
//! pays that only while another worker is idle; otherwise it visits the files
//! it finds itself and allocates nothing. With `jobs = 1` nothing is ever
//! handed off and the walk is exactly depth-first.
//!
//! Symlinks and special files are skipped; unreadable directories are skipped
//! silently.
//!
//! The walker knows nothing about what is done with a file. A visitor is any
//! struct with:
//!
//!     pub const Local = ...;   // per-worker state
//!     pub fn initLocal(v: *Visitor) !Local
//!     pub fn deinitLocal(v: *Visitor, local: *Local) void
//!     pub fn visitFile(v: *Visitor, local: *Local, file: walk.File) !void
//!
//! `visitFile` is called concurrently from different workers, but one `Local`
//! belongs to one worker for the whole walk. That makes `Local` the place for
//! reusable buffers.

const std = @import("std");
const Io = std.Io;

/// Files per handed-off batch: enough that the hand-off (one `openDir`, one
/// name copy per file) is amortized, few enough that a directory of large
/// files still spreads over the workers.
pub const batch_len = 32;

pub const File = struct {
    /// Open handle of the directory containing the file.
    dir: Io.Dir,
    /// File name inside `dir`. Valid only during the `visitFile` call.
    name: []const u8,
    /// Path relative to the walk root. Valid only during the `visitFile` call.
    path: []const u8,
};

/// Walks every regular file under `root` (opened with `.iterate = true`) and
/// calls `visitor.visitFile` for each, on `jobs` worker tasks. Returns when
/// the whole tree has been walked.
pub fn walk(io: Io, gpa: std.mem.Allocator, root: Io.Dir, visitor: anytype, jobs: usize) !void {
    const W = Walker(@typeInfo(@TypeOf(visitor)).pointer.child);
    var w: W = .{ .io = io, .gpa = gpa, .root = root, .visitor = visitor };
    defer w.deinit();

    try w.push(.{ .dir = "" }); // the root; the only item whose path is not owned

    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..@max(jobs, 1)) |_| group.async(io, W.work, .{&w});
    try group.await(io);
}

fn Walker(comptime Visitor: type) type {
    return struct {
        const Self = @This();

        io: Io,
        gpa: std.mem.Allocator,
        root: Io.Dir,
        visitor: *Visitor,

        mutex: Io.Mutex = .init,
        /// Signaled when an item is queued, and broadcast when the last one
        /// is finished.
        ready: Io.Condition = .init,
        /// Queued work, taken from the end: deepest directory first, which
        /// keeps the queue short.
        items: std.ArrayList(Item) = .empty,
        /// Items queued but not yet finished. Zero means the walk is over.
        pending: usize = 0,
        /// Workers waiting in `next`. Read without the mutex, so only a hint:
        /// a worker that just went idle may be missed, and the files are then
        /// visited by the worker that found them.
        idle: std.atomic.Value(usize) = .init(0),

        const Item = union(enum) {
            /// Directory to read, relative to root ("" for the root itself).
            dir: []const u8,
            /// Files to visit, all in the same directory.
            files: struct { rel: []const u8, names: []const []const u8 },
        };

        fn deinit(w: *Self) void {
            for (w.items.items) |item| w.freeItem(item);
            w.items.deinit(w.gpa);
        }

        fn freeItem(w: *Self, item: Item) void {
            switch (item) {
                .dir => |rel| w.freeRel(rel),
                .files => |f| {
                    for (f.names) |name| w.gpa.free(name);
                    w.gpa.free(f.names);
                    w.freeRel(f.rel);
                },
            }
        }

        fn freeRel(w: *Self, rel: []const u8) void {
            if (rel.len > 0) w.gpa.free(rel); // the root's "" is a literal
        }

        fn push(w: *Self, item: Item) !void {
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            try w.items.append(w.gpa, item);
            w.pending += 1;
            w.ready.signal(w.io);
        }

        // Returns null once every queued item has been finished.
        fn next(w: *Self) Io.Cancelable!?Item {
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            while (w.items.items.len == 0) {
                if (w.pending == 0) return null;
                _ = w.idle.fetchAdd(1, .monotonic);
                defer _ = w.idle.fetchSub(1, .monotonic);
                try w.ready.wait(w.io, &w.mutex); // returns holding the mutex
            }
            return w.items.pop();
        }

        fn finish(w: *Self) void {
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            w.pending -= 1;
            if (w.pending == 0) w.ready.broadcast(w.io); // wake the idle workers to exit
        }

        // One worker: its own `Local`, then items until the queue runs dry.
        fn work(w: *Self) Io.Cancelable!void {
            var local = w.visitor.initLocal() catch |err| {
                std.log.err("worker: {t}", .{err});
                return;
            };
            defer w.visitor.deinitLocal(&local);

            while (try w.next()) |item| {
                defer {
                    w.freeItem(item);
                    w.finish();
                }
                w.process(&local, item) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => std.log.err("{s}: {t}", .{ w.itemPath(item), err }),
                };
            }
        }

        fn itemPath(_: *Self, item: Item) []const u8 {
            const rel = switch (item) {
                .dir => |d| d,
                .files => |f| f.rel,
            };
            return if (rel.len == 0) "." else rel;
        }

        fn process(w: *Self, local: *Visitor.Local, item: Item) !void {
            switch (item) {
                .dir => |rel| try w.readDir(local, rel),
                .files => |f| try w.visitFiles(local, f.rel, f.names),
            }
        }

        fn readDir(w: *Self, local: *Visitor.Local, rel: []const u8) !void {
            var dir = w.root.openDir(w.io, if (rel.len == 0) "." else rel, .{ .iterate = true }) catch return;
            defer dir.close(w.io);

            var handoff: std.ArrayList([]const u8) = .empty; // names for an idle worker
            defer w.freeNames(&handoff);

            var path: std.ArrayList(u8) = .empty; // "<rel>/<name>"
            defer path.deinit(w.gpa);

            var it = dir.iterate();
            while (it.next(w.io) catch return) |entry| {
                switch (entry.kind) {
                    .directory => try w.pushDir(rel, entry.name),
                    .file => if (w.idle.load(.monotonic) > 0) {
                        try handoff.append(w.gpa, try w.gpa.dupe(u8, entry.name));
                        if (handoff.items.len >= batch_len) try w.pushFiles(rel, &handoff);
                    } else {
                        try w.visitOne(local, dir, rel, &path, entry.name);
                    },
                    else => {},
                }
            }
            if (handoff.items.len > 0) try w.pushFiles(rel, &handoff);
        }

        fn visitFiles(w: *Self, local: *Visitor.Local, rel: []const u8, names: []const []const u8) !void {
            // The worker that found these files has long since closed its
            // handle on their directory, so open it again.
            var dir = if (rel.len == 0) w.root else w.root.openDir(w.io, rel, .{}) catch return;
            defer if (rel.len > 0) dir.close(w.io);

            var path: std.ArrayList(u8) = .empty;
            defer path.deinit(w.gpa);

            for (names) |n| try w.visitOne(local, dir, rel, &path, n);
        }

        fn visitOne(
            w: *Self,
            local: *Visitor.Local,
            dir: Io.Dir,
            rel: []const u8,
            path: *std.ArrayList(u8),
            file_name: []const u8,
        ) !void {
            path.clearRetainingCapacity();
            if (rel.len > 0) {
                try path.appendSlice(w.gpa, rel);
                try path.append(w.gpa, '/');
            }
            try path.appendSlice(w.gpa, file_name);
            try w.visitor.visitFile(local, .{ .dir = dir, .name = file_name, .path = path.items });
        }

        fn pushDir(w: *Self, rel: []const u8, child_name: []const u8) !void {
            const child = try joinPath(w.gpa, rel, child_name);
            errdefer w.gpa.free(child);
            try w.push(.{ .dir = child });
        }

        // Hands `names` to the queue; leaves it empty, ready to refill.
        fn pushFiles(w: *Self, rel: []const u8, names: *std.ArrayList([]const u8)) !void {
            const owned = try names.toOwnedSlice(w.gpa);
            errdefer {
                for (owned) |n| w.gpa.free(n);
                w.gpa.free(owned);
            }
            const rel_owned = if (rel.len == 0) rel else try w.gpa.dupe(u8, rel);
            errdefer w.freeRel(rel_owned);
            try w.push(.{ .files = .{ .rel = rel_owned, .names = owned } });
        }

        fn freeNames(w: *Self, names: *std.ArrayList([]const u8)) void {
            for (names.items) |n| w.gpa.free(n);
            names.deinit(w.gpa);
        }
    };
}

fn joinPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}
