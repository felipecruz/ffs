//! C ABI over `search.run`: `ffs_search` in include/ffs.h. Keep the two in
//! sync; the test at the bottom calls it the way C would.

const std = @import("std");
const build_options = @import("build_options");
const search = @import("search.zig");
const Regex = @import("regex.zig").Regex;

const FFS_IGNORE_CASE = 1;
const FFS_REGEX = 2;

const FFS_OK = 0;
const FFS_STOPPED = 1;
const FFS_EARG = -1;
const FFS_EREGEX = -2;
const FFS_EROOT = -3;
const FFS_ENOMEM = -4;

pub const ffs_match = extern struct {
    path: [*:0]const u8,
    line: usize,
    text: [*:0]const u8,
    text_len: usize,
};

pub const ffs_callback = *const fn (ctx: ?*anyopaque, m: *const ffs_match) callconv(.c) c_int;

pub export fn ffs_search(
    root: ?[*:0]const u8,
    term: ?[*:0]const u8,
    flags: c_uint,
    threads: c_uint,
    cb: ?ffs_callback,
    ctx: ?*anyopaque,
) c_int {
    const root_path = std.mem.span(root orelse return FFS_EARG);
    const t = std.mem.span(term orelse return FFS_EARG);
    if (t.len == 0 or std.mem.indexOfScalar(u8, t, '\n') != null) return FFS_EARG;
    const gpa = std.heap.smp_allocator;
    const ignore_case = flags & FFS_IGNORE_CASE != 0;

    var re: ?Regex = null;
    if (flags & FFS_REGEX != 0) re = Regex.compile(gpa, t, ignore_case) catch |err| return switch (err) {
        error.OutOfMemory => FFS_ENOMEM,
        else => FFS_EREGEX,
    };
    defer if (re) |*r| r.deinit();

    var state: State = .{ .gpa = gpa, .root = root_path, .cb = cb orelse return FFS_EARG, .ctx = ctx };
    defer state.buf.deinit(gpa);
    search.run(gpa, .{
        .root_path = root_path,
        .term = t,
        .jobs = if (threads == 0) search.autoJobs() else threads,
        .ignore_case = ignore_case,
        .regex = if (re) |*r| r else null,
    }, .{ .callback = .{ .ctx = &state, .f = State.onHit } }) catch return FFS_EROOT; // the only error left: opening root
    if (state.out_of_memory) return FFS_ENOMEM;
    return if (state.stopped) FFS_STOPPED else FFS_OK;
}

pub export fn ffs_version() [*:0]const u8 {
    return std.fmt.comptimePrint("{s}", .{build_options.version}); // NUL-terminated
}

// Turns a `search.Hit` into an `ffs_match` with NUL-terminated strings.
// Callbacks are serialized, so one buffer is enough.
const State = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    cb: ffs_callback,
    ctx: ?*anyopaque,
    buf: std.ArrayList(u8) = .empty, // "<root>/<path>\0<text>\0"
    stopped: bool = false,
    out_of_memory: bool = false,

    fn onHit(ptr: ?*anyopaque, hit: search.Hit) bool {
        const s: *State = @ptrCast(@alignCast(ptr));
        s.buf.clearRetainingCapacity();
        for ([_][]const u8{ s.root, "/", hit.path, "\x00", hit.text, "\x00" }) |part| {
            s.buf.appendSlice(s.gpa, part) catch {
                s.out_of_memory = true;
                return false;
            };
        }
        const text_start = s.root.len + 1 + hit.path.len + 1;
        const m: ffs_match = .{
            .path = @ptrCast(s.buf.items.ptr),
            .line = hit.line,
            .text = @ptrCast(s.buf.items[text_start..].ptr),
            .text_len = hit.text.len,
        };
        if (s.cb(s.ctx, &m) != 0) s.stopped = true;
        return !s.stopped;
    }
};

// The marker below appears exactly once in the source tree, on this line:
// zqx_c_api_marker
const Lines = struct {
    count: usize = 0,
    last_line: usize = 0,
    stop_after: usize = std.math.maxInt(usize),
    path_ok: bool = true,

    fn cb(ctx: ?*anyopaque, m: *const ffs_match) callconv(.c) c_int {
        const l: *Lines = @ptrCast(@alignCast(ctx));
        l.count += 1;
        l.last_line = m.line;
        l.path_ok = l.path_ok and std.mem.eql(u8, std.mem.span(m.path), "src/c_api.zig") and
            std.mem.span(m.text).len == m.text_len;
        return @intFromBool(l.count >= l.stop_after);
    }
};

test "ffs_search from C" {
    // Run from the project root by `zig build test`.
    var l: Lines = .{};
    try std.testing.expectEqual(FFS_OK, ffs_search("src", "zqx_c_api_" ++ "marker", 0, 2, Lines.cb, &l));
    try std.testing.expectEqual(1, l.count);
    try std.testing.expect(l.path_ok);

    l = .{};
    try std.testing.expectEqual(FFS_OK, ffs_search("src", "ZQX_C_API_" ++ "MARKER", FFS_IGNORE_CASE, 0, Lines.cb, &l));
    try std.testing.expectEqual(1, l.count);

    l = .{};
    try std.testing.expectEqual(FFS_OK, ffs_search("src", "^// zqx_c_api_" ++ "m[a-z]+$", FFS_REGEX, 0, Lines.cb, &l));
    try std.testing.expectEqual(1, l.count);

    // Stop after the first match of a common word.
    l = .{ .stop_after = 1 };
    try std.testing.expectEqual(FFS_STOPPED, ffs_search("src", "const", 0, 0, Lines.cb, &l));
    try std.testing.expectEqual(1, l.count);

    try std.testing.expectEqual(FFS_EREGEX, ffs_search("src", "a(", FFS_REGEX, 0, Lines.cb, &l));
    try std.testing.expectEqual(FFS_EROOT, ffs_search("no/such/dir", "x", 0, 0, Lines.cb, &l));
    try std.testing.expectEqual(FFS_EARG, ffs_search("src", "", 0, 0, Lines.cb, &l));
    try std.testing.expectEqual(FFS_EARG, ffs_search(null, "x", 0, 0, Lines.cb, &l));
    try std.testing.expectEqual(FFS_EARG, ffs_search("src", "x", 0, 0, null, null));
    try std.testing.expectEqualStrings(build_options.version, std.mem.span(ffs_version()));
}
