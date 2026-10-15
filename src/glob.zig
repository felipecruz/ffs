//! Globs, for `-g` and for ignore files (.gitignore, .ignore, .rgignore).
//!
//! Both use gitignore rules, as ripgrep does:
//!
//!     *  ?  [a-z] [!a]   any run of bytes but '/', one byte, a class
//!     **                 any run of bytes, '/' included: `**/x`, `a/**`, `a/**/b`
//!     {a,b}              alternatives
//!     \x                 x literally
//!
//! A pattern with no '/' (other than a trailing one) matches the file name
//! at any depth; with a '/', it matches the whole path, relative to the
//! directory of the ignore file (or the search root, for `-g`). A trailing
//! '/' matches directories only.
//!
//! Ignore files come with the tree being searched, so a hostile one must not
//! make the search hang or run out of memory: `**` is matched in time linear
//! in the pattern times the path, and `{a,b}` expansion has a budget. A rule
//! that would need more is left out (`error.TooComplex`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The longest pattern with `**` or `{` that is accepted: matching `**`
/// keeps a state per pattern byte, and finding braces a stack. Paths are
/// shorter than this anyway.
pub const max_len = 4096;

pub const Error = Allocator.Error || error{TooComplex};

/// Does `text` match `pattern`? `*`, `?` and classes never match '/'.
/// With `fold`, ASCII letters match either case. A pattern with `**` must
/// be at most `max_len` bytes; a longer one matches nothing.
pub fn match(pattern: []const u8, text: []const u8, fold: bool) bool {
    if (std.mem.indexOf(u8, pattern, "**") != null) return matchStates(pattern, text, fold);
    // Only single `*`s: backtracking to the last one is enough, since a
    // later `*` can take whatever an earlier one would have.
    var p: usize = 0;
    var t: usize = 0;
    // Backtracking point for the last single `*`: where it started in the
    // pattern, and how much of the text it has eaten so far.
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (true) {
        if (p < pattern.len) {
            const c = pattern[p];
            if (c == '*') {
                star_p = p;
                star_t = t;
                p += 1;
                continue;
            }
            if (t < text.len) {
                if (matchOne(pattern, &p, text[t], fold)) {
                    t += 1;
                    continue;
                }
            }
        } else if (t == text.len) return true;
        // Mismatch: let the last `*` eat one more byte, but never a '/'.
        const sp = star_p orelse return false;
        if (star_t >= text.len or text[star_t] == '/') return false;
        star_t += 1;
        p = sp + 1;
        t = star_t;
    }
}

// A pattern with `**`, run as an automaton whose states are positions in
// the pattern: every position the text read so far can have reached is
// tracked at once, so no choice is ever retried. Backtracking over several
// `**` instead takes time exponential in their number.
//
// `**/` matches zero or more whole directories (`(.*/)?`), and any other
// `**` any run of bytes, '/' included; a final `/**` is everything below.
fn matchStates(pattern: []const u8, text: []const u8, fold: bool) bool {
    if (pattern.len > max_len) return false;
    var states: [2][max_len + 1]u8 = undefined;
    var cur = states[0][0 .. pattern.len + 1];
    var next = states[1][0 .. pattern.len + 1];
    @memset(cur, 0);
    cur[0] = at;
    skipEmpty(pattern, cur);
    for (text) |c| {
        @memset(next, 0);
        var alive = false;
        for (cur[0..pattern.len], 0..) |flags, p| {
            if (flags == 0) continue;
            alive = true;
            if (flags & in_dirs != 0) {
                // Inside `**/`'s directories: any byte, and after a '/'
                // possibly the end of them.
                next[p] |= in_dirs;
                if (c == '/') next[token(pattern, p).double_star.to] |= at;
            }
            if (flags & at == 0) continue;
            switch (token(pattern, p)) {
                .double_star => |exit| if (!exit.slash) {
                    next[p] |= at;
                },
                .star => if (c != '/') {
                    next[p] |= at;
                },
                .one => {
                    var q = p;
                    if (matchOne(pattern, &q, c, fold)) next[q] |= at;
                },
            }
        }
        if (!alive) return false;
        skipEmpty(pattern, next);
        std.mem.swap([]u8, &cur, &next);
    }
    return cur[pattern.len] & at != 0;
}

// State flags of a pattern position: `at` it, or (for `**/` only) inside
// the directories it matches. The two differ in what follows: from `at`,
// `**/` can match no directory at all, but once a byte is read it must end
// with a '/'.
const at = 1;
const in_dirs = 2;

// Adds the states reachable without reading a byte: past a `*` or `**`
// that matches nothing, and into `**/`'s directories. They are all at or
// after the position they come from, so one pass does it.
fn skipEmpty(pattern: []const u8, set: []u8) void {
    for (0..pattern.len) |p| {
        if (set[p] & at == 0) continue;
        switch (token(pattern, p)) {
            .double_star => |exit| {
                set[exit.to] |= at;
                if (exit.slash) set[p] |= in_dirs;
            },
            .star => set[p + 1] |= at,
            .one => {},
        }
    }
}

const Token = union(enum) {
    /// `**`, and where it ends: the position after it, or after the '/' of
    /// `**/` (`slash`).
    double_star: struct { to: usize, slash: bool },
    star,
    /// A byte, a class or an escape: see `matchOne`.
    one,
};

fn token(pattern: []const u8, p: usize) Token {
    if (pattern[p] != '*') return .one;
    if (p + 1 == pattern.len or pattern[p + 1] != '*') return .star;
    var rest = p + 2;
    while (rest < pattern.len and pattern[rest] == '*') rest += 1;
    if (rest < pattern.len and pattern[rest] == '/') return .{ .double_star = .{ .to = rest + 1, .slash = true } };
    return .{ .double_star = .{ .to = rest, .slash = false } };
}

// One byte of the pattern (or one class) at pattern[p.*] against `c`.
// Advances p.* past it on a match.
fn matchOne(pattern: []const u8, p: *usize, c: u8, fold: bool) bool {
    switch (pattern[p.*]) {
        '?' => {
            if (c == '/') return false;
            p.* += 1;
            return true;
        },
        '[' => if (classEnd(pattern, p.*)) |end| {
            if (c == '/' or !inClass(pattern[p.* + 1 .. end], c, fold)) return false;
            p.* = end + 1;
            return true;
        },
        '\\' => if (p.* + 1 < pattern.len) {
            if (!eql(pattern[p.* + 1], c, fold)) return false;
            p.* += 2;
            return true;
        },
        else => {},
    }
    if (!eql(pattern[p.*], c, fold)) return false;
    p.* += 1;
    return true;
}

fn eql(a: u8, b: u8, fold: bool) bool {
    return a == b or (fold and std.ascii.toLower(a) == std.ascii.toLower(b));
}

// Index of the ']' closing the class at pattern[start] == '[', or null if
// unclosed (the '[' is then literal). A ']' first in the class is a member.
fn classEnd(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1;
    return std.mem.indexOfScalarPos(u8, pattern, i, ']');
}

fn inClass(body: []const u8, c: u8, fold: bool) bool {
    var b = body;
    const negate = b.len > 0 and (b[0] == '!' or b[0] == '^');
    if (negate) b = b[1..];
    var found = false;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (i + 2 < b.len and b[i + 1] == '-') {
            const lo = b[i];
            const hi = b[i + 2];
            if ((c >= lo and c <= hi) or (fold and inRangeFolded(lo, hi, c))) found = true;
            i += 2;
        } else if (eql(b[i], c, fold)) found = true;
    }
    return found != negate;
}

fn inRangeFolded(lo: u8, hi: u8, c: u8) bool {
    const l = std.ascii.toLower(c);
    const u = std.ascii.toUpper(c);
    return (l >= lo and l <= hi) or (u >= lo and u <= hi);
}

/// What brace expansion may still produce. `{a,b}` repeated n times is 2^n
/// patterns, so without a limit one line of an ignore file could take all
/// the memory there is.
const Budget = struct {
    /// Expansion steps; each finished pattern takes one.
    steps: usize,
    /// Bytes of expanded patterns.
    bytes: usize,

    fn forGlob() Budget {
        return .{ .steps = 1024, .bytes = 1 << 20 };
    }
};

/// Expands `{a,b}` alternatives (nested too) into separate patterns,
/// allocated in `a`.
fn expandBraces(a: Allocator, pattern: []const u8, out: *std.ArrayList([]const u8), budget: *Budget) Error!void {
    if (budget.steps == 0) return error.TooComplex;
    budget.steps -= 1;
    if (std.mem.indexOfScalar(u8, pattern, '{') == null) return out.append(a, pattern);
    if (pattern.len > max_len) return error.TooComplex;
    const group = firstGroup(pattern) orelse return out.append(a, pattern);
    const i = group.open;
    const end = group.close;
    var start = i + 1;
    var depth: usize = 0;
    var j = start;
    while (j <= end) : (j += 1) {
        const c = if (j == end) ',' else pattern[j];
        switch (c) {
            '\\' => j += 1,
            '{' => depth += 1,
            '}' => depth -= 1,
            ',' => if (depth == 0) {
                const len = i + (j - start) + (pattern.len - end - 1);
                if (len > budget.bytes) return error.TooComplex;
                budget.bytes -= len;
                const joined = try std.mem.concat(a, u8, &.{ pattern[0..i], pattern[start..j], pattern[end + 1 ..] });
                try expandBraces(a, joined, out, budget);
                start = j + 1;
            },
            else => {},
        }
    }
}

// The first '{' that has a matching '}', and that '}', in one pass:
// checking each '{' with a scan of its own is quadratic on `{{{{…`.
const Group = struct { open: usize, close: usize };

fn firstGroup(pattern: []const u8) ?Group {
    var open: [max_len]u16 = undefined; // unmatched '{' positions
    var n: usize = 0;
    var best: ?Group = null;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '{' => {
                open[n] = @intCast(i);
                n += 1;
            },
            '}' => if (n > 0) {
                n -= 1;
                if (best == null or open[n] < best.?.open) best = .{ .open = open[n], .close = i };
            },
            else => {},
        }
    }
    return best;
}

pub const Rule = struct {
    pattern: []const u8,
    /// How to match: most ignore-file lines are a name, `*.ext` or `name*`,
    /// which need no glob matcher.
    shape: Shape,
    /// Matches the file name only (the pattern has no '/').
    basename: bool,
    dir_only: bool,
    /// What a match means: leave the path out, or keep it.
    kind: Decision,
};

pub const Decision = enum { none, ignore, include };

const Shape = enum { glob, literal, suffix, prefix };

// A file-name pattern's shape; `pattern` without its `*` is the literal part.
fn shapeOf(pattern: []const u8, basename: bool) Shape {
    const meta = "*?[\\";
    if (std.mem.indexOfAny(u8, pattern, meta) == null) return .literal;
    // '*' can't cross '/', which only holds without checking for file names.
    if (!basename or pattern.len < 2) return .glob;
    if (pattern[0] == '*' and std.mem.indexOfAny(u8, pattern[1..], meta) == null) return .suffix;
    if (pattern[pattern.len - 1] == '*' and std.mem.indexOfAny(u8, pattern[0 .. pattern.len - 1], meta) == null) return .prefix;
    return .glob;
}

/// Rules in order; the last one that matches a path decides.
pub const RuleSet = struct {
    rules: std.ArrayList(Rule) = .empty,
    /// Some rule includes paths (a `-g` without '!', or a '!' line).
    any_include: bool = false,

    /// Adds one gitignore-style pattern. A leading '!' means the opposite of
    /// `kind`. Patterns are copied into `a`. `error.TooComplex`: the pattern
    /// was left out, see the top of this file.
    pub fn add(set: *RuleSet, a: Allocator, line: []const u8, kind_plain: Decision) Error!void {
        var budget: Budget = .forGlob();
        return set.addBudgeted(a, line, kind_plain, &budget);
    }

    fn addBudgeted(set: *RuleSet, a: Allocator, line: []const u8, kind_plain: Decision, budget: *Budget) Error!void {
        var pat = line;
        var kind = kind_plain;
        if (pat.len > 0 and pat[0] == '!') {
            kind = if (kind == .ignore) .include else .ignore;
            pat = pat[1..];
        } else if (pat.len > 1 and pat[0] == '\\' and (pat[1] == '!' or pat[1] == '#')) {
            pat = pat[1..];
        }
        var dir_only = false;
        if (pat.len > 1 and pat[pat.len - 1] == '/') {
            dir_only = true;
            pat = pat[0 .. pat.len - 1];
        }
        if (pat.len == 0) return;
        const basename = std.mem.indexOfScalar(u8, pat, '/') == null;
        if (pat[0] == '/') pat = pat[1..];
        var expanded: std.ArrayList([]const u8) = .empty;
        try expandBraces(a, pat, &expanded, budget);
        for (expanded.items) |p| {
            if (p.len > max_len and std.mem.indexOf(u8, p, "**") != null) return error.TooComplex;
        }
        for (expanded.items) |p| {
            const shape = shapeOf(p, basename);
            const lit = switch (shape) {
                .glob, .literal => p,
                .suffix => p[1..],
                .prefix => p[0 .. p.len - 1],
            };
            try set.rules.append(a, .{ .pattern = try a.dupe(u8, lit), .shape = shape, .basename = basename, .dir_only = dir_only, .kind = kind });
        }
        if (kind == .include) set.any_include = true;
    }

    /// Adds every line of an ignore file: comments and blank lines skipped,
    /// trailing spaces trimmed. Lines too complex to use are skipped too.
    /// Each line gets the steps of one glob, but the bytes are budgeted for
    /// the whole file, in proportion to its size: a file of many lines that
    /// each expand a little must not add up to gigabytes.
    pub fn addIgnoreFile(set: *RuleSet, a: Allocator, contents: []const u8) Allocator.Error!void {
        var budget: Budget = .{ .steps = 0, .bytes = 2 * contents.len + (1 << 20) };
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |raw| {
            var line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            while (line.len > 0 and line[line.len - 1] == ' ' and !(line.len > 1 and line[line.len - 2] == '\\')) line = line[0 .. line.len - 1];
            budget.steps = Budget.forGlob().steps;
            set.addBudgeted(a, line, .ignore, &budget) catch |err| switch (err) {
                error.TooComplex => continue,
                error.OutOfMemory => |e| return e,
            };
        }
    }

    /// The last rule matching `path` (relative, '/'-separated), or .none.
    pub fn decide(set: *const RuleSet, path: []const u8, is_dir: bool) Decision {
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
        var i = set.rules.items.len;
        while (i > 0) {
            i -= 1;
            const r = set.rules.items[i];
            if (r.dir_only and !is_dir) continue;
            const text = if (r.basename) base else path;
            const hit = switch (r.shape) {
                .glob => match(r.pattern, text, false),
                .literal => std.mem.eql(u8, r.pattern, text),
                .suffix => std.mem.endsWith(u8, text, r.pattern),
                .prefix => std.mem.startsWith(u8, text, r.pattern),
            };
            if (hit) return r.kind;
        }
        return .none;
    }
};

const testing = std.testing;

test "glob match" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "*.swift", "a.swift", true },
        .{ "*.swift", "a.swifty", false },
        .{ "*.swift", "dir/a.swift", false }, // '*' stops at '/'
        .{ "*Test*", "FooTests.swift", true },
        .{ "a?c", "abc", true },
        .{ "a?c", "a/c", false },
        .{ "[abc]x", "bx", true },
        .{ "[!abc]x", "bx", false },
        .{ "[a-c]x", "dx", false },
        .{ "\\*x", "*x", true },
        .{ "\\*x", "ax", false },
        .{ "**/foo", "foo", true },
        .{ "**/foo", "a/b/foo", true },
        .{ "**/foo", "a/xfoo", false },
        .{ "a/**", "a/b/c", true },
        .{ "a/**", "ab/c", false },
        .{ "a/**/b", "a/b", true },
        .{ "a/**/b", "a/x/y/b", true },
        .{ "a/**/b", "a/x/yb", false },
        .{ "Sources/**/*.swift", "Sources/A/B/c.swift", true },
        .{ "*", "", true },
        .{ "", "", true },
        .{ "abc", "abcd", false },
        .{ "*a*b", "xaxxb", true },
        .{ "[abc", "[abc", true }, // unclosed class: literal
        .{ "*a**/z", "aaz", true }, // the `*` must take "a" for `**/` to match nothing
        .{ "a/***/b", "a/x/b", true },
        .{ "**", "a/b", true },
        .{ "a**", "ab/c", true },
        .{ "**/\\*", "a/*", true },
        .{ "**/\\*", "a/b", false },
        .{ "a/**/[bc]?", "a/x/cd", true },
        .{ "a/**/[bc]?", "a/x/c/", false },
    };
    for (cases) |c| {
        if (match(c[0], c[1], false) != c[2]) {
            std.debug.print("glob {s} on {s}: expected {}\n", .{ c[0], c[1], c[2] });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(match("*.SWIFT", "a.swift", true));
    try testing.expect(match("[A-C]x", "bx", true));
    try testing.expect(!match("*.SWIFT", "a.swift", false));
}

// Reference for the randomized test: the glob rules, by plain recursion
// (exponential, fine on short inputs).
fn matchRef(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    switch (token(pattern, 0)) {
        .double_star => |exit| {
            const rest = pattern[exit.to..];
            if (exit.slash) {
                if (matchRef(rest, text)) return true;
                for (text, 0..) |c, k| if (c == '/' and matchRef(rest, text[k + 1 ..])) return true;
                return false;
            }
            for (0..text.len + 1) |k| if (matchRef(rest, text[k..])) return true;
            return false;
        },
        .star => {
            for (0..text.len + 1) |k| {
                if (k > 0 and text[k - 1] == '/') break;
                if (matchRef(pattern[1..], text[k..])) return true;
            }
            return false;
        },
        .one => {
            var q: usize = 0;
            return text.len > 0 and matchOne(pattern, &q, text[0], false) and matchRef(pattern[q..], text[1..]);
        },
    }
}

test "glob match agrees with a recursive reference" {
    var prng: std.Random.DefaultPrng = .init(0x610b);
    const rand = prng.random();
    const pieces = [_][]const u8{ "a", "b", "/", "*", "**", "**/", "/**", "?", "[ab]", "[!a]", "\\*", "ab" };
    var pat_buf: [64]u8 = undefined;
    var text_buf: [12]u8 = undefined;
    for (0..20_000) |_| {
        var n: usize = 0;
        for (0..1 + rand.uintLessThan(usize, 6)) |_| {
            const piece = pieces[rand.uintLessThan(usize, pieces.len)];
            @memcpy(pat_buf[n..][0..piece.len], piece);
            n += piece.len;
        }
        const pattern = pat_buf[0..n];
        const text = text_buf[0..rand.uintAtMost(usize, text_buf.len)];
        for (text) |*c| c.* = "ab/*"[rand.uintLessThan(usize, 4)];
        if (match(pattern, text, false) != matchRef(pattern, text)) {
            std.debug.print("glob {s} on {s}: expected {}\n", .{ pattern, text, matchRef(pattern, text) });
            return error.TestUnexpectedResult;
        }
    }
}

test "hostile patterns stay fast and small" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rep = struct {
        fn f(al: Allocator, s: []const u8, n: usize) ![]const u8 {
            const out = try al.alloc(u8, s.len * n);
            for (0..n) |k| @memcpy(out[k * s.len ..][0..s.len], s);
            return out;
        }
    }.f;

    // Backtracking over seven `**` against a 200-byte name took minutes.
    const name = try rep(a, "a", 200);
    try testing.expect(!match("**a**a**a**a**a**a**a**b", name, false));
    try testing.expect(match("**a**a**a**a**a**a**a**a", name, false));

    var set: RuleSet = .{};
    // 2^26 patterns, or a line of unmatched braces: left out, quickly.
    const bomb = try rep(a, "{a,b}", 26);
    const braces = try rep(a, "{", 4000);
    try testing.expectError(error.TooComplex, set.add(a, bomb, .include));
    try testing.expectError(error.TooComplex, set.add(a, try std.mem.concat(a, u8, &.{ try rep(a, "{", 5000), "}" }), .include));
    try set.addIgnoreFile(a, try std.mem.concat(a, u8, &.{ bomb, "\n", braces, "x\n*.{c,h}\n" }));
    try testing.expectEqual(.ignore, set.decide("x.h", false));
    try testing.expectEqual(.ignore, set.decide(try std.mem.concat(a, u8, &.{ braces, "x" }), false));
    try testing.expectEqual(.none, set.decide("ab", false));
}

test "rule set: gitignore semantics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var set: RuleSet = .{};
    try set.addIgnoreFile(a,
        \\# comment
        \\build
        \\*.log
        \\!keep.log
        \\/top.txt
        \\docs/
        \\src/gen/*.c
        \\\#hash
        \\trailing
    );
    try testing.expectEqual(.ignore, set.decide("build", true));
    try testing.expectEqual(.ignore, set.decide("a/b/build", false));
    try testing.expectEqual(.ignore, set.decide("x/y.log", false));
    try testing.expectEqual(.include, set.decide("x/keep.log", false));
    try testing.expectEqual(.ignore, set.decide("top.txt", false));
    try testing.expectEqual(.none, set.decide("a/top.txt", false));
    try testing.expectEqual(.ignore, set.decide("a/docs", true));
    try testing.expectEqual(.none, set.decide("a/docs", false));
    try testing.expectEqual(.ignore, set.decide("src/gen/x.c", false));
    try testing.expectEqual(.none, set.decide("a/src/gen/x.c", false));
    try testing.expectEqual(.ignore, set.decide("#hash", false));
    try testing.expectEqual(.ignore, set.decide("trailing", false));
    try testing.expectEqual(.none, set.decide("main.zig", false));
}

test "rule set: -g semantics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var set: RuleSet = .{};
    for ([_][]const u8{ "*.{swift,md}", "!build", "Makefile" }) |g| try set.add(a, g, .include);
    try testing.expectEqual(.include, set.decide("a/b.swift", false));
    try testing.expectEqual(.include, set.decide("README.md", false));
    try testing.expectEqual(.include, set.decide("Makefile", false));
    try testing.expectEqual(.none, set.decide("main.zig", false));
    try testing.expectEqual(.ignore, set.decide("build", true));
    try testing.expect(set.any_include);
}
