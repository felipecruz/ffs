//! Per-file search: open, read, skip binary files, find matching lines and
//! report them. `Searcher` is the visitor passed to `walk.walk`; `run` sets
//! up threads and the walk, and is shared by the CLI and the C API.
//!
//! Files are streamed through a fixed buffer, never loaded whole: a file is
//! skipped as binary as soon as a NUL byte shows up, and only complete lines
//! are searched (the partial last line is carried into the next read).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const match = @import("match.zig");
const regex = @import("regex.zig");
const walk = @import("walk.zig");

pub const Options = struct {
    root_path: []const u8,
    /// A literal, or the source of `regex`. Must not contain '\n'.
    term: []const u8,
    /// Worker threads.
    jobs: usize,
    /// ASCII case-insensitive matching.
    ignore_case: bool = false,
    /// Search for this compiled regex instead of the literal `term`.
    regex: ?*const regex.Regex = null,
};

/// The default thread count: the number of performance cores
/// (`hw.perflevel0.logicalcpu`) on Apple silicon, where more threads mostly
/// add kernel contention (EXPERIMENTS.md, Experiment 7). Elsewhere, every
/// logical CPU.
///
/// The old fallback was 4 everywhere, a number measured on Apple silicon: on
/// a 16-thread Linux box that cost 1.74x on the kernel fixture, because the
/// search keeps scaling well past 4 threads there (Experiment 15). 16 is the
/// widest machine measured, and it was still the fastest setting on the large
/// fixture; above that this is untested. Small trees peak a little earlier
/// (redis: 4.1 ms at `-j8` vs 5.4 ms at `-j16`), which is 1.3 ms, so the
/// large-tree setting wins the tradeoff.
pub fn autoJobs() usize {
    if (builtin.os.tag == .macos) {
        var n: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (std.c.sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, null, 0) == 0 and n > 0) return @intCast(n);
    }
    return std.Thread.getCpuCount() catch 4;
}

pub const Output = union(enum) {
    /// `<root>/<path>:<line>` lines (`:<content>` too with `content`).
    print: struct { file: Io.File, content: bool = false },
    /// One call per matching line; see `Callback`.
    callback: Callback,
};

/// Called once per matching line, never concurrently, with the lines of one
/// file in order and files never interleaved. Strings are valid only during
/// the call. Return false to stop the search.
pub const Callback = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, hit: Hit) bool,
};

pub const Hit = struct {
    path: []const u8, // relative to the root
    line: usize,
    text: []const u8, // the line, without '\n'
};

/// Searches every text file under `opts.root_path`.
pub fn run(gpa: std.mem.Allocator, opts: Options, output: Output) !void {
    // The calling thread only starts the root task and then waits in
    // `group.await`, so all searching happens on the `jobs` pool threads.
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(opts.jobs) });
    defer threaded.deinit();
    const io = threaded.io();

    var root = try Io.Dir.cwd().openDir(io, opts.root_path, .{ .iterate = true });
    defer root.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = switch (output) {
        .print => |p| .init(p.file, io, &buffer),
        .callback => undefined,
    };
    var searcher: Searcher = .{ .io = io, .gpa = gpa, .opts = opts, .output = output, .writer = &file_writer.interface };
    try walk.walk(io, gpa, root, &searcher, opts.jobs);
    if (output == .print) try file_writer.interface.flush();
}

pub const Searcher = struct {
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    output: Output,
    writer: *Io.Writer, // with `.print` only
    out_mutex: Io.Mutex = .init,
    stopped: std.atomic.Value(bool) = .init(false), // a callback returned false

    pub const read_size = 256 * 1024;

    /// Per-worker state, reused for every file that worker visits.
    pub const Local = struct {
        buf: []u8, // read buffer; grows only for lines longer than read_size
        matches: Io.Writer.Allocating, // current file's output (`.print`) or line texts (`.callback`)
        hits: std.ArrayList(Collected) = .empty, // with `.callback` only
        vm: ?regex.Vm, // regex scratch space, with a regex only
    };

    pub fn initLocal(s: *Searcher) !Local {
        return .{
            .buf = try s.gpa.alloc(u8, read_size),
            .matches = .init(s.gpa),
            .vm = if (s.opts.regex) |re| try regex.Vm.init(s.gpa, re) else null,
        };
    }

    pub fn deinitLocal(s: *Searcher, local: *Local) void {
        s.gpa.free(local.buf);
        local.matches.deinit();
        local.hits.deinit(s.gpa);
        if (local.vm) |*vm| vm.deinit(s.gpa);
    }

    pub fn visitFile(s: *Searcher, local: *Local, f: walk.File) !void {
        if (s.stopped.load(.monotonic)) return;
        // Unreadable files are skipped.
        const file = f.dir.openFile(s.io, f.name, .{}) catch return;
        defer file.close(s.io);

        local.matches.clearRetainingCapacity();
        local.hits.clearRetainingCapacity();
        const complete = switch (s.output) {
            .print => |p| try s.scan(local, file, PrintLine{
                .out = &local.matches.writer,
                .root_path = s.opts.root_path,
                .path = f.path,
                .content = p.content,
            }),
            .callback => try s.scan(local, file, Collect{ .gpa = s.gpa, .local = local }),
        };
        // Binary or unreadable: matches found so far are dropped.
        if (!complete or (local.matches.written().len == 0 and local.hits.items.len == 0)) return;

        // Report this file's matches in one piece so files never interleave.
        try s.out_mutex.lock(s.io);
        defer s.out_mutex.unlock(s.io);
        switch (s.output) {
            .print => try s.writer.writeAll(local.matches.written()),
            .callback => |cb| for (local.hits.items) |h| {
                if (s.stopped.load(.monotonic)) break;
                const text = local.matches.written()[h.start..][0..h.len];
                if (!cb.f(cb.ctx, .{ .path = f.path, .line = h.line, .text = text })) s.stopped.store(true, .monotonic);
            },
        }
    }

    // Streams the file through `local.buf`, passing complete lines to the
    // matcher. Returns false if the file is binary or can't be read.
    //
    // A read that returns less than asked for means end of file (the walker
    // only passes regular files), so a small file costs one read, not two.
    fn scan(s: *Searcher, local: *Local, file: Io.File, sink: anytype) !bool {
        var line: usize = 1; // line number of local.buf[0]
        var carried: usize = 0; // partial line kept at the front of local.buf
        var first_read = true;

        while (true) {
            if (carried == local.buf.len) {
                // A single line is longer than the buffer: grow it.
                local.buf = try s.gpa.realloc(local.buf, local.buf.len * 2);
            }
            const space = local.buf.len - carried;
            var n = file.readStreaming(s.io, &.{local.buf[carried..]}) catch |err| switch (err) {
                error.EndOfStream => {
                    // Last line has no trailing newline.
                    _ = try s.findLines(local, local.buf[0..carried], line, sink);
                    return true;
                },
                else => return false,
            };
            const eof = n < space;
            if (first_read and std.mem.startsWith(u8, local.buf[0..n], bom)) {
                // Like ripgrep, a UTF-8 byte-order mark is not part of line 1.
                std.mem.copyForwards(u8, local.buf[0 .. n - bom.len], local.buf[bom.len..n]);
                n -= bom.len;
            }
            first_read = false;
            const fresh = local.buf[carried..][0..n];
            // Text files only: a NUL byte anywhere means binary.
            if (std.mem.indexOfScalar(u8, fresh, 0) != null) return false;

            // Search up to the last newline, or everything at end of file.
            const filled = local.buf[0 .. carried + n];
            const cut = if (eof) filled.len else if (std.mem.findScalarLast(u8, filled, '\n')) |nl| nl + 1 else 0;
            line = try s.findLines(local, filled[0..cut], line, sink);
            if (eof) return true;

            const rest = filled[cut..];
            std.mem.copyForwards(u8, local.buf[0..rest.len], rest);
            carried = rest.len;
        }
    }

    fn findLines(s: *const Searcher, local: *Local, data: []const u8, first_line: usize, sink: anytype) !usize {
        if (s.opts.regex) |re| return regex.findLines(re, &local.vm.?, data, first_line, sink);
        if (s.opts.ignore_case) return match.findLinesIgnoreCase(data, s.opts.term, first_line, sink);
        return match.findLines(data, s.opts.term, first_line, sink);
    }
};

const bom = "\xef\xbb\xbf";

/// `.print` output: `<root>/<path>:<line>`, or `<root>/<path>:<line>:<content>`.
const PrintLine = struct {
    out: *Io.Writer,
    root_path: []const u8,
    path: []const u8,
    content: bool,

    pub fn onLine(p: PrintLine, m: match.Match) !void {
        if (p.content) {
            try p.out.print("{s}/{s}:{d}:{s}\n", .{ p.root_path, p.path, m.line, m.text() });
        } else {
            try p.out.print("{s}/{s}:{d}\n", .{ p.root_path, p.path, m.line });
        }
    }
};

/// `.callback` output: keeps the line number and a copy of the text until
/// the file is known not to be binary.
const Collected = struct { line: usize, start: usize, len: usize };

const Collect = struct {
    gpa: std.mem.Allocator,
    local: *Searcher.Local,

    pub fn onLine(c: Collect, m: match.Match) !void {
        const text = m.text();
        const start = c.local.matches.written().len;
        try c.local.matches.writer.writeAll(text);
        try c.local.hits.append(c.gpa, .{ .line = m.line, .start = start, .len = text.len });
    }
};
