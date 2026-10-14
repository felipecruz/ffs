//! Finding the term in bytes: no I/O, no output format.
//!
//! A matcher calls `sink.onLine(match)` once for each line of `data` that
//! contains `term`, in order, and returns the line number just after `data`
//! (`first_line` + newlines in `data`). `first_line` is the line number of
//! `data[0]`, which must be the start of a line, so callers can search a
//! file in chunks. `term` must not contain '\n'.
//! `sink` is any value with `fn onLine(self, m: Match) !void`.
//!
//! `findLinesIgnoreCase` is the same search with ASCII case folding: `A`-`Z`
//! match `a`-`z`; other bytes, including non-ASCII UTF-8, match exactly.

const std = @import("std");

/// One matching line, as passed to `sink.onLine`.
pub const Match = struct {
    line: usize, // line number
    data: []const u8, // the slice being searched
    pos: usize, // where the term starts in `data`
    end: usize, // end of the line in `data`: its '\n', or data.len

    /// The line's text, without its '\n'. The start is found on demand by
    /// scanning back from `pos` to the previous newline, so sinks that only
    /// print line numbers pay nothing for it.
    pub fn text(m: Match) []const u8 {
        const start = if (std.mem.findScalarLast(u8, m.data[0..m.pos], '\n')) |nl| nl + 1 else 0;
        return m.data[start..m.end];
    }
};

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vec_len, u8);
const Mask = @Int(.unsigned, vec_len);

// SIMD search: for each block of `vec_len` candidate positions, compare the
// first byte of `term` at offset 0 and its last byte at offset term.len - 1.
// Only positions where both match are verified with a full comparison.
//
// Ignoring case, letters in the end bytes are compared with bit 5 set (one
// extra OR per load; see `Byte`), and candidates are verified with
// `eqlIgnoreCase`. `case` is comptime, so the case-sensitive
// loop is unchanged.
//
// Newlines are counted in the same loop, on the block already loaded, into
// per-lane u8 counters (`nl_acc`): one vector add per block. The counters are
// summed into `line` only when a match needs its line number, or every 255
// blocks before they could overflow. Turning a compare into a bitmask is
// expensive on NEON (no movemask instruction), so it is done only on a match.
pub fn findLines(data: []const u8, term: []const u8, first_line: usize, sink: anytype) !usize {
    return find(.sensitive, data, term, first_line, sink);
}

pub fn findLinesIgnoreCase(data: []const u8, term: []const u8, first_line: usize, sink: anytype) !usize {
    return find(.insensitive, data, term, first_line, sink);
}

pub const Case = enum { sensitive, insensitive };

fn find(comptime case: Case, data: []const u8, term: []const u8, first_line: usize, sink: anytype) !usize {
    var line: usize = first_line; // line number of data[i], minus what's in nl_acc
    if (data.len < term.len) return line + std.mem.countScalar(u8, data, '\n');

    const n = term.len;
    const first: Byte(case) = .init(term[0]);
    const last: Byte(case) = .init(term[n - 1]);
    const newline: Vec = @splat('\n');
    const end = data.len - n + 1; // candidate start positions are [0, end)

    var nl_acc: Vec = @splat(0);
    var nl_blocks: u8 = 0; // blocks added to nl_acc since the last flush

    var i: usize = 0;
    outer: while (i + vec_len <= end) {
        const a: Vec = data[i..][0..vec_len].*;
        const b: Vec = data[i + n - 1 ..][0..vec_len].*;
        const is_nl = a == newline;
        var mask: Mask = first.eqlMask(a) & last.eqlMask(b);
        while (mask != 0) : (mask &= mask - 1) {
            const lane: Lane = @intCast(@ctz(mask));
            const pos = i + lane;
            if (eql(case, data[pos..][0..n], term)) {
                line += flush(&nl_acc, &nl_blocks);
                // Newlines in data[i..pos] are the bits below `lane`.
                const nl_mask: Mask = @bitCast(is_nl);
                line += @popCount(nl_mask & ((@as(Mask, 1) << lane) - 1));
                i = try report(data, pos, &line, sink) orelse return line;
                continue :outer;
            }
        }
        nl_acc += @select(u8, is_nl, @as(Vec, @splat(1)), @as(Vec, @splat(0)));
        nl_blocks += 1;
        if (nl_blocks == 255) line += flush(&nl_acc, &nl_blocks);
        i += vec_len;
    }
    line += flush(&nl_acc, &nl_blocks);

    // Tail: fewer than vec_len candidate positions left.
    while (i < end) {
        if (first.eqlByte(data[i]) and eql(case, data[i..][0..n], term)) {
            i = try report(data, i, &line, sink) orelse return line;
        } else {
            line += @intFromBool(data[i] == '\n');
            i += 1;
        }
    }
    // The last n - 1 bytes can't start a match but may hold newlines.
    return line + std.mem.countScalar(u8, data[i..], '\n');
}

// One byte of the term, splatted for comparing against a block. Ignoring
// case, a letter is compared as `(v | 0x20) == lower`: setting bit 5 maps
// 'A'-'Z' onto 'a'-'z', and only 'A'-'Z' and 'a'-'z' land on 'a'-'z', so the
// compare is exact. Non-letters use `fold = 0`, a plain compare.
fn Byte(comptime case: Case) type {
    return struct {
        const Self = @This();
        lower: Vec,
        fold: if (case == .insensitive) Vec else void, // 0x20 for letters, else 0

        fn init(c: u8) Self {
            return switch (case) {
                .sensitive => .{ .lower = @splat(c), .fold = {} },
                .insensitive => .{
                    .lower = @splat(std.ascii.toLower(c)),
                    .fold = @splat(if (std.ascii.isAlphabetic(c)) 0x20 else 0),
                },
            };
        }

        fn eqlMask(self: Self, v: Vec) Mask {
            const folded = if (case == .sensitive) v else v | self.fold;
            return @bitCast(folded == self.lower);
        }

        fn eqlByte(self: Self, c: u8) bool {
            const folded = if (case == .sensitive) c else c | self.fold[0];
            return folded == self.lower[0];
        }
    };
}

fn eql(comptime case: Case, a: []const u8, b: []const u8) bool {
    return switch (case) {
        .sensitive => std.mem.eql(u8, a, b),
        .insensitive => std.ascii.eqlIgnoreCase(a, b),
    };
}

// Sums and clears the per-lane newline counters.
fn flush(acc: *Vec, blocks: *u8) usize {
    const sum = @reduce(.Add, @as(@Vector(vec_len, u16), acc.*));
    acc.* = @splat(0);
    blocks.* = 0;
    return sum;
}

const Lane = std.math.Log2Int(Mask);

// Reports the match's line (`line.*` is already the line of `pos`), then
// skips to the start of the next line. Returns null if there is none.
fn report(data: []const u8, pos: usize, line: *usize, sink: anytype) !?usize {
    const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n');
    try sink.onLine(Match{ .line = line.*, .data = data, .pos = pos, .end = nl orelse data.len });
    const i = nl orelse return null;
    line.* += 1;
    return i + 1;
}

/// Original scalar version: a pointer runs from begin to end, counting
/// newlines. Kept as the reference implementation for tests.
pub fn findLinesNaive(comptime case: Case, data: []const u8, term: []const u8, first_line: usize, sink: anytype) !usize {
    const after = first_line + std.mem.countScalar(u8, data, '\n');
    if (data.len < term.len) return after;

    const begin: [*]const u8 = data.ptr;
    const end: [*]const u8 = begin + data.len;
    const last: [*]const u8 = end - term.len; // last position where term fits

    var p = begin;
    var line: usize = first_line;
    while (@intFromPtr(p) <= @intFromPtr(last)) {
        if (p[0] == '\n') {
            line += 1;
            p += 1;
        } else if (eql(case, p[0..term.len], term)) {
            const pos = @intFromPtr(p) - @intFromPtr(begin);
            // skip the rest of the line so each line is reported once
            while (@intFromPtr(p) < @intFromPtr(end) and p[0] != '\n') p += 1;
            try sink.onLine(Match{ .line = line, .data = data, .pos = pos, .end = @intFromPtr(p) - @intFromPtr(begin) });
        } else {
            p += 1;
        }
    }
    return after;
}

const CollectLines = struct {
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(usize),
    first_line: usize,

    // Also checks `m.text()` against the line found by splitting `data` on
    // newlines, an independent oracle.
    pub fn onLine(c: CollectLines, m: Match) !void {
        try c.lines.append(c.gpa, m.line);
        var it = std.mem.splitScalar(u8, m.data, '\n');
        for (0..m.line - c.first_line) |_| _ = it.next();
        try std.testing.expectEqualStrings(it.next().?, m.text());
    }
};

test "SIMD search matches naive search" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xf5f5);
    const rand = prng.random();
    const alphabet = "abAB\n";
    var data_buf: [600]u8 = undefined;
    var term_buf: [8]u8 = undefined;
    var simd_lines: std.ArrayList(usize) = .empty;
    defer simd_lines.deinit(gpa);
    var naive_lines: std.ArrayList(usize) = .empty;
    defer naive_lines.deinit(gpa);

    for (0..20_000) |_| {
        const data = data_buf[0..rand.uintAtMost(usize, data_buf.len)];
        for (data) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        const term = term_buf[0 .. 1 + rand.uintLessThan(usize, term_buf.len)];
        for (term) |*c| c.* = alphabet[rand.uintLessThan(usize, 4)]; // no newline in term
        const first_line = 1 + rand.uintLessThan(usize, 100);

        inline for (.{ Case.sensitive, Case.insensitive }) |case| {
            simd_lines.clearRetainingCapacity();
            naive_lines.clearRetainingCapacity();
            const simd_after = try find(case, data, term, first_line, CollectLines{ .gpa = gpa, .lines = &simd_lines, .first_line = first_line });
            const naive_after = try findLinesNaive(case, data, term, first_line, CollectLines{ .gpa = gpa, .lines = &naive_lines, .first_line = first_line });
            try std.testing.expectEqualSlices(usize, naive_lines.items, simd_lines.items);
            try std.testing.expectEqual(naive_after, simd_after);
        }
    }
}

test "SIMD search matches naive search on long inputs" {
    // Longer than 255 blocks of vec_len bytes, so the per-lane newline
    // counters are flushed mid-scan.
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    const data_buf = try gpa.alloc(u8, 300 * vec_len);
    defer gpa.free(data_buf);
    var simd_lines: std.ArrayList(usize) = .empty;
    defer simd_lines.deinit(gpa);
    var naive_lines: std.ArrayList(usize) = .empty;
    defer naive_lines.deinit(gpa);

    for (0..300) |_| {
        const data = data_buf[0 .. 255 * vec_len + rand.uintLessThan(usize, 45 * vec_len)];
        // Newline density 1/40, 1/2 or 1/1: dense newlines would overflow the
        // u8 lane counters without the flush.
        const nl_one_in = ([_]u8{ 40, 2, 1 })[rand.uintLessThan(usize, 3)];
        for (data) |*c| c.* = if (rand.uintLessThan(u8, nl_one_in) == 0) '\n' else "abAB"[rand.uintLessThan(usize, 4)];
        const term = ([_][]const u8{ "a", "ab", "bAb", "aabBa", "bbbbbbb" })[rand.uintLessThan(usize, 5)];

        inline for (.{ Case.sensitive, Case.insensitive }) |case| {
            simd_lines.clearRetainingCapacity();
            naive_lines.clearRetainingCapacity();
            const simd_after = try find(case, data, term, 7, CollectLines{ .gpa = gpa, .lines = &simd_lines, .first_line = 7 });
            const naive_after = try findLinesNaive(case, data, term, 7, CollectLines{ .gpa = gpa, .lines = &naive_lines, .first_line = 7 });
            try std.testing.expectEqualSlices(usize, naive_lines.items, simd_lines.items);
            try std.testing.expectEqual(naive_after, simd_after);
        }
    }
}

test "ignore case folds ASCII letters only" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(usize) = .empty;
    defer lines.deinit(gpa);
    // Line 5 ends in 'Ö' (UTF-8), which is not folded. Line 7 lies past the
    // first SIMD blocks.
    const pad = "pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad \n";
    const data = "x\nHeLLo world\n[hello]\n{HELLO}\nhell\xc3\x96\n" ++ pad ++ "HELLO\n";
    const after = try findLinesIgnoreCase(data, "hello", 1, CollectLines{ .gpa = gpa, .lines = &lines, .first_line = 1 });
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 4, 7 }, lines.items);
    try std.testing.expectEqual(8, after);

    // '[' and '{' are not the case forms of each other.
    lines.clearRetainingCapacity();
    _ = try findLinesIgnoreCase(data, "{hello}", 1, CollectLines{ .gpa = gpa, .lines = &lines, .first_line = 1 });
    try std.testing.expectEqualSlices(usize, &.{4}, lines.items);
}
