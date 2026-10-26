//! Per-file search: open, read, skip binary files, find matching lines and
//! report them. `Searcher` is the visitor passed to `walk.walk`; `run` sets
//! up threads and the walk, and is shared by the CLI and the C API.
//!
//! Files are streamed through a fixed buffer, never loaded whole: a file is
//! skipped as binary as soon as a NUL byte shows up, and only complete lines
//! are searched (the partial last line is carried into the next read).
//! Context lines (`-A`/`-B`/`-C`) and `-v` need the lines around a match, so
//! with those a file is read whole first.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const match = @import("match.zig");
const regex = @import("regex.zig");
const walk = @import("walk.zig");

pub const Options = struct {
    /// Directories (walked), files, or "-" for standard input. Empty: the
    /// current directory, printed without a "./" prefix.
    paths: []const []const u8 = &.{},
    /// A literal, or the source of `regex`. Must not contain '\n'.
    term: []const u8,
    /// Worker threads.
    jobs: usize,
    /// ASCII case-insensitive matching.
    ignore_case: bool = false,
    /// Search for this compiled regex instead of the literal `term`.
    regex: ?*const regex.Regex = null,
    /// Which files a directory walk visits.
    filter: walk.Filter = .{},
    /// Report the lines that do not match.
    invert: bool = false,
    /// Stop reading a file after this many reported lines.
    max_count: ?usize = null,
    /// Search files with NUL bytes too, instead of skipping them as binary.
    binary: bool = false,
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
    /// ripgrep's output; see `Print`.
    print: Print,
    /// One call per matching line; see `Callback`.
    callback: Callback,
};

/// ripgrep's format for a pipe: `<path>:<line>:<text>`, the path and the
/// line number each optional; context lines use '-' instead of ':', and
/// `--` separates groups of lines that are not adjacent.
pub const Print = struct {
    file: Io.File,
    mode: Mode = .lines,
    line_number: bool = false,
    /// null: on, unless the only path is a file or standard input.
    with_filename: ?bool = null,
    before: usize = 0,
    after: usize = 0,
    /// `--json`: matching (and context) lines as ripgrep's JSON Lines
    /// messages, with `begin`/`end` around each file and a `summary` last.
    /// Only for `.lines` and `.only_matching`, which then print whole lines.
    json: bool = false,
    /// `-q` with `--json`: no messages but the `summary`, as in rg.
    summary_only: bool = false,
    /// `--null`: a NUL byte after each path instead of ':' (or '\n').
    null_sep: bool = false,
    /// `--max-columns`: lines longer than this, newline included, are
    /// printed as "[Omitted long matching line]" (or "... context line").
    max_columns: ?usize = null,

    pub const Mode = enum {
        lines,
        /// `-o`: each match on its own line.
        only_matching,
        /// `-c`: matching lines per file.
        count,
        /// `-l`: the files with a match.
        files_with_matches,
        /// `-q`: nothing; stop at the first match.
        quiet,
        /// `--files`: every file that would be searched.
        files,
    };

    fn context(p: Print) bool {
        return (p.mode == .lines or (p.json and p.mode == .only_matching)) and (p.before > 0 or p.after > 0);
    }

    // What ends a path: a NUL with `--null`, else `sep`.
    fn afterPath(p: Print, sep: u8) u8 {
        return if (p.null_sep) 0 else sep;
    }
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

pub const Result = struct {
    /// Some line was reported (some file listed, with `--files`).
    matched: bool,
    /// Some path could not be searched; a message went to stderr.
    errors: bool,
};

/// Searches every path in `opts.paths`. Paths that can't be opened are
/// reported on stderr and counted in `Result.errors`, except with the
/// callback output, where the first one is returned as an error.
pub fn run(gpa: std.mem.Allocator, opts: Options, output: Output) !Result {
    // The calling thread only starts the root task and then waits in
    // `group.await`, so all searching happens on the `jobs` pool threads.
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(opts.jobs) });
    defer threaded.deinit();
    const io = threaded.io();

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = switch (output) {
        .print => |p| .init(p.file, io, &buffer),
        .callback => undefined,
    };
    var searcher: Searcher = .{ .io = io, .gpa = gpa, .opts = opts, .output = output, .writer = &file_writer.interface };
    defer if (output == .print) file_writer.interface.flush() catch {};
    const started: Io.Timestamp = .now(io, .awake);

    const cwd: []const []const u8 = &.{"."};
    const paths = if (opts.paths.len == 0) cwd else opts.paths;
    var single_file = paths.len == 1;
    // Searched on this thread, after the walks: a few files don't need the pool.
    var local: ?Searcher.Local = null;
    defer if (local) |*l| searcher.deinitLocal(l);

    // rg prints no file names when the only path is a file.
    if (single_file and !std.mem.eql(u8, paths[0], "-")) {
        const st = Io.Dir.cwd().statFile(io, paths[0], .{}) catch null;
        single_file = st != null and st.?.kind != .directory;
    }
    if (output == .print) searcher.with_filename = output.print.with_filename orelse !single_file;

    for (paths) |path| {
        if (searcher.stopped.load(.monotonic)) break;
        if (std.mem.eql(u8, path, "-")) {
            if (local == null) local = try searcher.initLocal();
            try searcher.searchFile(&local.?, Io.File.stdin(), .{ .path = "<stdin>" });
            continue;
        }
        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                if (output == .callback) return err; // the C API takes directories only
                if (local == null) local = try searcher.initLocal();
                const file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
                    try searcher.reportError(path, e);
                    continue;
                };
                defer file.close(io);
                try searcher.searchFile(&local.?, file, .{ .path = path });
                continue;
            },
            else => {
                try searcher.reportError(path, err);
                continue;
            },
        };
        defer dir.close(io);
        // No path given: "src/x.zig", not "./src/x.zig".
        searcher.prefix = if (opts.paths.len == 0) "" else path;
        searcher.slash = searcher.prefix.len > 0 and searcher.prefix[searcher.prefix.len - 1] != '/';
        var filter = opts.filter;
        filter.glob_prefix = globPrefix(searcher.prefix);
        try walk.walk(io, gpa, dir, &searcher, opts.jobs, filter);
    }
    if (output == .print and output.print.json) try searcher.stats.summary(searcher.writer, nanosSince(io, started));
    return .{ .matched = searcher.matched.load(.monotonic), .errors = searcher.errors };
}

fn nanosSince(io: Io, t: Io.Timestamp) u64 {
    return @intCast(@max(0, t.untilNow(io, .awake).toNanoseconds()));
}

/// `--json` statistics, as in ripgrep's `end` and `summary` messages.
const Stats = struct {
    searches: std.atomic.Value(u64) = .init(0),
    searches_with_match: std.atomic.Value(u64) = .init(0),
    bytes_searched: std.atomic.Value(u64) = .init(0),
    bytes_printed: std.atomic.Value(u64) = .init(0),
    matched_lines: std.atomic.Value(u64) = .init(0),
    matches: std.atomic.Value(u64) = .init(0),
    elapsed: std.atomic.Value(u64) = .init(0), // nanoseconds, summed over files

    fn add(st: *Stats, f: FileStats) void {
        _ = st.searches.fetchAdd(1, .monotonic);
        if (f.matched_lines > 0) _ = st.searches_with_match.fetchAdd(1, .monotonic);
        _ = st.bytes_searched.fetchAdd(f.bytes_searched, .monotonic);
        _ = st.bytes_printed.fetchAdd(f.bytes_printed, .monotonic);
        _ = st.matched_lines.fetchAdd(f.matched_lines, .monotonic);
        _ = st.matches.fetchAdd(f.matches, .monotonic);
        _ = st.elapsed.fetchAdd(f.elapsed, .monotonic);
    }

    // ripgrep's last message; its keys come sorted.
    fn summary(st: *Stats, out: *Io.Writer, total: u64) !void {
        try out.writeAll("{\"data\":{\"elapsed_total\":");
        try jsonDuration(out, total, true);
        try out.print(",\"stats\":{{\"bytes_printed\":{d},\"bytes_searched\":{d},\"elapsed\":", .{ st.bytes_printed.load(.monotonic), st.bytes_searched.load(.monotonic) });
        try jsonDuration(out, st.elapsed.load(.monotonic), true);
        try out.print(",\"matched_lines\":{d},\"matches\":{d},\"searches\":{d},\"searches_with_match\":{d}}}}},\"type\":\"summary\"}}\n", .{
            st.matched_lines.load(.monotonic), st.matches.load(.monotonic), st.searches.load(.monotonic), st.searches_with_match.load(.monotonic),
        });
    }
};

const FileStats = struct {
    bytes_searched: u64 = 0,
    bytes_printed: u64 = 0,
    matched_lines: u64 = 0,
    matches: u64 = 0,
    elapsed: u64 = 0,
};

// A duration as ripgrep writes it: whole seconds, the nanoseconds left, and
// seconds with 6 decimals. In `summary` the keys are sorted.
fn jsonDuration(out: *Io.Writer, ns: u64, sorted: bool) !void {
    const secs = ns / std.time.ns_per_s;
    const nanos = ns % std.time.ns_per_s;
    const human = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    if (sorted) {
        try out.print("{{\"human\":\"{d:.6}s\",\"nanos\":{d},\"secs\":{d}}}", .{ human, nanos, secs });
    } else {
        try out.print("{{\"secs\":{d},\"nanos\":{d},\"human\":\"{d:.6}s\"}}", .{ secs, nanos, human });
    }
}

// Bytes as a JSON value, as ripgrep writes them: {"text":"..."} if they are
// valid UTF-8, else {"bytes":"<base64>"}.
fn jsonData(out: *Io.Writer, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try out.writeAll("{\"text\":");
        try jsonString(out, bytes);
        try out.writeByte('}');
    } else {
        try out.writeAll("{\"bytes\":\"");
        try std.base64.standard.Encoder.encodeWriter(out, bytes);
        try out.writeAll("\"}");
    }
}

// A JSON string, escaped as serde_json (ripgrep) does: '"', '\\' and the
// control characters, with the short forms where JSON has them.
fn jsonString(out: *Io.Writer, str: []const u8) !void {
    try out.writeByte('"');
    var start: usize = 0;
    for (str, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (esc == null and c >= 0x20) continue;
        try out.writeAll(str[start..i]);
        if (esc) |e| try out.writeAll(e) else try out.print("\\u{x:0>4}", .{c});
        start = i + 1;
    }
    try out.writeAll(str[start..]);
    try out.writeByte('"');
}

// The root as `-g` globs see it: "./a/" is "a", and "." is "".
fn globPrefix(root: []const u8) []const u8 {
    var p = root;
    while (true) {
        p = std.mem.trimEnd(u8, p, "/");
        if (std.mem.eql(u8, p, ".")) return "";
        if (!std.mem.startsWith(u8, p, "./")) return p;
        p = std.mem.trimStart(u8, p[2..], "/");
    }
}

/// A path as printed: `prefix`, a '/' if `slash`, then `path`.
const Name = struct {
    prefix: []const u8 = "",
    slash: bool = false,
    path: []const u8,

    fn write(n: Name, out: *Io.Writer) !void {
        try out.writeAll(n.prefix);
        if (n.slash) try out.writeByte('/');
        try out.writeAll(n.path);
    }
};

const Done = error{Done};

pub const Searcher = struct {
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    output: Output,
    writer: *Io.Writer, // with `.print` only
    out_mutex: Io.Mutex = .init,
    stopped: std.atomic.Value(bool) = .init(false), // a callback returned false, or -q matched
    matched: std.atomic.Value(bool) = .init(false),
    errors: bool = false,
    /// The walk root as printed before each path (see `Name`).
    prefix: []const u8 = "",
    slash: bool = false,
    with_filename: bool = true,
    /// With context lines: something was printed, so the next file's first
    /// group needs a `--` before it. Guarded by `out_mutex`.
    printed_group: bool = false,
    /// With `--json`.
    stats: Stats = .{},

    pub const read_size = 256 * 1024;

    /// Per-worker state, reused for every file that worker visits.
    pub const Local = struct {
        buf: []u8, // read buffer; grows only for lines longer than read_size
        matches: Io.Writer.Allocating, // current file's output (`.print`) or line texts (`.callback`)
        hits: std.ArrayList(Collected) = .empty, // with `.callback` only
        vm: ?regex.Vm, // regex scratch space, with a regex only
        /// The file offset of buf[0], and the bytes read so far, for `--json`.
        offset: usize = 0,
        read: usize = 0,
        json_path: Io.Writer.Allocating, // the current file's path as JSON
    };

    pub fn initLocal(s: *Searcher) !Local {
        return .{
            .buf = try s.gpa.alloc(u8, read_size),
            .matches = .init(s.gpa),
            .json_path = .init(s.gpa),
            .vm = if (s.opts.regex) |re| try regex.Vm.init(s.gpa, re) else null,
        };
    }

    pub fn deinitLocal(s: *Searcher, local: *Local) void {
        s.gpa.free(local.buf);
        local.matches.deinit();
        local.json_path.deinit();
        local.hits.deinit(s.gpa);
        if (local.vm) |*vm| vm.deinit(s.gpa);
    }

    pub fn visitFile(s: *Searcher, local: *Local, f: walk.File) !void {
        if (s.stopped.load(.monotonic)) return;
        const name: Name = .{ .prefix = s.prefix, .slash = s.slash, .path = f.path };
        if (s.output == .print and s.output.print.mode == .files) {
            local.matches.clearRetainingCapacity();
            try name.write(&local.matches.writer);
            try local.matches.writer.writeByte(s.output.print.afterPath('\n'));
            s.matched.store(true, .monotonic);
            return s.flush(local, name);
        }
        // Unreadable files are skipped.
        const file = f.dir.openFile(s.io, f.name, .{}) catch return;
        defer file.close(s.io);
        try s.searchFile(local, file, name);
    }

    fn reportError(s: *Searcher, path: []const u8, err: anyerror) !void {
        s.errors = true;
        if (s.output == .callback) return err;
        const msg = switch (err) {
            error.FileNotFound => "No such file or directory (os error 2)",
            error.AccessDenied, error.PermissionDenied => "Permission denied (os error 13)",
            else => @errorName(err),
        };
        try s.writer.flush(); // keep stdout and stderr in order on a terminal
        std.debug.print("ffs: {s}: {s}\n", .{ path, msg });
    }

    fn searchFile(s: *Searcher, local: *Local, file: Io.File, name: Name) !void {
        if (s.output == .print and s.output.print.mode == .files) {
            local.matches.clearRetainingCapacity();
            try name.write(&local.matches.writer);
            try local.matches.writer.writeByte(s.output.print.afterPath('\n'));
            s.matched.store(true, .monotonic);
            return s.flush(local, name);
        }
        local.matches.clearRetainingCapacity();
        local.hits.clearRetainingCapacity();
        const complete = switch (s.output) {
            .print => |p| blk: {
                const started: ?Io.Timestamp = if (p.json) .now(s.io, .awake) else null;
                var printer: Printer = .{ .s = s, .p = p, .out = &local.matches.writer, .local = local, .vm = if (local.vm) |*vm| vm else null, .name = name, .with_filename = s.with_filename };
                const ok = try s.scan(local, file, p.context() or s.opts.invert, &printer);
                if (ok) try printer.finish(if (started) |t| nanosSince(s.io, t) else 0);
                if (printer.count > 0) s.matched.store(true, .monotonic);
                if (p.json) s.stats.add(if (ok) printer.file_stats else .{});
                break :blk ok;
            },
            .callback => try s.scan(local, file, s.opts.invert, Collect{ .gpa = s.gpa, .local = local }),
        };
        // Binary or unreadable: matches found so far are dropped.
        if (!complete or (local.matches.written().len == 0 and local.hits.items.len == 0)) return;
        if (s.output == .callback) s.matched.store(true, .monotonic);
        try s.flush(local, name);
    }

    // Reports this file's output in one piece so files never interleave.
    fn flush(s: *Searcher, local: *Local, name: Name) !void {
        try s.out_mutex.lock(s.io);
        defer s.out_mutex.unlock(s.io);
        switch (s.output) {
            .print => |p| {
                if (p.context() and !p.json) {
                    if (s.printed_group) try s.writer.writeAll("--\n");
                    s.printed_group = true;
                }
                try s.writer.writeAll(local.matches.written());
            },
            .callback => |cb| for (local.hits.items) |h| {
                if (s.stopped.load(.monotonic)) break;
                const text = local.matches.written()[h.start..][0..h.len];
                if (!cb.f(cb.ctx, .{ .path = name.path, .line = h.line, .text = text })) s.stopped.store(true, .monotonic);
            },
        }
    }

    // Reads the file through `local.buf`, passing complete lines to the
    // matcher, or the whole file at once with `whole`. Returns false if the
    // file is binary or can't be read.
    //
    // A read that returns less than asked for means end of file (the walker
    // only passes regular files), so a small file costs one read, not two.
    // Standard input can return less before its end, so there that only
    // means another read.
    fn scan(s: *Searcher, local: *Local, file: Io.File, whole: bool, sink: anytype) !bool {
        local.offset = 0;
        local.read = 0;
        var line: usize = 1; // line number of local.buf[0]
        var carried: usize = 0; // partial line kept at the front of local.buf
        var first_read = true;
        const short_read_is_eof = file.handle != Io.File.stdin().handle;

        while (true) {
            if (carried == local.buf.len) {
                // A single line (or, with `whole`, the file) is longer than the buffer: grow it.
                local.buf = try s.gpa.realloc(local.buf, local.buf.len * 2);
            }
            const space = local.buf.len - carried;
            var n = file.readStreaming(s.io, &.{local.buf[carried..]}) catch |err| switch (err) {
                error.EndOfStream => {
                    // Last line has no trailing newline.
                    _ = s.findAll(local, local.buf[0..carried], line, sink) catch |e| switch (e) {
                        error.Done => {},
                        else => |other| return other,
                    };
                    return true;
                },
                else => return false,
            };
            const eof = short_read_is_eof and n < space;
            if (first_read and std.mem.startsWith(u8, local.buf[0..n], bom)) {
                // Like ripgrep, a UTF-8 byte-order mark is not part of line 1.
                std.mem.copyForwards(u8, local.buf[0 .. n - bom.len], local.buf[bom.len..n]);
                n -= bom.len;
            }
            first_read = false;
            local.read += n;
            const fresh = local.buf[carried..][0..n];
            // Text files only: a NUL byte anywhere means binary.
            if (!s.opts.binary and std.mem.indexOfScalar(u8, fresh, 0) != null) return false;

            const filled = local.buf[0 .. carried + n];
            if (whole and !eof) {
                carried = filled.len;
                continue;
            }
            // Search up to the last newline, or everything at end of file.
            const cut = if (eof) filled.len else if (std.mem.findScalarLast(u8, filled, '\n')) |nl| nl + 1 else 0;
            line = s.findAll(local, filled[0..cut], line, sink) catch |err| switch (err) {
                error.Done => return true,
                else => |e| return e,
            };
            if (eof) return true;

            const rest = filled[cut..];
            std.mem.copyForwards(u8, local.buf[0..rest.len], rest);
            carried = rest.len;
            local.offset += cut;
        }
    }

    // `findLines`, or with `-v` the lines in between (`data` is then the
    // whole file).
    fn findAll(s: *const Searcher, local: *Local, data: []const u8, first_line: usize, sink: anytype) !usize {
        if (!s.opts.invert) return s.findLines(local, data, first_line, sink);
        var inv: Invert(@TypeOf(sink)) = .{ .sink = sink, .data = data, .next_line = first_line };
        _ = try s.findLines(local, data, first_line, &inv);
        try inv.gap(data.len);
        return inv.next_line;
    }

    fn findLines(s: *const Searcher, local: *Local, data: []const u8, first_line: usize, sink: anytype) !usize {
        if (s.opts.regex) |re| return regex.findLines(re, &local.vm.?, data, first_line, sink);
        if (s.opts.ignore_case) return match.findLinesIgnoreCase(data, s.opts.term, first_line, sink);
        return match.findLines(data, s.opts.term, first_line, sink);
    }

    // The first match in `line` at or after `from`, for `-o`.
    fn findSpan(s: *const Searcher, vm: ?*regex.Vm, line: []const u8, from: usize) ?regex.Span {
        if (s.opts.regex) |re| return vm.?.find(re, line, from);
        const t = s.opts.term;
        const at = (if (s.opts.ignore_case) std.ascii.findIgnoreCasePos(line, from, t) else std.mem.findPos(u8, line, from, t)) orelse return null;
        return .{ .start = at, .end = at + t.len };
    }
};

const bom = "\xef\xbb\xbf";

fn lineStart(m: match.Match) usize {
    return m.end - m.text().len;
}

/// `-v`: passes on the lines between the matches instead of the matches.
fn Invert(comptime Sink: type) type {
    return struct {
        sink: Sink,
        data: []const u8,
        next_off: usize = 0, // the first line not yet passed on or skipped
        next_line: usize,

        pub fn onLine(v: *@This(), m: match.Match) !void {
            try v.gap(lineStart(m));
            v.next_off = m.end + 1;
            v.next_line = m.line + 1;
        }

        // Passes on every line from `next_off` up to `end`.
        fn gap(v: *@This(), end: usize) !void {
            while (v.next_off < end) {
                const nl = std.mem.indexOfScalarPos(u8, v.data, v.next_off, '\n') orelse v.data.len;
                try v.sink.onLine(match.Match{ .line = v.next_line, .data = v.data, .pos = v.next_off, .end = nl });
                v.next_off = nl + 1;
                v.next_line += 1;
            }
        }
    };
}

/// `.print` output for one file, written to `out`.
const Printer = struct {
    s: *Searcher,
    p: Print,
    out: *Io.Writer,
    local: *Searcher.Local,
    vm: ?*regex.Vm,
    name: Name,
    with_filename: bool,
    count: usize = 0,
    // The slice the current line is in: the chunk being searched, or with
    // context lines the whole file.
    chunk: []const u8 = "",
    // Context lines: `data` is the whole file; everything before `next_off`
    // has been printed or skipped.
    data: []const u8 = "",
    next_off: usize = 0,
    next_line: usize = 1,
    after_left: usize = 0,
    printed: bool = false,
    // `--json`: the `begin` message is out, and the numbers for `end`.
    begun: bool = false,
    file_stats: FileStats = .{},
    // Where `-m` stopped the search: the end of the last line it counted.
    stopped_at: ?usize = null,

    pub fn onLine(p: *Printer, m: match.Match) !void {
        p.count += 1;
        p.chunk = m.data;
        switch (p.p.mode) {
            .quiet => {
                p.s.stopped.store(true, .monotonic);
                return error.Done;
            },
            .files_with_matches => {
                try p.name.write(p.out);
                try p.out.writeByte(p.p.afterPath('\n'));
                return error.Done;
            },
            .count, .files => {},
            .only_matching => if (p.p.json) {
                try p.wholeLine(m);
            } else if (!p.s.opts.invert) {
                const text = m.text();
                var from: usize = 0;
                while (p.s.findSpan(p.vm, text, from)) |span| {
                    if (span.end > span.start) try p.line(':', m.line, text[span.start..span.end], false);
                    from = if (span.end > span.start) span.end else span.end + 1;
                    if (from > text.len) break;
                }
            },
            .lines => try p.wholeLine(m),
        }
        if (p.s.opts.max_count) |max| if (p.count >= max) {
            // As in rg, the bytes searched then end with this line; with -v
            // they are still the whole file.
            if (!p.s.opts.invert) {
                const end = p.local.offset + (@intFromPtr(m.data.ptr) - @intFromPtr(p.local.buf.ptr)) + m.end + 1;
                p.stopped_at = @min(end, p.local.read);
            }
            return error.Done;
        };
    }

    fn wholeLine(p: *Printer, m: match.Match) !void {
        if (p.p.context()) return p.withContext(m);
        const text = m.text();
        try p.line(':', m.line, text, (p.p.json or p.p.max_columns != null) and p.newlineAfter(text));
    }

    fn finish(p: *Printer, elapsed: u64) !void {
        if (p.p.context()) try p.afterContext(p.data.len);
        if (p.p.mode == .count and p.count > 0) {
            if (p.with_filename) {
                try p.name.write(p.out);
                try p.out.writeByte(p.p.afterPath(':'));
            }
            try p.out.print("{d}\n", .{p.count});
        }
        if (p.p.json) {
            p.file_stats.bytes_searched = p.stopped_at orelse p.local.read;
            p.file_stats.matched_lines = p.count;
            p.file_stats.elapsed = elapsed;
            if (p.begun) try p.jsonEnd();
        }
    }

    // Is `text`, a slice of the current chunk, followed by a newline there?
    fn newlineAfter(p: *const Printer, text: []const u8) bool {
        const end = @intFromPtr(text.ptr) + text.len - @intFromPtr(p.chunk.ptr);
        return end < p.chunk.len and p.chunk[end] == '\n';
    }

    // One output line: [path<sep>][line<sep>]text. `nl`: a newline follows
    // `text` in the file, which counts toward `--max-columns`.
    fn line(p: *Printer, sep: u8, number: usize, text: []const u8, nl: bool) !void {
        if (p.p.json) return p.jsonLine(sep == ':', number, text, nl);
        if (p.with_filename) {
            try p.name.write(p.out);
            try p.out.writeByte(p.p.afterPath(sep));
        }
        if (p.p.line_number) try p.out.print("{d}{c}", .{ number, sep });
        if (p.p.max_columns) |max| if (text.len + @intFromBool(nl) > max) {
            try p.out.writeAll(if (sep == ':') "[Omitted long matching line]\n" else "[Omitted long context line]\n");
            return;
        };
        try p.out.writeAll(text);
        try p.out.writeByte('\n');
    }

    // A `match` or `context` message, after the file's `begin`.
    fn jsonLine(p: *Printer, is_match: bool, number: usize, text: []const u8, nl: bool) !void {
        if (p.p.summary_only) {
            if (is_match and !p.s.opts.invert) {
                var from: usize = 0;
                while (p.s.findSpan(p.vm, text, from)) |span| {
                    p.file_stats.matches += 1;
                    from = if (span.end > span.start) span.end else span.end + 1;
                    if (from > text.len) break;
                }
            }
            return;
        }
        if (!p.begun) {
            p.begun = true;
            const jp = &p.local.json_path;
            jp.clearRetainingCapacity();
            var name: std.ArrayList(u8) = .empty;
            defer name.deinit(p.s.gpa);
            try name.appendSlice(p.s.gpa, p.name.prefix);
            if (p.name.slash) try name.append(p.s.gpa, '/');
            try name.appendSlice(p.s.gpa, p.name.path);
            try jsonData(&jp.writer, name.items);
            const start = p.out.end;
            try p.out.print("{{\"type\":\"begin\",\"data\":{{\"path\":{s}}}}}\n", .{jp.written()});
            p.file_stats.bytes_printed += p.out.end - start;
        }
        const start = p.out.end;
        try p.out.print("{{\"type\":\"{s}\",\"data\":{{\"path\":{s},\"lines\":", .{ if (is_match) "match" else "context", p.local.json_path.written() });
        try jsonData(p.out, text.ptr[0 .. text.len + @intFromBool(nl)]);
        if (p.p.line_number) try p.out.print(",\"line_number\":{d}", .{number}) else try p.out.writeAll(",\"line_number\":null");
        const offset = p.local.offset + (@intFromPtr(text.ptr) - @intFromPtr(p.local.buf.ptr));
        try p.out.print(",\"absolute_offset\":{d},\"submatches\":[", .{offset});
        if (is_match and !p.s.opts.invert) {
            var from: usize = 0;
            var n: usize = 0;
            while (p.s.findSpan(p.vm, text, from)) |span| {
                if (n > 0) try p.out.writeByte(',');
                n += 1;
                try p.out.writeAll("{\"match\":");
                try jsonData(p.out, text[span.start..span.end]);
                try p.out.print(",\"start\":{d},\"end\":{d}}}", .{ span.start, span.end });
                from = if (span.end > span.start) span.end else span.end + 1;
                if (from > text.len) break;
            }
            p.file_stats.matches += n;
        }
        try p.out.writeAll("]}}\n");
        p.file_stats.bytes_printed += p.out.end - start;
    }

    fn jsonEnd(p: *Printer) !void {
        const f = p.file_stats;
        try p.out.print("{{\"type\":\"end\",\"data\":{{\"path\":{s},\"binary_offset\":null,\"stats\":{{\"elapsed\":", .{p.local.json_path.written()});
        try jsonDuration(p.out, f.elapsed, false);
        try p.out.print(",\"searches\":1,\"searches_with_match\":{d},\"bytes_searched\":{d},\"bytes_printed\":{d},\"matched_lines\":{d},\"matches\":{d}}}}}}}\n", .{
            @intFromBool(f.matched_lines > 0), f.bytes_searched, f.bytes_printed, f.matched_lines, f.matches,
        });
    }

    fn withContext(p: *Printer, m: match.Match) !void {
        p.data = m.data;
        const start = lineStart(m);
        try p.afterContext(start);

        // Up to `before` lines back, but not into what's already printed.
        var b = start;
        var b_line = m.line;
        for (0..p.p.before) |_| {
            if (b <= p.next_off) break;
            b = if (std.mem.findScalarLast(u8, p.data[0 .. b - 1], '\n')) |nl| nl + 1 else 0;
            b_line -= 1;
        }
        if (p.printed and b != p.next_off and !p.p.json) try p.out.writeAll("--\n");
        p.next_off = b;
        p.next_line = b_line;
        while (p.next_off < start) try p.contextLine();

        try p.line(':', m.line, m.text(), m.end < p.data.len);
        p.next_off = m.end + 1;
        p.next_line = m.line + 1;
        p.after_left = p.p.after;
        p.printed = true;
    }

    // The previous match's after-context lines that come before `end`.
    fn afterContext(p: *Printer, end: usize) !void {
        while (p.after_left > 0 and p.next_off < end) {
            try p.contextLine();
            p.after_left -= 1;
        }
    }

    fn contextLine(p: *Printer) !void {
        const nl = std.mem.indexOfScalarPos(u8, p.data, p.next_off, '\n');
        const end = nl orelse p.data.len;
        try p.line('-', p.next_line, p.data[p.next_off..end], nl != null);
        p.next_off = end + 1;
        p.next_line += 1;
    }
};

/// `.callback` output: keeps the line number and a copy of the text until
/// the file is known not to be binary.
const Collected = struct { line: usize, start: usize, len: usize };

const Collect = struct {
    gpa: std.mem.Allocator,
    local: *Searcher.Local,

    // Never stops a file early, but `scan` handles `Done` from any sink.
    pub fn onLine(c: Collect, m: match.Match) (Done || std.mem.Allocator.Error || Io.Writer.Error)!void {
        const text = m.text();
        const start = c.local.matches.written().len;
        try c.local.matches.writer.writeAll(text);
        try c.local.hits.append(c.gpa, .{ .line = m.line, .start = start, .len = text.len });
    }
};
