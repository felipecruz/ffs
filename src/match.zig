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
// two rarest bytes of `term` (see `probes`) at their offsets. Only positions
// where both match are verified with a full comparison.
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
    const o = probes(term, case == .insensitive);
    // The usual probes, the two ends, get their own copy of the loop: with
    // the first probe at offset 0, its load is the one that counts newlines.
    if (o[0] == 0 and o[1] == term.len - 1) return findProbes(case, true, data, term, o, first_line, sink);
    return findProbes(case, false, data, term, o, first_line, sink);
}

fn findProbes(comptime case: Case, comptime ends: bool, data: []const u8, term: []const u8, o: [2]usize, first_line: usize, sink: anytype) !usize {
    var line: usize = first_line; // line number of data[i], minus what's in nl_acc
    if (data.len < term.len) return line + std.mem.countScalar(u8, data, '\n');

    const n = term.len;
    const first: Byte(case) = .init(term[o[0]]);
    const second: Byte(case) = .init(term[o[1]]);
    const newline: Vec = @splat('\n');
    const end = data.len - n + 1; // candidate start positions are [0, end)

    var nl_acc: Vec = @splat(0);
    var nl_blocks: u8 = 0; // blocks added to nl_acc since the last flush

    var i: usize = 0;
    outer: while (i + vec_len <= end) {
        const a: Vec = data[i..][0..vec_len].*;
        const x: Vec = if (ends) a else data[i + o[0] ..][0..vec_len].*;
        const y: Vec = data[i + (if (ends) n - 1 else o[1]) ..][0..vec_len].*;
        const is_nl = a == newline;
        var mask: Mask = first.eqlMask(x) & second.eqlMask(y);
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
        if (first.eqlByte(data[i + o[0]]) and eql(case, data[i..][0..n], term)) {
            i = try report(data, i, &line, sink) orelse return line;
        } else {
            line += @intFromBool(data[i] == '\n');
            i += 1;
        }
    }
    // The last n - 1 bytes can't start a match but may hold newlines.
    return line + std.mem.countScalar(u8, data[i..], '\n');
}

/// The most terms `findLinesAny` takes.
pub const max_terms = 16;

/// `findLines` for lines that contain any of `terms` (1 to `max_terms`, none
/// empty): a regex alternation such as `func cancel|killGrace|cleanup`. The
/// same loop as `find`, with every term's two probe bytes compared against
/// each block, so a candidate is a position where some term's probes line up.
pub fn findLinesAny(comptime case: Case, data: []const u8, terms: []const []const u8, first_line: usize, sink: anytype) !usize {
    std.debug.assert(terms.len >= 1 and terms.len <= max_terms);
    // As in `find`: a copy of the loop for when every term's probes are its ends.
    for (terms) |t| {
        const o = probes(t, case == .insensitive);
        if (o[0] != 0 or o[1] != t.len - 1) return findAnyProbes(case, false, data, terms, first_line, sink);
    }
    return findAnyProbes(case, true, data, terms, first_line, sink);
}

fn findAnyProbes(comptime case: Case, comptime ends: bool, data: []const u8, terms: []const []const u8, first_line: usize, sink: anytype) !usize {
    var firsts: [max_terms]Byte(case) = undefined;
    var seconds: [max_terms]Byte(case) = undefined;
    var offsets: [max_terms][2]usize = undefined;
    var max_len: usize = 0;
    for (terms, 0..) |t, k| {
        offsets[k] = probes(t, case == .insensitive);
        firsts[k] = .init(t[offsets[k][0]]);
        seconds[k] = .init(t[offsets[k][1]]);
        max_len = @max(max_len, t.len);
    }
    const newline: Vec = @splat('\n');
    var line: usize = first_line;
    var nl_acc: Vec = @splat(0);
    var nl_blocks: u8 = 0;

    var i: usize = 0;
    outer: while (i + vec_len + max_len - 1 <= data.len) {
        const a: Vec = data[i..][0..vec_len].*;
        const is_nl = a == newline;
        var mask: Mask = 0;
        for (firsts[0..terms.len], seconds[0..terms.len], offsets[0..terms.len]) |f, g, o| {
            const x: Vec = if (ends) a else data[i + o[0] ..][0..vec_len].*;
            const y: Vec = data[i + o[1] ..][0..vec_len].*;
            mask |= f.eqlMask(x) & g.eqlMask(y);
        }
        while (mask != 0) : (mask &= mask - 1) {
            const lane: Lane = @intCast(@ctz(mask));
            const pos = i + lane;
            if (anyAt(case, data, pos, terms)) {
                line += flush(&nl_acc, &nl_blocks);
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

    // Tail: too close to the end for the longest term's block load.
    while (i < data.len) {
        if (anyAt(case, data, i, terms)) {
            i = try report(data, i, &line, sink) orelse return line;
        } else {
            line += @intFromBool(data[i] == '\n');
            i += 1;
        }
    }
    return line;
}

/// How rare each byte is in source code: -4 * log2 of its frequency in a
/// sample of the LLVM, Linux and Redis trees (470 MB), capped at 160 for
/// bytes that never occurred. ' ' is 10, 'e' 18, '_' 20, ':' 25, 'Q' 44.
pub const rarity: [256]u8 = .{
    160, 104, 115, 160, 160, 160, 160, 160, 105,  25,  21, 160,  95,  72, 160, 160,
    160, 160, 160, 160, 160, 160, 160, 160, 115, 160, 160, 115, 115, 160, 160, 160,
     10,  41,  32,  34,  41,  30,  39,  43,  28,  28,  31,  40,  23,  24,  28,  29,
     22,  25,  26,  28,  29,  33,  29,  35,  31,  35,  25,  27,  33,  30,  31,  52,
     40,  28,  33,  26,  30,  24,  31,  32,  32,  29,  51,  33,  29,  30,  27,  31,
     30,  44,  29,  28,  26,  34,  33,  39,  29,  41,  44,  29,  44,  29,  55,  20,
     50,  21,  28,  23,  23,  18,  25,  28,  29,  20,  46,  33,  23,  25,  21,  22,
     25,  39,  21,  21,  19,  25,  26,  33,  26,  32,  38,  33,  43,  34,  53, 107,
     61,  68,  64,  69,  65,  67,  68,  68,  65,  67,  69,  69,  64,  68,  70,  66,
     69,  71,  74,  72,  64,  70,  69,  68,  68,  69,  64,  69,  64,  71,  71,  70,
     66,  68,  71,  74,  69,  68,  70,  71,  65,  73,  71,  74,  73,  69,  66,  65,
     67,  72,  76,  71,  72,  74,  68,  72,  63,  69,  65,  65,  63,  66,  70,  67,
    115, 160,  72,  73, 100,  93, 109, 115, 100, 107, 115, 160, 100, 107,  92, 103,
     81,  84, 160, 160, 160, 160, 160,  95, 160, 160, 160, 160, 160, 160, 115, 160,
    115,  94,  66,  66,  59,  56,  58,  59,  61,  63, 107, 160, 160, 160, 160,  65,
     85, 160, 160, 101, 115, 160, 160, 160, 160, 160, 160, 160, 160, 160, 115, 115,
};

/// `rarity` of `c`, or ignoring case of either case of a letter (both are
/// candidates, so the letter is as common as the two together).
pub fn byteRarity(c: u8, fold: bool) u8 {
    return if (fold) rarity_folded[c] else rarity[c];
}

const rarity_folded: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t = rarity;
    for ('a'..'z' + 1) |lo| {
        const up = std.ascii.toUpper(lo);
        const p = std.math.exp2(-@as(f64, rarity[lo]) / 4) + std.math.exp2(-@as(f64, rarity[up]) / 4);
        t[lo] = @intFromFloat(@round(-4 * std.math.log2(p)));
        t[up] = t[lo];
    }
    break :blk t;
};

/// The offsets in `term` the SIMD search compares, in increasing order.
/// Normally its first and last byte (the first load also counts newlines).
/// But when those are common together (more than one position in 1024
/// passes both) and its two rarest bytes are at least 4x rarer, those: in
/// " : public " that is ':' and 'b', not the two spaces at the ends. Below
/// that rate, false candidates cost less than the extra load. The second
/// probe is a different byte from the first when there is one. One byte:
/// both offsets are 0.
pub fn probes(term: []const u8, fold: bool) [2]usize {
    const ends: [2]usize = .{ 0, term.len - 1 };
    const ends_rarity = pairRarity(term, ends, fold);
    if (ends_rarity >= 40) return ends;
    const rare = rarest(term, fold);
    if (pairRarity(term, rare, fold) >= ends_rarity + 8) return rare;
    return ends;
}

fn pairRarity(term: []const u8, o: [2]usize, fold: bool) u16 {
    if (o[0] == o[1]) return byteRarity(term[o[0]], fold);
    return @as(u16, byteRarity(term[o[0]], fold)) + byteRarity(term[o[1]], fold);
}

fn rarest(term: []const u8, fold: bool) [2]usize {
    var best: usize = 0;
    for (term, 0..) |c, k| {
        if (byteRarity(c, fold) > byteRarity(term[best], fold)) best = k;
    }
    // The rarest other byte, preferring one unlike term[best].
    var second = best;
    var second_key: u16 = 0;
    for (term, 0..) |c, k| {
        if (k == best) continue;
        const key = @as(u16, byteRarity(c, fold)) + if (sameByte(c, term[best], fold)) @as(u16, 0) else 256;
        if (second == best or key > second_key) {
            second = k;
            second_key = key;
        }
    }
    return .{ @min(best, second), @max(best, second) };
}

fn sameByte(a: u8, b: u8, fold: bool) bool {
    return if (fold) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

/// The most ranges a `Ranges` holds.
pub const max_ranges = 4;

/// A set of bytes as a few ranges, for `findLinesRun`: `[0-9a-f]` is two,
/// `\w` four.
pub const Ranges = struct {
    lo: [max_ranges]u8 = undefined,
    span: [max_ranges]u8 = undefined, // hi - lo
    n: usize = 0,

    /// The ranges of `set` (a bit set of 256 bytes), or null if there are
    /// more than `max_ranges` or none.
    pub fn of(set: anytype) ?Ranges {
        var r: Ranges = .{};
        var b: usize = 0;
        while (b < 256) {
            if (!set.isSet(b)) {
                b += 1;
                continue;
            }
            const lo = b;
            while (b < 256 and set.isSet(b)) b += 1;
            if (r.n == max_ranges) return null;
            r.lo[r.n] = @intCast(lo);
            r.span[r.n] = @intCast(b - 1 - lo);
            r.n += 1;
        }
        return if (r.n == 0) null else r;
    }

    pub fn contains(r: Ranges, c: u8) bool {
        for (r.lo[0..r.n], r.span[0..r.n]) |lo, span| {
            if (c -% lo <= span) return true;
        }
        return false;
    }

    // The lanes of `v` in the set: (v - lo) <= span, wrapping, per range.
    fn mask(r: Ranges, v: Vec) Mask {
        var m: Mask = 0;
        for (r.lo[0..r.n], r.span[0..r.n]) |lo, span| {
            const in = (v -% @as(Vec, @splat(lo))) <= @as(Vec, @splat(span));
            m |= @as(Mask, @bitCast(in));
        }
        return m;
    }
};

/// `findLines` for lines with a run of at least `min` consecutive bytes
/// from `set` ('\n' must not be in it): `[0-9a-f]{16}` is a run of 16
/// from two ranges. For each block, `Ranges.mask` gives the bytes in the
/// set as a bitmask. A run that fits in the block shows up as a bit that
/// survives AND-ing the mask with itself shifted by 1 to min - 1 places
/// (log2(min) steps by doubling); one that crosses into the block from the
/// last continues `carry`, the run at the end of the last block.
pub fn findLinesRun(data: []const u8, set: Ranges, min: usize, first_line: usize, sink: anytype) !usize {
    std.debug.assert(min >= 1);
    const newline: Vec = @splat('\n');
    var line: usize = first_line;
    var nl_acc: Vec = @splat(0);
    var nl_blocks: u8 = 0;
    var carry: usize = 0; // bytes in the set just before data[i]

    var i: usize = 0;
    while (i + vec_len <= data.len) {
        const a: Vec = data[i..][0..vec_len].*;
        const is_nl = a == newline;
        const m = set.mask(a);
        if (m != 0) {
            const lead: usize = @ctz(~m); // the run continuing from the last block
            var hit: ?usize = null;
            if (carry + lead >= min) {
                hit = min - carry - 1; // carry < min, so this is in the block
            } else if (min <= vec_len) {
                var x = m;
                var len: usize = 1;
                while (len * 2 <= min) : (len *= 2) x &= x >> @intCast(len);
                if (len < min) x &= x >> @intCast(min - len);
                if (x != 0) hit = @ctz(x);
            }
            if (hit) |lane_| {
                const lane: Lane = @intCast(lane_);
                line += flush(&nl_acc, &nl_blocks);
                const nl_mask: Mask = @bitCast(is_nl);
                line += @popCount(nl_mask & ((@as(Mask, 1) << lane) - 1));
                i = try report(data, i + lane, &line, sink) orelse return line;
                carry = 0;
                continue;
            }
            carry = if (~m == 0) carry + vec_len else @clz(~m);
        } else carry = 0;
        nl_acc += @select(u8, is_nl, @as(Vec, @splat(1)), @as(Vec, @splat(0)));
        nl_blocks += 1;
        if (nl_blocks == 255) line += flush(&nl_acc, &nl_blocks);
        i += vec_len;
    }
    line += flush(&nl_acc, &nl_blocks);

    // Tail: fewer than vec_len bytes left.
    while (i < data.len) {
        if (set.contains(data[i])) {
            carry += 1;
            if (carry >= min) {
                i = try report(data, i, &line, sink) orelse return line;
                carry = 0;
                continue;
            }
        } else {
            carry = 0;
            line += @intFromBool(data[i] == '\n');
        }
        i += 1;
    }
    return line;
}

fn anyAt(comptime case: Case, data: []const u8, pos: usize, terms: []const []const u8) bool {
    for (terms) |t| {
        if (pos + t.len <= data.len and eql(case, data[pos..][0..t.len], t)) return true;
    }
    return false;
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

test "findLinesAny matches a line-by-line reference" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xa11);
    const rand = prng.random();
    const alphabet = "abAB\n";
    var data_buf: [700]u8 = undefined;
    var term_bufs: [max_terms][6]u8 = undefined;
    var terms: [max_terms][]const u8 = undefined;
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(gpa);
    var want: std.ArrayList(usize) = .empty;
    defer want.deinit(gpa);

    for (0..5_000) |_| {
        const data = data_buf[0..rand.uintAtMost(usize, data_buf.len)];
        for (data) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        const n_terms = 1 + rand.uintLessThan(usize, max_terms);
        for (terms[0..n_terms], term_bufs[0..n_terms]) |*t, *buf| {
            t.* = buf[0 .. 1 + rand.uintLessThan(usize, buf.len)];
            for (@constCast(t.*)) |*c| c.* = alphabet[rand.uintLessThan(usize, 4)];
        }
        const first_line = 1 + rand.uintLessThan(usize, 50);

        inline for (.{ Case.sensitive, Case.insensitive }) |case| {
            got.clearRetainingCapacity();
            want.clearRetainingCapacity();
            const after = try findLinesAny(case, data, terms[0..n_terms], first_line, CollectLines{ .gpa = gpa, .lines = &got, .first_line = first_line });
            var it = std.mem.splitScalar(u8, data, '\n');
            var ln = first_line;
            while (it.next()) |text| : (ln += 1) {
                for (terms[0..n_terms]) |t| {
                    const hit = if (case == .sensitive) std.mem.indexOf(u8, text, t) else std.ascii.findIgnoreCase(text, t);
                    if (hit != null) {
                        try want.append(gpa, ln);
                        break;
                    }
                }
            }
            try std.testing.expectEqualSlices(usize, want.items, got.items);
            try std.testing.expectEqual(first_line + std.mem.countScalar(u8, data, '\n'), after);
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

test "probes pick the rare bytes" {
    try std.testing.expectEqual([2]usize{ 1, 5 }, probes(" : public ", false)); // ':' and 'b'
    try std.testing.expectEqual([2]usize{ 0, 0 }, probes("x", false));
    try std.testing.expectEqual([2]usize{ 0, 1 }, probes("  ", false));
    try std.testing.expectEqual([2]usize{ 0, 7 }, probes("DenseMap", true)); // the ends are rare enough
}

test "findLinesRun matches a line-by-line reference" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7e5);
    const rand = prng.random();
    var buf: [300]u8 = undefined;
    var set: std.bit_set.Integer(256) = .empty;
    set.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true);
    set.setRangeValue(.{ .start = 'a', .end = 'f' + 1 }, true);
    const ranges = Ranges.of(set).?;
    try std.testing.expectEqual(2, ranges.n);
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(gpa);
    for (0..2000) |_| {
        const data = buf[0..rand.uintAtMost(usize, buf.len)];
        // Mostly set bytes, so long runs happen, broken by others and '\n'.
        for (data) |*c| c.* = "0123abcdefxyz\n"[@min(13, rand.uintLessThan(usize, 18))];
        const min = 1 + rand.uintLessThan(usize, 70);
        got.clearRetainingCapacity();
        const after = try findLinesRun(data, ranges, min, 1, CollectLines{ .gpa = gpa, .lines = &got, .first_line = 1 });
        var want: std.ArrayList(usize) = .empty;
        defer want.deinit(gpa);
        var it = std.mem.splitScalar(u8, data, '\n');
        var ln: usize = 1;
        while (it.next()) |l| : (ln += 1) {
            var run: usize = 0;
            var best: usize = 0;
            for (l) |c| {
                run = if (set.isSet(c)) run + 1 else 0;
                best = @max(best, run);
            }
            if (best >= min) try want.append(gpa, ln);
        }
        try std.testing.expectEqualSlices(usize, want.items, got.items);
        try std.testing.expectEqual(1 + std.mem.countScalar(u8, data, '\n'), after);
    }
}
