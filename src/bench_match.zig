//! Microbenchmark for `match.findLines` alone: no file system, no output.
//! Usage: bench-match <corpus file> [runs]
//! Loads the corpus into memory, then for each term reports the best of
//! `runs` timings as GB/s, plus the number of matching lines.
//! Every term runs twice: case-sensitive, then with `findLinesIgnoreCase`.
//! Each run does what search.zig does per chunk: find matching lines and
//! work out the line number after the chunk.

const std = @import("std");
const Io = std.Io;
const match = @import("match.zig");

const terms = [_][]const u8{
    "PM_RESUME", // rare identifier
    "ERR_PTR", // common identifier
    "zqxjvkwqz", // no match
    "#include <linux/module.h>", // long
    "the", // short, common letters: many candidates
    "e", // single byte: matches most lines
};

const CountLines = struct {
    count: *usize,
    pub fn onLine(c: CountLines, m: match.Match) !void {
        _ = m;
        c.count.* += 1;
    }
};

var sink_line: usize = 0;

// Same work as search.zig per chunk: matches, then the next chunk's line number.
fn searchChunk(comptime case: match.Case, data: []const u8, term: []const u8, sink: anytype) !usize {
    return switch (case) {
        .sensitive => match.findLines(data, term, 1, sink),
        .insensitive => match.findLinesIgnoreCase(data, term, 1, sink),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: bench-match <corpus file> [runs]\n", .{});
        std.process.exit(2);
    }
    const runs = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 7;
    const data = try Io.Dir.cwd().readFileAlloc(io, args[1], init.gpa, .unlimited);
    defer init.gpa.free(data);

    std.debug.print("corpus: {d} MB, best of {d} runs\n", .{ data.len / 1_000_000, runs });
    inline for (.{ match.Case.sensitive, match.Case.insensitive }) |case| {
        std.debug.print("-- case {t}\n", .{case});
        try benchTerms(case, io, data, runs);
    }
}

fn benchTerms(comptime case: match.Case, io: Io, data: []const u8, runs: usize) !void {
    var total_ns: u64 = 0;
    for (terms) |term| {
        var best: u64 = std.math.maxInt(u64);
        var count: usize = 0;
        for (0..runs) |_| {
            count = 0;
            const start = Io.Timestamp.now(io, .awake);
            sink_line = try searchChunk(case, data, term, CountLines{ .count = &count });
            const ns: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
            best = @min(best, ns);
        }
        total_ns += best;
        const gbps = @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(best));
        std.debug.print("{s:<28} {d:>8.2} ms  {d:>6.2} GB/s  {d:>9} lines\n", .{
            term, @as(f64, @floatFromInt(best)) / 1e6, gbps, count,
        });
    }
    std.debug.print("{s:<28} {d:>8.2} ms   (last line number: {d})\n", .{ "total", @as(f64, @floatFromInt(total_ns)) / 1e6, sink_line });
}
