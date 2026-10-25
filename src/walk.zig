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
//! silently. A `Filter` leaves out more, as ripgrep does by default: hidden
//! entries, paths matched by ignore files, `-g` globs and a maximum depth.
//! Each directory item carries the ignore rules that apply to it, as a chain
//! of `IgnoreDir`s from the innermost directory with an ignore file outward.
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
const glob = @import("glob.zig");

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

/// Which entries to leave out. The default leaves out nothing.
pub const Filter = struct {
    /// Visit entries whose name starts with '.'.
    hidden: bool = true,
    /// Honor .ignore and .rgignore files, in each directory and the root's
    /// parents, and .gitignore and .git/info/exclude too inside a git repo.
    ignore_files: bool = false,
    /// With `ignore_files`: also the git ones.
    vcs_ignore: bool = true,
    /// `-g` globs. As in rg, they match the path as printed: `glob_prefix`
    /// (the root as given, without "./"), a '/', and the path from the root.
    globs: ?*const glob.RuleSet = null,
    glob_prefix: []const u8 = "",
    /// `-t`/`-T` file types, as rules on the file name: a selected type
    /// includes, a negated one ignores. With any selected, a file of no
    /// selected type is left out. Directories are never filtered by type.
    types: ?*const glob.RuleSet = null,
    /// Entries deeper than this are left out; the root's entries are at depth 1.
    max_depth: ?usize = null,
};

/// Ignore rules from the files in one directory. `parent` holds the rules of
/// the next directory up that has any; rules nearer the file win.
const IgnoreDir = struct {
    parent: ?*const IgnoreDir,
    /// The directory, relative to the walk root ("" for the root itself).
    rel: []const u8,
    /// For a directory above the root: the root's path relative to it.
    above: ?[]const u8 = null,
    rules: glob.RuleSet,
};

/// Walks every regular file under `root` (opened with `.iterate = true`) and
/// calls `visitor.visitFile` for each, on `jobs` worker tasks. Returns when
/// the whole tree has been walked, or the first error a worker hit (out of
/// memory, or one from `visitFile`), once every worker has stopped.
pub fn walk(io: Io, gpa: std.mem.Allocator, root: Io.Dir, visitor: anytype, jobs: usize, filter: Filter) !void {
    const W = Walker(@typeInfo(@TypeOf(visitor)).pointer.child);
    var w: W = .{ .io = io, .gpa = gpa, .root = root, .visitor = visitor, .filter = filter, .arena = .init(gpa) };
    defer w.deinit();

    var top: Dir = .{ .rel = "" }; // the root; the only item whose path is not owned
    if (filter.ignore_files) try w.loadAncestors(&top);
    try w.push(.{ .dir = top });

    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..@max(jobs, 1)) |_| group.async(io, W.work, .{&w});
    try group.await(io);
    if (w.err) |err| return err;
}

fn Walker(comptime Visitor: type) type {
    return struct {
        const Self = @This();

        io: Io,
        gpa: std.mem.Allocator,
        root: Io.Dir,
        visitor: *Visitor,
        filter: Filter,
        /// `IgnoreDir`s, for the whole walk. Guarded by `mutex`.
        arena: std.heap.ArenaAllocator,
        /// The root holds .git.
        root_is_repo: bool = false,

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
        /// The first error a worker hit; the others then stop. Guarded by
        /// `mutex`.
        err: ?anyerror = null,

        const Item = union(enum) {
            dir: Dir,
            /// Files to visit, all in the same directory.
            files: struct { rel: []const u8, names: []const []const u8 },
        };

        fn deinit(w: *Self) void {
            for (w.items.items) |item| w.freeItem(item);
            w.items.deinit(w.gpa);
            w.arena.deinit();
        }

        fn freeItem(w: *Self, item: Item) void {
            switch (item) {
                .dir => |d| w.freeRel(d.rel),
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
            while (w.items.items.len == 0 or w.err != null) {
                if (w.pending == 0 or w.err != null) return null;
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

        // Records the first error and wakes the idle workers to stop. The
        // items left in the queue are freed by `deinit`.
        fn fail(w: *Self, err: anyerror) void {
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            if (w.err == null) w.err = err;
            w.ready.broadcast(w.io);
        }

        // One worker: its own `Local`, then items until the queue runs dry.
        fn work(w: *Self) Io.Cancelable!void {
            var local = w.visitor.initLocal() catch |err| return w.fail(err);
            defer w.visitor.deinitLocal(&local);

            while (try w.next()) |item| {
                defer {
                    w.freeItem(item);
                    w.finish();
                }
                w.process(&local, item) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return w.fail(err),
                };
            }
        }

        fn process(w: *Self, local: *Visitor.Local, item: Item) !void {
            switch (item) {
                .dir => |d| try w.readDir(local, d),
                .files => |f| try w.visitFiles(local, f.rel, f.names),
            }
        }

        fn readDir(w: *Self, local: *Visitor.Local, d: Dir) !void {
            const rel = d.rel;
            var dir = w.root.openDir(w.io, if (rel.len == 0) "." else rel, .{ .iterate = true }) catch return;
            defer dir.close(w.io);

            var sub: Dir = .{ .rel = undefined, .ign = d.ign, .git = d.git, .depth = d.depth + 1 };
            if (w.filter.ignore_files) {
                // A repository inside the tree starts using its git ignores here.
                const repo_root = (rel.len == 0 and w.root_is_repo) or
                    (!d.git and w.filter.vcs_ignore and exists(w.io, dir, ".git"));
                sub.git = sub.git or repo_root;
                sub.ign = try w.loadIgnores(dir, .{ .rel = rel, .git = sub.git, .repo_root = repo_root }, sub.ign);
            }
            const max_depth = w.filter.max_depth orelse std.math.maxInt(usize);
            const check_path = sub.ign != null or w.filter.globs != null;

            var handoff: std.ArrayList([]const u8) = .empty; // names for an idle worker
            defer w.freeNames(&handoff);

            var path: std.ArrayList(u8) = .empty; // "<rel>/<name>"
            defer path.deinit(w.gpa);
            var glob_path: std.ArrayList(u8) = .empty; // "<glob_prefix>/<rel>/<name>"
            defer glob_path.deinit(w.gpa);

            var it = dir.iterate();
            while (it.next(w.io) catch return) |entry| {
                if (entry.kind != .directory and entry.kind != .file) continue;
                const is_dir = entry.kind == .directory;
                if (sub.depth > max_depth or (is_dir and sub.depth == max_depth)) continue;
                if (check_path) try setPath(w.gpa, &path, rel, entry.name);
                // As in rg: a glob decides alone. Otherwise the ignore files,
                // then the file types, can each leave the entry out; and an
                // entry one of them includes (a '!' line, a selected type)
                // skips the hidden check, so it beats a leading dot.
                filter: {
                    if (w.filter.globs) |g| switch (g.decide(try w.globPath(&glob_path, path.items), is_dir)) {
                        .ignore => continue,
                        .include => break :filter,
                        .none => if (!is_dir and g.any_include) continue,
                    };
                    var included = false;
                    if (sub.ign) |ign| switch (ignored(ign, path.items, is_dir)) {
                        .ignore => continue,
                        .include => included = true,
                        .none => {},
                    };
                    if (!is_dir) if (w.filter.types) |t| switch (t.decide(entry.name, false)) {
                        .ignore => continue,
                        .include => included = true,
                        .none => if (t.any_include) continue,
                    };
                    if (!included and !w.filter.hidden and entry.name[0] == '.') continue;
                }
                switch (entry.kind) {
                    .directory => try w.pushDir(sub, rel, entry.name),
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
            try setPath(w.gpa, path, rel, file_name);
            try w.visitor.visitFile(local, .{ .dir = dir, .name = file_name, .path = path.items });
        }

        fn pushDir(w: *Self, sub: Dir, rel: []const u8, child_name: []const u8) !void {
            var child = sub;
            child.rel = try joinPath(w.gpa, rel, child_name);
            errdefer w.gpa.free(child.rel);
            try w.push(.{ .dir = child });
        }

        fn globPath(w: *Self, buf: *std.ArrayList(u8), path: []const u8) ![]const u8 {
            if (w.filter.glob_prefix.len == 0) return path;
            try setPath(w.gpa, buf, w.filter.glob_prefix, path);
            return buf.items;
        }

        // What the ignore files say about `path` (relative to the root): the
        // innermost directory with a matching rule decides.
        fn ignored(chain: *const IgnoreDir, path: []const u8, is_dir: bool) glob.Decision {
            var node: ?*const IgnoreDir = chain;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            while (node) |n| : (node = n.parent) {
                const local = if (n.above) |above|
                    std.fmt.bufPrint(&buf, "{s}/{s}", .{ above, path }) catch continue
                else if (n.rel.len == 0) path else path[n.rel.len + 1 ..];
                const d = n.rules.decide(local, is_dir);
                if (d != .none) return d;
            }
            return .none;
        }

        // Reads the ignore files in `dir` and returns the chain to use below
        // it: a new `IgnoreDir` on top of `parent`, or `parent` if there are
        // none. In a repository root, .git/info/exclude is read first, so it
        // loses to the rest.
        fn loadIgnores(w: *Self, dir: Io.Dir, at: Location, parent: ?*const IgnoreDir) !?*const IgnoreDir {
            const vcs = at.git and w.filter.vcs_ignore;
            const names = [_][]const u8{ ".git/info/exclude", ".gitignore", ".ignore", ".rgignore" };
            var contents: [names.len]?[]u8 = @splat(null);
            defer for (contents) |c| if (c) |bytes| w.gpa.free(bytes);
            var any = false;
            for (names, 0..) |name, k| {
                if (k == 0 and !(vcs and at.repo_root)) continue;
                if (k == 1 and !vcs) continue;
                contents[k] = dir.readFileAlloc(w.io, name, w.gpa, .limited(1 << 20)) catch null;
                any = any or contents[k] != null;
            }
            if (!any) return parent;

            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            const a = w.arena.allocator();
            const node = try a.create(IgnoreDir);
            node.* = .{
                .parent = parent,
                .rel = try a.dupe(u8, at.rel),
                .above = if (at.above) |above| try a.dupe(u8, above) else null,
                .rules = .{},
            };
            for (contents) |c| if (c) |bytes| try node.rules.addIgnoreFile(a, bytes);
            return node;
        }

        const Location = struct {
            rel: []const u8 = "",
            above: ?[]const u8 = null,
            git: bool,
            repo_root: bool = false,
        };

        // The ignore files of the directories above the root: .ignore and
        // .rgignore all the way up, the git ones up to the repository root.
        fn loadAncestors(w: *Self, top: *Dir) !void {
            var real_buf: [std.fs.max_path_bytes]u8 = undefined;
            const real = real_buf[0 .. w.root.realPath(w.io, &real_buf) catch return];
            w.root_is_repo = exists(w.io, w.root, ".git");

            // Ancestors, nearest first, with the nearest one holding .git.
            var ancestors: std.ArrayList([]const u8) = .empty;
            defer ancestors.deinit(w.gpa);
            var p: []const u8 = real;
            while (std.fs.path.dirname(p)) |parent| : (p = parent) try ancestors.append(w.gpa, parent);
            var repo: ?usize = null;
            if (!w.root_is_repo) for (ancestors.items, 0..) |anc, k| {
                var d = Io.Dir.openDirAbsolute(w.io, anc, .{}) catch continue;
                defer d.close(w.io);
                if (exists(w.io, d, ".git")) {
                    repo = k;
                    break;
                }
            };
            top.git = w.root_is_repo or repo != null;

            // Outermost first, so each node's parent is the one above it.
            var chain: ?*const IgnoreDir = null;
            var k = ancestors.items.len;
            while (k > 0) {
                k -= 1;
                const anc = ancestors.items[k];
                var d = Io.Dir.openDirAbsolute(w.io, anc, .{}) catch continue;
                defer d.close(w.io);
                chain = try w.loadIgnores(d, .{
                    .above = std.mem.trimStart(u8, real[anc.len..], "/"),
                    .git = if (repo) |r| k <= r else false,
                    .repo_root = repo == k,
                }, chain);
            }
            top.ign = chain;
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

/// A directory to read.
const Dir = struct {
    /// Relative to root ("" for the root itself).
    rel: []const u8,
    /// Ignore rules that apply inside it, from the directories above.
    ign: ?*const IgnoreDir = null,
    /// Inside a git repository: .gitignore files count.
    git: bool = false,
    /// The root is at depth 0.
    depth: usize = 0,
};

fn exists(io: Io, dir: Io.Dir, name: []const u8) bool {
    _ = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return true;
}

// path = "<rel>/<name>", or just name at the root.
fn setPath(gpa: std.mem.Allocator, path: *std.ArrayList(u8), rel: []const u8, name: []const u8) !void {
    path.clearRetainingCapacity();
    if (rel.len > 0) {
        try path.appendSlice(gpa, rel);
        try path.append(gpa, '/');
    }
    try path.appendSlice(gpa, name);
}

fn joinPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}
