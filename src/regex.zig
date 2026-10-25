//! Regular expressions for `ffs -E`: a recursive-descent parser, a compiler
//! to a Thompson NFA and a Pike VM that answers one question: does this
//! line contain a match?
//!
//! Syntax (byte-oriented, ASCII classes):
//!
//!     x            a byte; \x is x literally for any non-alphanumeric x
//!     .            any byte
//!     [abc] [^a-z] classes, with ranges, \d \w \s and [:alpha:] etc. inside
//!     \d \w \s     ASCII digit, word byte [0-9A-Za-z_], whitespace
//!     \D \W \S     their complements
//!     \t \r \xNN  tab, carriage return, a byte in hex
//!     \b           word boundary
//!     ^ $          start and end of the line
//!     e* e+ e?     repetition; also e{n} e{n,} e{n,m}; a trailing ? is lazy
//!     e|f (e)      alternation, grouping; (?:e) is the same group
//!     (?i) (?i:e)  ignore case for the rest of the group, or inside e
//!
//! The VM runs in O(line length × program size) time with no backtracking,
//! so no pattern is catastrophically slow. Most of the time it doesn't run:
//! a lazy DFA built from the same program (dfa.zig) answers `isMatch` in
//! one table lookup per byte, and searches whole buffers for regexes with
//! no literal; the VM is left for `\b`, for `find`, and for patterns the
//! DFA gives up on. Compiling is bounded too: groups
//! and repetitions nest at most `max_depth` deep, as in ripgrep, and the
//! program has at most `max_prog` instructions. `Vm.isMatch` answers whether a
//! line matches; `Vm.find` also says where (leftmost-first, as in ripgrep),
//! for `-o`. Most lines never reach the VM: every match of most regexes
//! contains one of a few literals ("PM_" in `PM_[A-Z]+`; "cancel" or
//! "launch" in `func (cancel|launch)`), and the SIMD search in match.zig only
//! hands over lines that contain one. When the regex is nothing but those
//! literals (`foo|bar baz`), the VM is skipped altogether.

const std = @import("std");
const Allocator = std.mem.Allocator;
const match = @import("match.zig");
const pcre = @import("pcre.zig");
const Dfa = @import("dfa.zig").Dfa;

pub const Error = error{
    OutOfMemory,
    UnbalancedParen,
    BadClass,
    BadEscape,
    BadRepeat,
    NothingToRepeat,
    TooComplex,
    TooDeep,
    BadGroup,
};

/// Programs larger than this are rejected (e.g. `[a-z]{9999}`).
const max_prog = 10_000;

/// How deeply groups and repetitions may nest (ripgrep's limit). The parser,
/// the compiler and the literal analysis recurse once per level.
const max_depth = 250;

pub const Set = std.bit_set.Integer(256);

const Node = union(enum) {
    set: Set, // one byte from the set
    bol,
    eol,
    word_boundary,
    concat: []const Node, // empty: matches the empty string
    alt: []const Node, // two or more branches
    repeat: Repeat,
};

const Repeat = struct { node: *const Node, min: u32, max: ?u32, greedy: bool = true }; // null: unbounded

pub const Inst = union(enum) {
    set: Set, // consume one byte from the set
    split: [2]u32, // try both, first one preferred
    jmp: u32,
    bol,
    eol,
    word_boundary,
    match,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    prog: []const Inst,
    /// Every match contains one of these (none: nothing is required). With
    /// `ignore_case`, letters are lower-case and must be compared ignoring case.
    literals: []const []const u8,
    /// The regex matches exactly the lines containing one of `literals`.
    exact: bool,
    /// With no literal: a run of `min` bytes from `ranges` that every match
    /// contains, if one is rare enough to prefilter with (`[0-9a-f]{16}`).
    /// `exact`: the regex matches exactly the lines that have the run.
    run: ?Run = null,
    ignore_case: bool,
    /// Bytes that can start a match, or null if a match can start with an
    /// assertion or be empty. Lets the VM skip bytes while no thread is alive.
    first: ?Set,
    /// With `-Dpcre2`: the same pattern for PCRE2's JIT, which then does the
    /// VM's work. Not for patterns with `\b`, which PCRE2 sees in ASCII only.
    pcre: if (pcre.enabled) ?pcre.Pattern else void = if (pcre.enabled) null else {},

    pub fn compile(gpa: Allocator, pattern_arg: []const u8, ignore_case_arg: bool) Error!Regex {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        // A leading (?i) is the whole pattern ignoring case, which also lets
        // the prefilter use its literal.
        var ignore_case = ignore_case_arg;
        var pattern = pattern_arg;
        while (std.mem.startsWith(u8, pattern, "(?i)")) {
            ignore_case = true;
            pattern = pattern[4..];
        }

        var p: Parser = .{ .arena = a, .src = pattern, .fold = ignore_case };
        const root = try p.alt();
        if (p.i != pattern.len) return error.UnbalancedParen; // stray ')'
        if (try treeDepth(a, &root) > max_depth) return error.TooDeep;

        var c: Compiler = .{ .arena = a };
        try c.node(root);
        _ = try c.emit(.match);
        const literals = try required(a, root, ignore_case) orelse &.{};
        const first = try firstBytes(a, c.prog.items);
        const run = if (literals.len == 0) usableRun(root) else null;

        // Copy the arena last: allocations after the copy would be lost.
        const pcre_pattern = if (pcre.enabled) blk: {
            for (c.prog.items) |inst| if (inst == .word_boundary) break :blk null;
            break :blk pcre.Pattern.compile(pattern, ignore_case);
        } else {};
        return .{
            .pcre = pcre_pattern,
            .arena = arena,
            .prog = c.prog.items,
            .literals = literals,
            .exact = literals.len > 0 and onlyLiterals(root, ignore_case),
            .run = run,
            .ignore_case = ignore_case,
            .first = first,
        };
    }

    pub fn deinit(re: *Regex) void {
        if (pcre.enabled) if (re.pcre) |p| p.deinit();
        re.arena.deinit();
    }
};

/// Like `match.findLines`, for a regex: calls `sink.onLine` for each line of
/// `data` that contains a match, and returns the line number after `data`.
pub fn findLines(re: *const Regex, vm: *Vm, data: []const u8, first_line: usize, sink: anytype) !usize {
    if (re.exact) return prefilter(re, data, first_line, sink);
    const filter: Filter(@TypeOf(sink)) = .{ .re = re, .vm = vm, .sink = sink };
    if (re.literals.len == 0) {
        if (re.run) |r| {
            if (r.exact) return match.findLinesRun(data, r.ranges, r.min, first_line, sink);
            return match.findLinesRun(data, r.ranges, r.min, first_line, filter);
        }
        if (vm.dfa) |*d| if (!d.failed) {
            return d.findLines(data, first_line, sink) catch |err| switch (err) {
                error.GaveUp => everyLine(data, d.resume_pos, d.resume_line, filter),
                else => |e| e,
            };
        };
        if (pcre.enabled) if (re.pcre != null) return pcreLines(re, vm, data, first_line, filter);
        return everyLine(data, 0, first_line, filter);
    }
    return prefilter(re, data, first_line, filter);
}

// The lines containing one of `re.literals`.
fn prefilter(re: *const Regex, data: []const u8, first_line: usize, sink: anytype) !usize {
    const lits = re.literals;
    if (lits.len == 1) {
        if (re.ignore_case) return match.findLinesIgnoreCase(data, lits[0], first_line, sink);
        return match.findLines(data, lits[0], first_line, sink);
    }
    if (re.ignore_case) return match.findLinesAny(.insensitive, data, lits, first_line, sink);
    return match.findLinesAny(.sensitive, data, lits, first_line, sink);
}

// A sink that passes on only the lines the VM accepts.
fn Filter(comptime Sink: type) type {
    return struct {
        re: *const Regex,
        vm: *Vm,
        sink: Sink,

        pub fn onLine(f: @This(), m: match.Match) !void {
            if (f.vm.isMatch(f.re, m.text())) try f.sink.onLine(m);
        }
    };
}

// No literal, with PCRE2: let it scan the whole buffer. A match there may
// run across a newline (`\s` and `[^a]` match '\n'), so one that does is
// checked again on its first line alone. That can't skip a real match: any
// match within a line is also a match in the buffer, so the scan stops at or
// before it. If PCRE2 gives up (a match or JIT stack limit), the rest of the
// buffer goes line by line, where the Pike VM takes over from it.
fn pcreLines(re: *const Regex, vm: *Vm, data: []const u8, first_line: usize, filter: anytype) !usize {
    const p = re.pcre.?;
    const m = vm.pcre.?;
    const sink = filter.sink;
    var line = first_line;
    var counted: usize = 0; // newlines before this offset are in `line`
    var pos: usize = 0; // a line start
    while (pos < data.len) {
        const found = m.find(p, data, pos) catch
            return everyLine(data, pos, line + std.mem.countScalar(u8, data[counted..pos], '\n'), filter);
        const span = found orelse break;
        if (span.start >= data.len) break; // an empty match after the last '\n'
        const start = if (std.mem.findScalarLast(u8, data[pos..span.start], '\n')) |nl| pos + nl + 1 else pos;
        const end = std.mem.indexOfScalarPos(u8, data, span.start, '\n') orelse data.len;
        line += std.mem.countScalar(u8, data[counted..start], '\n');
        counted = start;
        if (span.end <= end or vm.isMatch(re, data[start..end])) {
            try sink.onLine(match.Match{ .line = line, .data = data, .pos = span.start, .end = end });
        }
        pos = end + 1;
    }
    return line + std.mem.countScalar(u8, data[counted..], '\n');
}

// No required literal: every line from `from` (a line start) on is a candidate.
fn everyLine(data: []const u8, from: usize, first_line: usize, sink: anytype) !usize {
    var line = first_line;
    var start = from;
    while (start < data.len) {
        const end = std.mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
        try sink.onLine(match.Match{ .line = line, .data = data, .pos = start, .end = end });
        if (end == data.len) break;
        line += 1;
        start = end + 1;
    }
    return line;
}

// ---------------------------------------------------------------- parser

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    i: usize = 0,
    fold: bool, // ignore case: letters match both cases
    groups: usize = 0, // groups open around `i`

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    // alt := concat ('|' concat)*
    fn alt(p: *Parser) Error!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(p.arena, try p.concat());
        while (p.peek() == '|') {
            p.i += 1;
            try branches.append(p.arena, try p.concat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    // concat := repeat*
    fn concat(p: *Parser) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try items.append(p.arena, try p.repeat());
        }
        return .{ .concat = items.items };
    }

    // repeat := atom ('*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}')*
    fn repeat(p: *Parser) Error!Node {
        var node = try p.atom();
        while (p.peek()) |c| {
            const r: [2]?u32 = switch (c) {
                '*' => .{ 0, null },
                '+' => .{ 1, null },
                '?' => .{ 0, 1 },
                '{' => try p.counted(),
                else => break,
            };
            if (c != '{') p.i += 1;
            const greedy = p.peek() != '?';
            if (!greedy) p.i += 1;
            const inner = try p.arena.create(Node);
            inner.* = node;
            node = .{ .repeat = .{ .node = inner, .min = r[0].?, .max = r[1], .greedy = greedy } };
        }
        return node;
    }

    // '{n}', '{n,}' or '{n,m}'.
    fn counted(p: *Parser) Error![2]?u32 {
        p.i += 1; // '{'
        const min = p.number() orelse return error.BadRepeat;
        var max: ?u32 = min;
        if (p.peek() == ',') {
            p.i += 1;
            max = p.number(); // none: unbounded
        }
        if (p.peek() != '}') return error.BadRepeat;
        p.i += 1;
        if (max != null and max.? < min) return error.BadRepeat;
        return .{ min, max };
    }

    fn number(p: *Parser) ?u32 {
        const start = p.i;
        while (p.peek()) |c| : (p.i += 1) if (!std.ascii.isDigit(c)) break;
        return std.fmt.parseInt(u32, p.src[start..p.i], 10) catch null;
    }

    fn atom(p: *Parser) Error!Node {
        const c = p.src[p.i]; // concat checked there is one
        p.i += 1;
        switch (c) {
            '(' => {
                // Checked here as well as in `treeDepth`: this recursion
                // happens before there is a tree to measure.
                p.groups += 1;
                defer p.groups -= 1;
                if (p.groups > max_depth) return error.TooDeep;
                const outer_fold = p.fold;
                if (p.peek() == '?') {
                    p.i += 1;
                    while (p.peek() == 'i') : (p.i += 1) p.fold = true;
                    switch (p.peek() orelse return error.BadGroup) {
                        ':' => p.i += 1,
                        ')' => {
                            // (?i): the flag stays on to the end of the enclosing group.
                            p.i += 1;
                            return .{ .concat = &.{} };
                        },
                        else => return error.BadGroup,
                    }
                }
                const inner = try p.alt();
                p.fold = outer_fold; // flags set inside a group end with it
                if (p.peek() != ')') return error.UnbalancedParen;
                p.i += 1;
                return inner;
            },
            '*', '+', '?', '{' => return error.NothingToRepeat,
            '.' => return .{ .set = .full },
            '^' => return .bol,
            '$' => return .eol,
            '[' => return .{ .set = try p.class() },
            '\\' => {
                if (p.peek() == 'b') {
                    p.i += 1;
                    return .word_boundary;
                }
                return .{ .set = try p.escape() };
            },
            else => return .{ .set = p.byte(c) },
        }
    }

    fn byte(p: *const Parser, c: u8) Set {
        var s: Set = .empty;
        s.set(c);
        if (p.fold) s = foldCase(s);
        return s;
    }

    // After a '\': a class (\d \w \s and complements) or a literal byte.
    fn escape(p: *Parser) Error!Set {
        const c = p.peek() orelse return error.BadEscape;
        p.i += 1;
        var s: Set = .empty;
        switch (c) {
            'd', 'D' => s.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true),
            'w', 'W' => for (0..256) |b| {
                if (isWord(@intCast(b))) s.set(b);
            },
            's', 'S' => for (" \t\r\x0b\x0c") |b| s.set(b),
            't' => return p.byte('\t'),
            'r' => return p.byte('\r'),
            'x' => {
                if (p.i + 2 > p.src.len) return error.BadEscape;
                const b = std.fmt.parseInt(u8, p.src[p.i..][0..2], 16) catch return error.BadEscape;
                p.i += 2;
                if (b == '\n') return error.BadEscape;
                return p.byte(b);
            },
            else => {
                // Other letter escapes are errors: \n, for one, can't occur in a line.
                if (std.ascii.isAlphanumeric(c)) return error.BadEscape;
                return p.byte(c);
            },
        }
        if (std.ascii.isUpper(c)) s.toggleAll(); // \D \W \S
        return s;
    }

    // After a '[': members up to ']'. A ']' right after '[' or '[^' is a
    // member; so is a '-' that does not form a range. Ranges are between
    // plain bytes only.
    fn class(p: *Parser) Error!Set {
        var s: Set = .empty;
        const negate = p.peek() == '^';
        if (negate) p.i += 1;
        var first = true;
        while (true) : (first = false) {
            const c = p.peek() orelse return error.BadClass;
            if (c == ']' and !first) break;
            p.i += 1;
            if (c == '\\') {
                s.setUnion(try p.escape());
                continue;
            }
            if (c == '[' and p.peek() == ':') {
                if (posixClass(p.src[p.i..])) |pc| {
                    s.setUnion(pc.set);
                    p.i += pc.len;
                    continue;
                }
            }
            if (p.peek() == '-' and p.i + 1 < p.src.len and p.src[p.i + 1] != ']') {
                const hi = p.src[p.i + 1];
                if (hi == '\\' or hi < c) return error.BadClass;
                p.i += 2;
                s.setRangeValue(.{ .start = c, .end = @as(usize, hi) + 1 }, true);
            } else {
                s.set(c);
            }
        }
        p.i += 1; // ']'
        if (p.fold) s = foldCase(s);
        if (negate) s.toggleAll();
        return s;
    }
};

// `[:name:]` after a class's '[': the set and the bytes it spans after the
// '['. Unknown names are left to be read as plain members.
fn posixClass(src: []const u8) ?struct { set: Set, len: usize } {
    const end = std.mem.indexOf(u8, src, ":]") orelse return null;
    if (end < 1) return null;
    const name = src[1..end];
    const negate = name.len > 0 and name[0] == '^';
    const pred: *const fn (u8) bool = inline for (.{
        .{ "alpha", std.ascii.isAlphabetic },   .{ "digit", std.ascii.isDigit },
        .{ "alnum", std.ascii.isAlphanumeric }, .{ "upper", std.ascii.isUpper },
        .{ "lower", std.ascii.isLower },        .{ "space", std.ascii.isWhitespace },
        .{ "punct", isPunct },                  .{ "xdigit", std.ascii.isHex },
        .{ "word", isWord },                    .{ "blank", isBlank },
    }) |entry| {
        if (std.mem.eql(u8, name[@intFromBool(negate)..], entry[0])) break entry[1];
    } else return null;
    var s: Set = .empty;
    for (0..256) |b| if (pred(@intCast(b))) s.set(b);
    if (negate) s.toggleAll();
    return .{ .set = s, .len = end + 2 };
}

fn isPunct(c: u8) bool {
    return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// `literal` as a pattern that matches it exactly: every non-alphanumeric
/// byte escaped. Caller owns the result.
pub fn escape(gpa: Allocator, literal: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (literal) |c| {
        // Bytes of 0x80 and up are literal anyway, and must stay together in UTF-8.
        if (!std.ascii.isAlphanumeric(c) and c < 0x80 and c != ' ') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

// Adds the other case of every ASCII letter in `s`.
fn foldCase(s: Set) Set {
    var out = s;
    for ('A'..'Z' + 1) |u| {
        const l = u + ('a' - 'A');
        if (s.isSet(u) or s.isSet(l)) {
            out.set(u);
            out.set(l);
        }
    }
    return out;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// How deeply concatenations, alternations and repetitions nest, without
// recursing: `x++++…` is a chain of repetitions as long as the pattern.
fn treeDepth(a: Allocator, root: *const Node) Error!usize {
    const Item = struct { node: *const Node, depth: usize };
    var stack: std.ArrayList(Item) = .empty;
    try stack.append(a, .{ .node = root, .depth = 1 });
    var deepest: usize = 0;
    while (stack.pop()) |it| {
        deepest = @max(deepest, it.depth);
        switch (it.node.*) {
            .concat, .alt => |items| for (items) |*item| try stack.append(a, .{ .node = item, .depth = it.depth + 1 }),
            .repeat => |r| try stack.append(a, .{ .node = r.node, .depth = it.depth + 1 }),
            .set, .bol, .eol, .word_boundary => {},
        }
    }
    return deepest;
}

// ---------------------------------------------------------------- required literal

// Literals every match contains one of, for the SIMD prefilter; null if
// there are none. A run of single bytes in a concatenation is one literal
// (anchors don't break a run); an alternation is the union of its
// branches' literals. Of the candidates in a concatenation, the set that
// should occur least often in source code wins (`score`), then the
// smaller set.
fn required(a: Allocator, n: Node, fold: bool) Error!?[]const []const u8 {
    switch (n) {
        .set => |s| return if (literalByte(s, fold)) |b| try one(a, &.{b}) else null,
        .repeat => |r| return if (r.min > 0) required(a, r.node.*, fold) else null,
        .bol, .eol, .word_boundary => return null,
        .alt => |branches| {
            var all: std.ArrayList([]const u8) = .empty;
            for (branches) |b| {
                const lits = try required(a, b, fold) orelse return null;
                for (lits) |lit| {
                    for (all.items) |have| {
                        if (std.mem.eql(u8, have, lit)) break;
                    } else try all.append(a, lit);
                }
            }
            if (all.items.len > match.max_terms) return null;
            return all.items;
        },
        .concat => |items| {
            var best: ?[]const []const u8 = null;
            var run: std.ArrayList(u8) = .empty;
            for (items) |item| {
                switch (item) {
                    .set => |s| if (literalByte(s, fold)) |b| {
                        try run.append(a, b);
                        continue;
                    },
                    .bol, .eol, .word_boundary => continue,
                    else => {},
                }
                if (run.items.len > 0) best = better(best, try one(a, run.items), fold);
                run = .empty;
                best = better(best, try required(a, item, fold), fold);
            }
            if (run.items.len > 0) best = better(best, try one(a, run.items), fold);
            return best;
        },
    }
}

fn one(a: Allocator, lit: []const u8) Error![]const []const u8 {
    const out = try a.alloc([]const u8, 1);
    out[0] = try a.dupe(u8, lit);
    return out;
}

fn better(x: ?[]const []const u8, y: ?[]const []const u8, fold: bool) ?[]const []const u8 {
    const xs = x orelse return y;
    const ys = y orelse return x;
    const x_bits = score(xs, fold);
    const y_bits = score(ys, fold);
    if (y_bits != x_bits) return if (y_bits > x_bits) y else x;
    return if (ys.len < xs.len) y else x;
}

// How rare a line position starting one of `lits` is, in bits (-log2 of
// its estimated frequency), taking a literal's bytes as independent, with
// the frequencies in `match.rarity`. "class " is 30 bits, "_" alone 5,
// {"spin", "mutex"} 22: about as rare as "spin" alone.
// `rareness`, less 4 bits for each literal after the first: the SIMD search
// for two literals takes ~40% longer than for one, which only pays if they
// are much rarer. "dict" (21 bits) beats {"Find", "Delete"} (24).
fn score(lits: []const []const u8, fold: bool) f64 {
    return rareness(lits, fold) - 4 * @as(f64, @floatFromInt(lits.len - 1));
}

fn rareness(lits: []const []const u8, fold: bool) f64 {
    var p: f64 = 0;
    for (lits) |lit| {
        var bits: f64 = 0;
        for (lit) |c| bits += @as(f64, @floatFromInt(match.byteRarity(c, fold))) / 4;
        p += std.math.exp2(-bits);
    }
    return -std.math.log2(p);
}

pub const Run = struct { ranges: match.Ranges, min: usize, exact: bool };

// A class run worth prefiltering with: one `match.findLinesRun` can test
// (few ranges), and rare enough that the SIMD scan rejects most lines
// (`min_run_bits`). `\w{3}` is not: most lines have one.
fn usableRun(root: Node) ?Run {
    const r = classRun(root) orelse return null;
    if (runBits(r) < min_run_bits) return null;
    const ranges = match.Ranges.of(r.set) orelse return null;
    return .{ .ranges = ranges, .min = r.min, .exact = r.exact };
}

// About one position in 256 or fewer starts a run.
const min_run_bits = 8;

const ClassRun = struct { set: Set, min: usize, exact: bool };

// A run of at least `min` consecutive bytes from `set` that every match of
// `n` contains: a repeated set, or consecutive ones in a concatenation when
// each set contains the last or is contained in it (the run is then from
// the larger). `exact`: `n` is the run and nothing else, so a line matches
// exactly when it has the run. '\n' is never in the set: a run is in a line.
fn classRun(n: Node) ?ClassRun {
    switch (n) {
        .set, .repeat => {
            if (simpleRun(n)) |r| return withoutNewline(r);
            if (n == .set or n.repeat.min == 0) return null;
            var inner = classRun(n.repeat.node.*) orelse return null;
            inner.exact = false;
            return inner;
        },
        .concat => |items| {
            var best: ?ClassRun = null;
            var cur: ?ClassRun = null;
            for (items) |item| {
                if (simpleRun(item)) |nx| {
                    if (cur) |*c| {
                        if (nx.set.subsetOf(c.set) or c.set.subsetOf(nx.set)) {
                            c.set.setUnion(nx.set);
                            c.min += nx.min;
                            continue;
                        }
                        best = betterRun(best, c.*);
                    }
                    cur = nx;
                    continue;
                }
                if (cur) |c| best = betterRun(best, c);
                cur = null;
                if (classRun(item)) |r| best = betterRun(best, r);
            }
            if (cur) |c| best = betterRun(best, c);
            var r = withoutNewline(best) orelse return null;
            // Exact: every item is the same set, alone or repeated.
            r.exact = items.len > 0 and for (items) |item| {
                const x = simpleRun(item) orelse break false;
                if (!x.set.eql(simpleRun(items[0]).?.set)) break false;
            } else true;
            return r;
        },
        else => return null,
    }
}

// A set, or a set repeated at least once.
fn simpleRun(n: Node) ?ClassRun {
    return switch (n) {
        .set => |s| .{ .set = s, .min = 1, .exact = true },
        .repeat => |r| if (r.min > 0 and r.node.* == .set) .{ .set = r.node.set, .min = r.min, .exact = true } else null,
        else => null,
    };
}

fn withoutNewline(r: ?ClassRun) ?ClassRun {
    var x = r orelse return null;
    x.set.unset('\n');
    if (x.set.count() == 0) return null;
    return x;
}

fn betterRun(x: ?ClassRun, y: ClassRun) ClassRun {
    const xr = x orelse return y;
    return if (runBits(y) > runBits(xr)) y else xr;
}

// How rare a run is: -log2 of the chance that `min` given bytes are all in
// the set, with byte frequencies from `match.rarity`.
fn runBits(r: ClassRun) f64 {
    var p: f64 = 0;
    for (0..256) |b| {
        if (b != '\n' and r.set.isSet(b)) p += std.math.exp2(-@as(f64, @floatFromInt(match.rarity[b])) / 4);
    }
    if (p <= 0) return std.math.inf(f64);
    return -std.math.log2(@min(1.0, p)) * @as(f64, @floatFromInt(r.min));
}

// Is the regex nothing but literal strings, alone or as alternatives? Then a
// line contains a match exactly when it contains one of them.
fn onlyLiterals(n: Node, fold: bool) bool {
    return switch (n) {
        .set => |s| literalByte(s, fold) != null,
        // `(foo|bar)` is a concatenation of one alternation. Other nesting
        // is not unwrapped: in `(ab)c` the literal found is "ab", not "abc".
        .concat => |items| if (items.len == 1 and items[0] != .set) onlyLiterals(items[0], fold) else items.len > 0 and for (items) |item| {
            if (item != .set or literalByte(item.set, fold) == null) break false;
        } else true,
        .alt => |branches| for (branches) |b| {
            if (!onlyLiterals(b, fold)) break false;
        } else true,
        else => false,
    };
}

// The byte a set stands for, if it is a single byte (or, ignoring case, a
// single letter in both cases, returned lower-case).
fn literalByte(s: Set, fold: bool) ?u8 {
    const lo: u8 = @intCast(s.findFirstSet() orelse return null);
    if (s.count() == 1) return lo;
    if (fold and s.count() == 2 and std.ascii.isUpper(lo) and s.isSet(std.ascii.toLower(lo))) return std.ascii.toLower(lo);
    return null;
}

// The union of the byte sets reachable from pc 0 without consuming a byte.
fn firstBytes(a: Allocator, prog: []const Inst) Error!?Set {
    var first: Set = .empty;
    const seen = try a.alloc(bool, prog.len);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, 0);
    while (stack.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        switch (prog[pc]) {
            .set => |s| first.setUnion(s),
            .jmp => |t| try stack.append(a, t),
            .split => |t| try stack.appendSlice(a, &t),
            .match, .bol, .eol, .word_boundary => return null,
        }
    }
    return first;
}

// ---------------------------------------------------------------- compiler

const Compiler = struct {
    arena: Allocator,
    prog: std.ArrayList(Inst) = .empty,

    fn emit(c: *Compiler, inst: Inst) Error!u32 {
        if (c.prog.items.len >= max_prog) return error.TooComplex;
        try c.prog.append(c.arena, inst);
        return @intCast(c.prog.items.len - 1);
    }

    fn here(c: *const Compiler) u32 {
        return @intCast(c.prog.items.len);
    }

    fn node(c: *Compiler, n: Node) Error!void {
        switch (n) {
            .set => |s| _ = try c.emit(.{ .set = s }),
            .bol => _ = try c.emit(.bol),
            .eol => _ = try c.emit(.eol),
            .word_boundary => _ = try c.emit(.word_boundary),
            .concat => |items| for (items) |item| try c.node(item),
            .alt => |branches| {
                // split L1 L2; L1: a; jmp end; L2: split ...; last branch; end:
                var jumps: std.ArrayList(u32) = .empty;
                for (branches[0 .. branches.len - 1]) |b| {
                    const split = try c.emit(.{ .split = undefined });
                    try c.node(b);
                    try jumps.append(c.arena, try c.emit(.{ .jmp = undefined }));
                    c.prog.items[split] = .{ .split = .{ split + 1, c.here() } };
                }
                try c.node(branches[branches.len - 1]);
                for (jumps.items) |j| c.prog.items[j] = .{ .jmp = c.here() };
            },
            .repeat => |r| {
                for (0..r.min) |k| {
                    const before = c.here();
                    try c.node(r.node.*);
                    // A body that compiles to nothing matches only the empty
                    // string, however often it is repeated: `(){4294967295}`
                    // must not loop four billion times.
                    if (k == 0 and c.here() == before) return;
                }
                if (r.max) |max| {
                    // Each optional copy: split body end. Skipping one skips the rest.
                    var splits: std.ArrayList(u32) = .empty;
                    for (r.min..max) |_| {
                        try splits.append(c.arena, try c.emit(.{ .split = undefined }));
                        try c.node(r.node.*);
                    }
                    for (splits.items) |s| c.prog.items[s] = .{ .split = order(r.greedy, s + 1, c.here()) };
                } else {
                    // L: split body end; body; jmp L; end:
                    const split = try c.emit(.{ .split = undefined });
                    try c.node(r.node.*);
                    _ = try c.emit(.{ .jmp = split });
                    c.prog.items[split] = .{ .split = order(r.greedy, split + 1, c.here()) };
                }
            },
        }
    }
};

// A repetition's split: greedy prefers another round of the body, lazy
// prefers leaving.
fn order(greedy: bool, body: u32, end: u32) [2]u32 {
    return if (greedy) .{ body, end } else .{ end, body };
}

// ---------------------------------------------------------------- VM

/// A match: `line[start..end]`.
pub const Span = struct { start: usize, end: usize };

/// Scratch space for matching. One per thread; reused for every line.
pub const Vm = struct {
    clist: []u32, // threads at the current position (pcs of `set` instructions)
    nlist: []u32, // threads at the next position
    cstart: []usize, // with `find`: where clist[k]'s match started
    nstart: []usize,
    seen: []usize, // seen[pc] == gen: pc already added at this position
    stack: []u32, // pcs to follow in `add`
    gen: usize = 0,
    pcre: if (pcre.enabled) ?pcre.Matcher else void = if (pcre.enabled) null else {},
    dfa: ?Dfa = null, // null for a pattern with `\b`

    pub fn init(gpa: Allocator, re: *const Regex) !Vm {
        const n = re.prog.len;
        const seen = try gpa.alloc(usize, n);
        @memset(seen, 0);
        return .{
            .dfa = try Dfa.init(gpa, re.prog),
            .pcre = if (pcre.enabled) (if (re.pcre) |p| try pcre.Matcher.init(p) else null) else {},
            .clist = try gpa.alloc(u32, n),
            .nlist = try gpa.alloc(u32, n),
            .cstart = try gpa.alloc(usize, n),
            .nstart = try gpa.alloc(usize, n),
            .seen = seen,
            .stack = try gpa.alloc(u32, 2 * n + 1),
        };
    }

    pub fn deinit(vm: *Vm, gpa: Allocator) void {
        if (pcre.enabled) if (vm.pcre) |m| m.deinit();
        if (vm.dfa) |*d| d.deinit();
        gpa.free(vm.clist);
        gpa.free(vm.nlist);
        gpa.free(vm.cstart);
        gpa.free(vm.nstart);
        gpa.free(vm.seen);
        gpa.free(vm.stack);
    }

    /// Does `line` contain a match? The DFA answers if it can, then PCRE2,
    /// then the Pike VM.
    pub fn isMatch(vm: *Vm, re: *const Regex, line: []const u8) bool {
        if (vm.dfa) |*d| if (d.isMatch(line)) |m| return m;
        if (pcre.enabled) if (re.pcre) |p| {
            // On an error (a PCRE2 limit) the VM answers instead.
            if (vm.pcre.?.find(p, line, 0)) |m| return m != null else |_| {}
        };
        return vm.pike(re, line);
    }

    // `isMatch` on the Pike VM: runs all threads in lockstep, one byte at a
    // time, starting a new thread at every position (skipping ahead with
    // `first` while none is alive).
    fn pike(vm: *Vm, re: *const Regex, line: []const u8) bool {
        var n_cur: usize = 0;
        vm.gen += 1;
        var i: usize = 0;
        while (true) : (i += 1) {
            if (n_cur == 0) if (re.first) |first| {
                // No live threads: jump to the next byte that can start a match.
                while (i < line.len and !first.isSet(line[i])) i += 1;
                if (i == line.len) return false;
                vm.gen += 1;
            };
            if (vm.add(re, vm.clist, &n_cur, 0, line, i)) return true;
            if (i == line.len or (n_cur == 0 and isAnchored(re))) return false;
            vm.gen += 1;
            var n_next: usize = 0;
            for (vm.clist[0..n_cur]) |pc| {
                if (re.prog[pc].set.isSet(line[i]) and vm.add(re, vm.nlist, &n_next, pc + 1, line, i + 1)) return true;
            }
            std.mem.swap([]u32, &vm.clist, &vm.nlist);
            n_cur = n_next;
        }
    }

    /// The leftmost-first match in `line` starting at or after `from`, as a
    /// backtracking engine would report it (ripgrep's semantics). Slower
    /// than `isMatch`: every thread carries its start position, and the run
    /// continues past the first `match` while a preferred thread could still
    /// make the match longer.
    pub fn find(vm: *Vm, re: *const Regex, line: []const u8, from: usize) ?Span {
        if (pcre.enabled) if (re.pcre) |p| {
            if (vm.pcre.?.find(p, line, from)) |found| {
                const m = found orelse return null;
                return .{ .start = m.start, .end = m.end };
            } else |_| {}
        };
        var found: ?Span = null;
        var n_cur: usize = 0;
        vm.gen += 1;
        var i: usize = from;
        while (true) : (i += 1) {
            if (found == null) {
                if (n_cur == 0) if (re.first) |first| {
                    while (i < line.len and !first.isSet(line[i])) i += 1;
                    if (i == line.len) return null;
                    vm.gen += 1;
                };
                // The new thread starting here has the lowest priority.
                if (n_cur == 0 or !isAnchored(re)) vm.addFind(re, vm.clist, vm.cstart, &n_cur, 0, i, line, i);
            } else if (n_cur == 0) break;
            vm.gen += 1;
            var n_next: usize = 0;
            for (vm.clist[0..n_cur], vm.cstart[0..n_cur]) |pc, start| {
                switch (re.prog[pc]) {
                    .match => {
                        // Every thread after this one is less preferred.
                        found = .{ .start = start, .end = i };
                        break;
                    },
                    .set => |s| if (i < line.len and s.isSet(line[i])) vm.addFind(re, vm.nlist, vm.nstart, &n_next, pc + 1, start, line, i + 1),
                    else => unreachable,
                }
            }
            if (i == line.len) break;
            std.mem.swap([]u32, &vm.clist, &vm.nlist);
            std.mem.swap([]usize, &vm.cstart, &vm.nstart);
            n_cur = n_next;
            if (found != null and n_cur == 0) break;
        }
        return found;
    }

    // `add` for `find`: keeps `match` in the list, in priority order, and
    // records each thread's start.
    fn addFind(vm: *Vm, re: *const Regex, list: []u32, starts: []usize, n: *usize, pc0: u32, start: usize, line: []const u8, i: usize) void {
        var sp: usize = 1;
        vm.stack[0] = pc0;
        while (sp > 0) {
            sp -= 1;
            const pc = vm.stack[sp];
            if (vm.seen[pc] == vm.gen) continue;
            vm.seen[pc] = vm.gen;
            const follow = switch (re.prog[pc]) {
                .match, .set => {
                    list[n.*] = pc;
                    starts[n.*] = start;
                    n.* += 1;
                    continue;
                },
                .jmp => |t| t,
                .split => |t| {
                    vm.stack[sp] = t[1];
                    vm.stack[sp + 1] = t[0];
                    sp += 2;
                    continue;
                },
                .bol => if (i == 0) pc + 1 else continue,
                .eol => if (i == line.len) pc + 1 else continue,
                .word_boundary => if (wordBoundary(line, i)) pc + 1 else continue,
            };
            vm.stack[sp] = follow;
            sp += 1;
        }
    }

    // Adds the thread at `start` and everything reachable from it without
    // consuming a byte. Returns true if that reaches `match`.
    fn add(vm: *Vm, re: *const Regex, list: []u32, n: *usize, start: u32, line: []const u8, i: usize) bool {
        var sp: usize = 1;
        vm.stack[0] = start;
        while (sp > 0) {
            sp -= 1;
            const pc = vm.stack[sp];
            if (vm.seen[pc] == vm.gen) continue;
            vm.seen[pc] = vm.gen;
            const follow = switch (re.prog[pc]) {
                .match => return true,
                .set => {
                    list[n.*] = pc;
                    n.* += 1;
                    continue;
                },
                .jmp => |t| t,
                .split => |t| {
                    vm.stack[sp] = t[1];
                    vm.stack[sp + 1] = t[0];
                    sp += 2;
                    continue;
                },
                .bol => if (i == 0) pc + 1 else continue,
                .eol => if (i == line.len) pc + 1 else continue,
                .word_boundary => if (wordBoundary(line, i)) pc + 1 else continue,
            };
            vm.stack[sp] = follow;
            sp += 1;
        }
        return false;
    }
};

// A pattern starting with '^' can't match once all threads have died.
fn isAnchored(re: *const Regex) bool {
    return re.prog[0] == .bol;
}

// `\b`, as in ripgrep, sees whole UTF-8 characters: in `返回ERR_PTR` there
// is no boundary before `E`. Which non-ASCII characters are word characters
// is approximated by `isWordCodepoint`.
fn wordBoundary(line: []const u8, i: usize) bool {
    return wordBefore(line, i) != wordAt(line, i);
}

fn wordAt(line: []const u8, i: usize) bool {
    if (i >= line.len) return false;
    if (line[i] < 0x80) return isWord(line[i]);
    const len = std.unicode.utf8ByteSequenceLength(line[i]) catch return false;
    if (i + len > line.len) return false;
    const cp = std.unicode.utf8Decode(line[i..][0..len]) catch return false;
    return isWordCodepoint(cp);
}

fn wordBefore(line: []const u8, i: usize) bool {
    if (i == 0) return false;
    if (line[i - 1] < 0x80) return isWord(line[i - 1]);
    // Back over up to three continuation bytes to the lead byte.
    var start = i - 1;
    while (start > 0 and i - start < 4 and line[start] & 0xc0 == 0x80) start -= 1;
    const len = std.unicode.utf8ByteSequenceLength(line[start]) catch return false;
    if (start + len != i) return false;
    return wordAt(line, start);
}

// Unicode's \w is letters, marks, digits and connector punctuation. Every
// non-ASCII character counts, except the blocks of punctuation, symbols and
// spaces that turn up next to code and prose: Latin-1 punctuation, general
// punctuation, arrows and math, CJK and full-width punctuation, emoji.
fn isWordCodepoint(cp: u21) bool {
    return switch (cp) {
        0x80...0xa9, 0xab...0xb4, 0xb6...0xb9, 0xbb...0xbf, 0xd7, 0xf7 => false,
        0x2000...0x200b, 0x200e...0x203e, 0x2041...0x2053, 0x2055...0x206f => false,
        0x20a0...0x20cf, 0x2190...0x2bff, 0x2e00...0x2e7f => false,
        0x3000...0x3004, 0x3008...0x3020, 0x3030, 0x303d...0x303f => false,
        0xfe30...0xfe32, 0xfe35...0xfe4c, 0xfe50...0xfe6f => false,
        0xff00...0xff0f, 0xff1a...0xff20, 0xff3b...0xff3e, 0xff40, 0xff5b...0xff65 => false,
        0x1f000...0x1faff => false,
        else => true,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectMatch(pattern: []const u8, line: []const u8, ignore_case: bool, expected: bool) !void {
    var re = try Regex.compile(testing.allocator, pattern, ignore_case);
    defer re.deinit();
    var vm = try Vm.init(testing.allocator, &re);
    defer vm.deinit(testing.allocator);
    if (vm.isMatch(&re, line) != expected) {
        std.debug.print("pattern {s} line \"{s}\": expected {}\n", .{ pattern, line, expected });
        return error.TestUnexpectedResult;
    }
}

test "regex syntax" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "abc", "xxabcxx", true },
        .{ "abc", "ab c", false },
        .{ "a.c", "abc", true },
        .{ "a.c", "ac", false },
        .{ "^abc", "abcd", true },
        .{ "^abc", "xabc", false },
        .{ "abc$", "xabc", true },
        .{ "abc$", "abcx", false },
        .{ "^$", "", true },
        .{ "^$", "x", false },
        .{ "ab*c", "ac", true },
        .{ "ab*c", "abbbc", true },
        .{ "ab+c", "ac", false },
        .{ "ab+c", "abbc", true },
        .{ "ab?c", "abc", true },
        .{ "ab?c", "abbc", false },
        .{ "a{3}", "aa", false },
        .{ "a{3}", "aaa", true },
        .{ "^a{2,3}$", "aaaa", false },
        .{ "^a{2,3}$", "aaa", true },
        .{ "^a{2,}$", "aaaaaa", true },
        .{ "^a{2,}$", "a", false },
        .{ "^a{0}b", "b", true },
        .{ "cat|dog", "hotdog", true },
        .{ "cat|dog", "cow", false },
        .{ "^(cat|dog)s?$", "dogs", true },
        .{ "^(cat|dog)s?$", "dogsx", false },
        .{ "(ab)+$", "xababab", true },
        .{ "^(a|)$", "", true },
        .{ "()*x", "x", true },
        .{ "[abc]+", "xxbxx", true },
        .{ "[abc]", "xyz", false },
        .{ "[^abc]", "abc", false },
        .{ "[^abc]", "abcd", true },
        .{ "[a-f0-9]{4}", "zz9f3c", true },
        .{ "[a-f0-9]{4}", "zz9g3c", false },
        .{ "[]a]", "]", true },
        .{ "[^]a]", "]a", false },
        .{ "[a-]", "-", true },
        .{ "[\\d.]+$", "v1.2", true },
        .{ "\\d+", "abc", false },
        .{ "\\d+", "a1", true },
        .{ "^\\D+$", "abc", true },
        .{ "\\w+_lock\\(", "spin_lock(&x)", true },
        .{ "^\\W", "_x", false },
        .{ "\\s", "a\tb", true },
        .{ "^\\S+$", "a b", false },
        .{ "\\t", "a\tb", true },
        .{ "\\bfoo\\b", "a foo b", true },
        .{ "\\bfoo\\b", "afoo", false },
        .{ "\\bfoo\\b", "foo_", false },
        .{ "\\bERR\\b", "\xe8\xbf\x94ERR", false }, // after a CJK letter: no boundary
        .{ "\\bERR\\b", "\xef\xbc\x88ERR\xef\xbc\x89", true }, // full-width parentheses
        .{ "\\bERR\\b", "caf\xc3\xa9 ERR", true },
        .{ "\\bcaf", "\xc3\xa9caf", false },
        .{ "\\.", "a.b", true },
        .{ "\\.", "ab", false },
        .{ "a\\|b", "a|b", true },
        .{ "\\(x\\)", "f(x)", true },
        .{ "\\[", "[", true },
        .{ "\\\\", "a\\b", true },
        .{ "(a*)*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false }, // no blow-up
        .{ "caf\xc3\xa9", "un caf\xc3\xa9", true }, // UTF-8 as bytes
    };
    for (cases) |c| try expectMatch(c[0], c[1], false, c[2]);
}

test "regex find" {
    const cases = [_]struct { []const u8, []const u8, usize, ?Span }{
        .{ "foo", "a foo foo", 0, .{ .start = 2, .end = 5 } },
        .{ "foo", "a foo foo", 3, .{ .start = 6, .end = 9 } },
        .{ "a+", "baaab", 0, .{ .start = 1, .end = 4 } },
        .{ "a+?", "baaab", 0, .{ .start = 1, .end = 2 } },
        .{ "a|ab", "ab", 0, .{ .start = 0, .end = 1 } }, // leftmost-first, not longest
        .{ "ab|a", "ab", 0, .{ .start = 0, .end = 2 } },
        .{ "F[0-9]+", "**F239 x", 0, .{ .start = 2, .end = 6 } },
        .{ "^x", "ax", 1, null },
        .{ "x*", "ab", 0, .{ .start = 0, .end = 0 } },
        .{ "z", "ab", 0, null },
    };
    for (cases) |c| {
        var re = try Regex.compile(testing.allocator, c[0], false);
        defer re.deinit();
        var vm = try Vm.init(testing.allocator, &re);
        defer vm.deinit(testing.allocator);
        try testing.expectEqual(c[3], vm.find(&re, c[1], c[2]));
    }
}

test "regex groups, flags and escapes" {
    try expectMatch("(?:ab)+$", "xabab", false, true);
    try expectMatch("(?i)hello", "HELLO", false, true);
    try expectMatch("a(?i)b", "aB", false, true);
    try expectMatch("a(?i)b", "AB", false, false);
    try expectMatch("(?i:a)b", "Ab", false, true);
    try expectMatch("(?i:a)b", "AB", false, false);
    try expectMatch("(x(?i)a)A", "xAA", false, true);
    try expectMatch("(x(?i)a)a", "xAA", false, false); // the flag ends with its group
    try expectMatch("\\x41\\r", "A\r", false, true);
    try expectMatch("^[[:upper:]][[:digit:]]+$", "F12", false, true);
    try expectMatch("^[[:upper:]]", "f", false, false);
    try expectMatch("[[:^space:]]", "  ", false, false);
    try testing.expectError(error.BadGroup, Regex.compile(testing.allocator, "(?x)", false));
    try testing.expectError(error.BadEscape, Regex.compile(testing.allocator, "\\x0a", false));

    const gpa = testing.allocator;
    const lit = "a.b*(c)|\\ [x]{2} caf\xc3\xa9";
    const esc = try escape(gpa, lit);
    defer gpa.free(esc);
    var re = try Regex.compile(gpa, esc, false);
    defer re.deinit();
    var vm = try Vm.init(gpa, &re);
    defer vm.deinit(gpa);
    try testing.expectEqual(Span{ .start = 1, .end = 1 + lit.len }, vm.find(&re, "-" ++ lit ++ "-", 0));
}

test "regex ignore case" {
    try expectMatch("hello", "HeLLo", true, true);
    try expectMatch("hello", "HeLLo", false, false);
    try expectMatch("[a-c]+x", "ABCX", true, true);
    try expectMatch("[^a]", "A", true, false);
    try expectMatch("\\[", "{", true, false); // '[' and '{' are not cases of each other
    try expectMatch("\xc3\xa9", "\xc3\x89", true, false); // é/É: ASCII folding only
}

test "regex errors" {
    const cases = [_]struct { []const u8, Error }{
        .{ "(ab", error.UnbalancedParen },
        .{ "ab)", error.UnbalancedParen },
        .{ "[ab", error.BadClass },
        .{ "[z-a]", error.BadClass },
        .{ "*a", error.NothingToRepeat },
        .{ "a|+", error.NothingToRepeat },
        .{ "a\\", error.BadEscape },
        .{ "\\n", error.BadEscape },
        .{ "\\q", error.BadEscape },
        .{ "a{2,1}", error.BadRepeat },
        .{ "a{x}", error.BadRepeat },
        .{ "a{2", error.BadRepeat },
        .{ "[a-z]{20000}", error.TooComplex },
    };
    for (cases) |c| try testing.expectError(c[1], Regex.compile(testing.allocator, c[0], false));

    // Too deep to compile without risking the stack.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nested = struct {
        fn f(al: Allocator, depth: usize) ![]const u8 {
            return std.mem.concat(al, u8, &.{ try repeat(al, "(", depth), "x", try repeat(al, ")", depth) });
        }
    }.f;
    try testing.expectError(error.TooDeep, Regex.compile(testing.allocator, try nested(a, 251), false));
    // Stopped before the parser's own recursion goes deep.
    try testing.expectError(error.TooDeep, Regex.compile(testing.allocator, try repeat(a, "(", 100_000), false));
    try testing.expectError(error.TooDeep, Regex.compile(testing.allocator, try std.mem.concat(a, u8, &.{ "x", try repeat(a, "+", 300) }), false));

    // Just inside the limit, and repeats of an empty body, compile (quickly).
    for ([_][]const u8{ try nested(a, 200), "(){4294967295}x", "((){4294967295}){4294967295}x", "(?:(?i)){99999}x" }) |ok| {
        var re = try Regex.compile(testing.allocator, ok, false);
        defer re.deinit();
        var vm = try Vm.init(testing.allocator, &re);
        defer vm.deinit(testing.allocator);
        try testing.expect(vm.isMatch(&re, "x"));
    }
}

test "regex required literal" {
    const cases = [_]struct { []const u8, bool, []const u8 }{
        .{ "PM_[A-Z]+", false, "PM_" },
        .{ "^\\s*#\\s*define\\s+FOO", false, "define" },
        .{ "\\bERR_PTR\\(", false, "ERR_PTR(" },
        .{ "ab+cd", false, "cd" },
        .{ "(abc)+x", false, "abc" },
        .{ "dict(Find|Delete)\\(", false, "dict" },
        .{ "(spin|mutex)_lock\\(", false, "_lock(" },
        .{ "(abc)*x", false, "x" },
        .{ "abc|abd", false, "abc,abd" },
        .{ "func (cancel|launch)", false, "cancel,launch" },
        .{ "(a|bc)x", false, "x" },
        .{ "(ab|)cd", false, "cd" },
        .{ "a?", false, "" },
        .{ "[0-9a-f]{8}", false, "" },
        .{ "Hello", true, "hello" },
        .{ "[Hh]ello", false, "ello" },
        // Rarer beats longer: 'K' and 'j' are rare in source, 'e' common.
        .{ "eee[0-9]Kj", false, "Kj" },
        .{ "class \\w+ : public", false, " : public" },
    };
    for (cases) |c| {
        var re = try Regex.compile(testing.allocator, c[0], c[1]);
        defer re.deinit();
        const joined = try std.mem.join(testing.allocator, ",", re.literals);
        defer testing.allocator.free(joined);
        try testing.expectEqualStrings(c[2], joined);
    }
    // No literal: a class run, when rare enough.
    for ([_]struct { []const u8, ?usize, bool }{
        .{ "[0-9a-f]{16}", 16, true },
        .{ "[A-Za-z_]{30,}", 30, true },
        .{ "\\d{5,}", 5, true },
        .{ "[0-9][0-9]{3}", 4, true },
        .{ "[0-9][0-9a-f]{15}", 16, false }, // from the larger set, not exact
        .{ "^[0-9]{8}", 8, false },
        .{ "x?[0-9]{8}", 8, false },
        .{ "([0-9]{8})+", 8, false },
        .{ "\\w{3}", null, false }, // too common to pay
        .{ "[0-9]{8}|[a-f]{9}", null, false }, // alternation: not analysed
        .{ ".{40}", null, false }, // every byte but '\n': too common
    }) |c| {
        var re = try Regex.compile(testing.allocator, c[0], false);
        defer re.deinit();
        try testing.expectEqual(c[1], if (re.run) |r| r.min else null);
        if (re.run) |r| try testing.expectEqual(c[2], r.exact);
    }

    // Only literals: the prefilter's answer is the answer.
    for ([_]struct { []const u8, bool }{
        .{ "foo", true },         .{ "foo|bar baz", true }, .{ "(foo|bar)", true },
        .{ "foo|ba?r", false },   .{ "^foo", false },       .{ "\\bfoo", false },
        .{ "f[o]o|x\\.y", true }, .{ "", false },           .{ "(ab)c", false },
    }) |c| {
        var re = try Regex.compile(testing.allocator, c[0], false);
        defer re.deinit();
        try testing.expectEqual(c[1], re.exact);
    }
}

fn repeat(a: Allocator, s: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, s.len * n);
    for (0..n) |k| @memcpy(out[k * s.len ..][0..s.len], s);
    return out;
}

// Reference matcher for the randomized test: backtracking straight over
// the parse tree. `rest` is what must match after the head node.
fn backtrack(a: Allocator, nodes: []const Node, line: []const u8, i: usize) Error!bool {
    if (nodes.len == 0) return true;
    const rest = nodes[1..];
    switch (nodes[0]) {
        .set => |s| return i < line.len and s.isSet(line[i]) and try backtrack(a, rest, line, i + 1),
        .bol => return i == 0 and try backtrack(a, rest, line, i),
        .eol => return i == line.len and try backtrack(a, rest, line, i),
        .word_boundary => return wordBoundary(line, i) and try backtrack(a, rest, line, i),
        .concat => |items| return backtrack(a, try std.mem.concat(a, Node, &[_][]const Node{ items, rest }), line, i),
        .alt => |branches| {
            for (branches) |b| {
                if (try backtrack(a, try std.mem.concat(a, Node, &[_][]const Node{ &.{b}, rest }), line, i)) return true;
            }
            return false;
        },
        .repeat => |r| {
            // The generator only repeats sets, which always consume a byte.
            if (r.min == 0) {
                if (try backtrack(a, rest, line, i)) return true;
                if (r.max != null and r.max.? == 0) return false;
            }
            const fewer: Node = .{ .repeat = .{ .node = r.node, .min = r.min -| 1, .max = if (r.max) |m| m - 1 else null } };
            return backtrack(a, try std.mem.concat(a, Node, &[_][]const Node{ &.{ r.node.*, fewer }, rest }), line, i);
        },
    }
}

// Like `backtrack`, but in priority order (alternatives left to right,
// greedy repetition tries one more round first), returning where the first
// successful match ends: the reference for `Vm.find`.
fn backtrackEnd(a: Allocator, nodes: []const Node, line: []const u8, i: usize) Error!?usize {
    if (nodes.len == 0) return i;
    const rest = nodes[1..];
    switch (nodes[0]) {
        .set => |s| return if (i < line.len and s.isSet(line[i])) backtrackEnd(a, rest, line, i + 1) else null,
        .bol => return if (i == 0) backtrackEnd(a, rest, line, i) else null,
        .eol => return if (i == line.len) backtrackEnd(a, rest, line, i) else null,
        .word_boundary => return if (wordBoundary(line, i)) backtrackEnd(a, rest, line, i) else null,
        .concat => |items| return backtrackEnd(a, try std.mem.concat(a, Node, &[_][]const Node{ items, rest }), line, i),
        .alt => |branches| {
            for (branches) |b| {
                if (try backtrackEnd(a, try std.mem.concat(a, Node, &[_][]const Node{ &.{b}, rest }), line, i)) |end| return end;
            }
            return null;
        },
        .repeat => |r| {
            // As in `backtrack`, only sets are repeated, so every round consumes a byte.
            const fewer: Node = .{ .repeat = .{ .node = r.node, .min = r.min -| 1, .max = if (r.max) |m| m -| 1 else null, .greedy = r.greedy } };
            const more = try std.mem.concat(a, Node, &[_][]const Node{ &.{ r.node.*, fewer }, rest });
            if (r.min > 0) return backtrackEnd(a, more, line, i);
            const can_more = r.max == null or r.max.? > 0;
            if (r.greedy and can_more) if (try backtrackEnd(a, more, line, i)) |end| return end;
            if (try backtrackEnd(a, rest, line, i)) |end| return end;
            if (!r.greedy and can_more) return backtrackEnd(a, more, line, i);
            return null;
        },
    }
}

fn randomPattern(rand: std.Random, buf: *std.ArrayList(u8), a: Allocator, depth: u32) !void {
    const atoms = [_][]const u8{ "a", "b", "A", ".", "[ab]", "[^a]", "\\w", "_", " ", "ab", "ba" };
    const n = 1 + rand.uintLessThan(usize, 4);
    for (0..n) |_| {
        switch (rand.uintLessThan(u8, 12)) {
            0 => try buf.append(a, '^'),
            1 => try buf.append(a, '$'),
            2 => try buf.appendSlice(a, "\\b"),
            3 => if (depth < 2) {
                try buf.append(a, '(');
                try randomPattern(rand, buf, a, depth + 1);
                try buf.append(a, '|');
                try randomPattern(rand, buf, a, depth + 1);
                try buf.append(a, ')');
            },
            else => {
                const atom = atoms[rand.uintLessThan(usize, atoms.len)];
                try buf.appendSlice(a, atom);
                if (atom.len == 2 and atom[0] != '\\') continue; // two bytes: don't repeat
                const quants = [_][]const u8{ "", "", "*", "+", "?", "{2}", "{1,3}", "{2,}", "*?", "+?" };
                try buf.appendSlice(a, quants[rand.uintLessThan(usize, quants.len)]);
            },
        }
    }
}

test "regex VM matches backtracking reference" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x7e9e);
    const rand = prng.random();
    var line_buf: [16]u8 = undefined;
    var runs: usize = 0; // lines checked against a class run

    for (0..5_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var pattern: std.ArrayList(u8) = .empty;
        try randomPattern(rand, &pattern, a, 0);
        const ignore_case = rand.boolean();

        var re = try Regex.compile(testing.allocator, pattern.items, ignore_case);
        defer re.deinit();
        var vm = try Vm.init(testing.allocator, &re);
        defer vm.deinit(testing.allocator);
        var p: Parser = .{ .arena = a, .src = pattern.items, .fold = ignore_case };
        const root = try p.alt();

        for (0..20) |_| {
            const line = line_buf[0..rand.uintAtMost(usize, line_buf.len)];
            for (line) |*c| c.* = "abAB_ "[rand.uintLessThan(usize, 6)];
            var expected = false;
            for (0..line.len + 1) |i| {
                if (try backtrack(a, &.{root}, line, i)) expected = true;
            }
            const dfa_says: ?bool = if (vm.dfa) |*d| d.isMatch(line) else null;
            if (vm.pike(&re, line) != expected or (dfa_says != null and dfa_says.? != expected)) {
                std.debug.print("pattern {s} (ignore case {}) line \"{s}\": expected {}, dfa {?}\n", .{ pattern.items, ignore_case, line, expected, dfa_says });
                return error.TestUnexpectedResult;
            }
            // find: the leftmost start, and the end a backtracker picks there.
            var want: ?Span = null;
            for (0..line.len + 1) |i| {
                if (try backtrackEnd(a, &.{root}, line, i)) |end| {
                    want = .{ .start = i, .end = end };
                    break;
                }
            }
            const got = vm.find(&re, line, 0);
            if (!std.meta.eql(want, got)) {
                std.debug.print("find: pattern {s} (ignore case {}) line \"{s}\": expected {?} got {?}\n", .{ pattern.items, ignore_case, line, want, got });
                return error.TestUnexpectedResult;
            }
            // The prefilter must never drop a matching line, and with
            // `exact` it must be the whole answer.
            if (re.literals.len > 0) {
                const found = for (re.literals) |lit| {
                    const at = if (ignore_case) std.ascii.findIgnoreCase(line, lit) else std.mem.indexOf(u8, line, lit);
                    if (at != null) break true;
                } else false;
                if (expected) try testing.expect(found);
                if (re.exact) try testing.expectEqual(expected, found);
            }
            if (re.run) |r| {
                var run: usize = 0;
                const has = for (line) |c| {
                    run = if (r.ranges.contains(c)) run + 1 else 0;
                    if (run >= r.min) break true;
                } else false;
                if (expected) try testing.expect(has);
                if (r.exact) try testing.expectEqual(expected, has);
                runs += 1;
            }
        }
    }
    try testing.expect(runs > 0);
}

test "DFA findLines over a buffer matches line-by-line answers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0xdfa);
    const rand = prng.random();
    var data_buf: [96]u8 = undefined;
    var checked: usize = 0;
    for (0..3_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var pattern: std.ArrayList(u8) = .empty;
        try randomPattern(rand, &pattern, a, 0);
        var re = try Regex.compile(testing.allocator, pattern.items, rand.boolean());
        defer re.deinit();
        var vm = try Vm.init(testing.allocator, &re);
        defer vm.deinit(testing.allocator);
        const d = if (vm.dfa) |*d| d else continue; // `\b`
        for (0..10) |_| {
            // Short lines, empty ones included, with or without a final '\n'.
            const data = data_buf[0..rand.uintAtMost(usize, data_buf.len)];
            for (data) |*c| c.* = "abAB_ \n\n"[rand.uintLessThan(usize, 8)];
            var want: std.ArrayList(usize) = .empty;
            var it = std.mem.splitScalar(u8, data, '\n');
            var ln: usize = 1;
            var off: usize = 0;
            while (it.next()) |line| : (ln += 1) {
                if (off == data.len and data.len > 0) break; // nothing after a final '\n'
                if (data.len == 0) break;
                if (vm.pike(&re, line)) try want.append(a, ln);
                off += line.len + 1;
            }
            var got: std.ArrayList(usize) = .empty;
            const after = try d.findLines(data, 1, CollectLines{ .gpa = a, .lines = &got });
            if (!std.mem.eql(usize, want.items, got.items)) {
                std.debug.print("pattern {s} data \"{f}\": want {any} got {any}\n", .{ pattern.items, std.zig.fmtString(data), want.items, got.items });
                return error.TestUnexpectedResult;
            }
            try testing.expectEqual(1 + std.mem.countScalar(u8, data, '\n'), after);
            checked += 1;
        }
    }
    try testing.expect(checked > 10_000);
}

test "DFA gives up on a pattern that needs too many states" {
    // Every combination of where the 'a'-runs started is a state.
    var re = try Regex.compile(testing.allocator, "a[ab]{14}c", false);
    defer re.deinit();
    var vm = try Vm.init(testing.allocator, &re);
    defer vm.deinit(testing.allocator);
    var prng: std.Random.DefaultPrng = .init(1);
    var line: [4096]u8 = undefined;
    var answers: usize = 0;
    for (0..400) |_| {
        for (&line) |*c| c.* = "ab"[prng.random().uintLessThan(usize, 2)];
        line[line.len - 1] = 'c';
        // Whatever answers, the answer is right.
        try testing.expectEqual(vm.pike(&re, &line), vm.isMatch(&re, &line));
        answers += 1;
    }
    try testing.expect(vm.dfa.?.failed or vm.dfa.?.clears > 0);
}

const CollectLines = struct {
    gpa: Allocator,
    lines: *std.ArrayList(usize),
    pub fn onLine(c: CollectLines, m: match.Match) !void {
        try c.lines.append(c.gpa, m.line);
    }
};

test "regex findLines: prefiltered and every-line paths agree" {
    const gpa = testing.allocator;
    const data = "foo\nPM_RESUME x\n\npm_suspend\nPM_\nend PM_FOO";
    const cases = [_]struct { []const u8, bool, []const usize }{
        .{ "PM_[A-Z]+", false, &.{ 2, 6 } },
        .{ "PM_[A-Z]+", true, &.{ 2, 4, 6 } },
        .{ "^$", false, &.{3} },
        .{ "^[a-z_]+$", false, &.{ 1, 4 } },
        .{ "O$", false, &.{6} },
    };
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(gpa);
    var all: std.ArrayList(usize) = .empty;
    defer all.deinit(gpa);
    for (cases) |c| {
        var re = try Regex.compile(gpa, c[0], c[1]);
        defer re.deinit();
        var vm = try Vm.init(gpa, &re);
        defer vm.deinit(gpa);
        got.clearRetainingCapacity();
        all.clearRetainingCapacity();
        const after = try findLines(&re, &vm, data, 1, CollectLines{ .gpa = gpa, .lines = &got });
        const filter: Filter(CollectLines) = .{ .re = &re, .vm = &vm, .sink = .{ .gpa = gpa, .lines = &all } };
        const after_all = try everyLine(data, 0, 1, filter);
        try testing.expectEqualSlices(usize, c[2], got.items);
        try testing.expectEqualSlices(usize, c[2], all.items);
        try testing.expectEqual(6, after);
        try testing.expectEqual(6, after_all);
    }
}
