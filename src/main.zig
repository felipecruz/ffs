const std = @import("std");
const build_options = @import("build_options");
const search = @import("search.zig");
const Regex = @import("regex.zig").Regex;

// Usage: ffs [-j N] [-i] [-E] [--content] <folder> <term>
// Recursively searches every text file under <folder> and prints `path:line`
// (or `path:line:content` with --content) for each line containing <term>.
// `-i` ignores ASCII case. `-E` treats <term> as a regex (see regex.zig).
// Output order is not deterministic.
//
// Layers:
//   main.zig    command line
//   c_api.zig   the same search as a C library (include/ffs.h)
//   walk.zig    parallel recursive directory walk (worker pool, one queue)
//   search.zig  thread pool, per-file work: open, read, binary check, output
//   match.zig   finding the term in bytes (SIMD), no I/O
//   regex.zig   regex: parser, Pike VM, SIMD literal prefilter
//
// `-j N` sets the number of worker threads; `-j 1` is fully serial. The
// default, `-j auto`, is the performance-core count on Apple silicon (4 on
// an M5), else every logical CPU: see `search.autoJobs`.
//
// std.Io.Evented (Dispatch on macOS) and std.Io.Kqueue do not compile in
// Zig 0.17.0: their vtables are out of sync with std.Io.VTable.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    var jobs: usize = 0; // 0: automatic
    var content = false;
    var ignore_case = false;
    var use_regex = false;
    var pos_args = args[1..];
    while (pos_args.len > 0 and std.mem.startsWith(u8, pos_args[0], "-")) {
        const flag = pos_args[0];
        pos_args = pos_args[1..];
        if (std.mem.eql(u8, flag, "--version") or std.mem.eql(u8, flag, "-V")) {
            std.debug.print("ffs {s}\n", .{build_options.version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, flag, "--content")) {
            content = true;
        } else if (std.mem.eql(u8, flag, "-i") or std.mem.eql(u8, flag, "--ignore-case")) {
            ignore_case = true;
        } else if (std.mem.eql(u8, flag, "-E") or std.mem.eql(u8, flag, "--regex")) {
            use_regex = true;
        } else if (std.mem.startsWith(u8, flag, "-j")) {
            var value: []const u8 = flag[2..];
            if (value.len == 0) {
                if (pos_args.len == 0) usage();
                value = pos_args[0];
                pos_args = pos_args[1..];
            }
            if (std.mem.eql(u8, value, "auto")) {
                jobs = 0;
            } else {
                jobs = std.fmt.parseInt(usize, value, 10) catch usage();
                if (jobs == 0) usage();
            }
        } else usage();
    }
    if (pos_args.len != 2 or pos_args[1].len == 0) usage();
    const root_path = pos_args[0];
    const term = pos_args[1];
    // Only complete lines are searched, so a term can't span lines.
    if (std.mem.indexOfScalar(u8, term, '\n') != null) usage();

    var re: ?Regex = null;
    if (use_regex) re = Regex.compile(gpa, term, ignore_case) catch |err| {
        std.debug.print("ffs: invalid regex: {t}\n", .{err});
        std.process.exit(2);
    };
    defer if (re) |*r| r.deinit();

    search.run(gpa, .{
        .root_path = root_path,
        .term = term,
        .jobs = if (jobs == 0) search.autoJobs() else jobs,
        .ignore_case = ignore_case,
        .regex = if (re) |*r| r else null,
    }, .{ .print = .{ .file = .stdout(), .content = content } }) catch |err| {
        std.debug.print("ffs: {s}: {t}\n", .{ root_path, err });
        std.process.exit(2);
    };
}

fn usage() noreturn {
    std.debug.print(
        \\usage: ffs [-j N|auto] [-i] [-E] [--content] <folder> <term>
        \\  -j N|auto          worker threads (default: auto = {d} here, the
        \\                     performance-core count on Apple silicon, else
        \\                     every logical CPU)
        \\  -i, --ignore-case  match ASCII letters regardless of case
        \\  -E, --regex        <term> is a regular expression (see src/regex.zig)
        \\  --content          print <path>:<line>:<content> instead of <path>:<line>
        \\  -V, --version      print the version
        \\  <term> must not contain a newline
        \\
    , .{search.autoJobs()});
    std.process.exit(2);
}

test {
    _ = @import("c_api.zig");
    _ = @import("match.zig");
    _ = @import("regex.zig");
    _ = @import("search.zig");
    _ = @import("walk.zig");
}
