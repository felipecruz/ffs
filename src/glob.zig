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

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Does `text` match `pattern`? `*`, `?` and classes never match '/'.
/// With `fold`, ASCII letters match either case.
pub fn match(pattern: []const u8, text: []const u8, fold: bool) bool {
    var p: usize = 0;
    var t: usize = 0;
    // Backtracking point for the last single `*`: where it started in the
    // pattern, and how much of the text it has eaten so far.
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (true) {
        if (p < pattern.len) {
            const c = pattern[p];
            if (c == '*' and p + 1 < pattern.len and pattern[p + 1] == '*') {
                return doubleStar(pattern, p, text, t, fold);
            }
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

// `**` at pattern[p]: `**/` matches zero or more whole directories, a final
// `/**` everything below, and any other `**` any run of bytes.
fn doubleStar(pattern: []const u8, p: usize, text: []const u8, t: usize, fold: bool) bool {
    var rest = p + 2;
    while (rest < pattern.len and pattern[rest] == '*') rest += 1;
    if (rest < pattern.len and pattern[rest] == '/') {
        // `**/rest`: rest at t, or after any later '/'.
        const tail = pattern[rest + 1 ..];
        if (match(tail, text[t..], fold)) return true;
        var i = t;
        while (std.mem.indexOfScalarPos(u8, text, i, '/')) |slash| : (i = slash + 1) {
            if (match(tail, text[slash + 1 ..], fold)) return true;
        }
        return false;
    }
    const tail = pattern[rest..];
    var i = t;
    while (i <= text.len) : (i += 1) {
        if (match(tail, text[i..], fold)) return true;
    }
    return false;
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

/// Expands `{a,b}` alternatives (nested too) into separate patterns,
/// allocated in `a`.
fn expandBraces(a: Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    // The first top-level '{' with a matching '}'.
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '{' => if (braceEnd(pattern, i)) |end| {
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
                            const joined = try std.mem.concat(a, u8, &.{ pattern[0..i], pattern[start..j], pattern[end + 1 ..] });
                            try expandBraces(a, joined, out);
                            start = j + 1;
                        },
                        else => {},
                    }
                }
                return;
            },
            else => {},
        }
    }
    try out.append(a, pattern);
}

fn braceEnd(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
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

    /// Adds one gitignore-style pattern. `negated` (a leading '!', already
    /// stripped) means the opposite of `kind`. Patterns are copied into `a`.
    pub fn add(set: *RuleSet, a: Allocator, line: []const u8, kind_plain: Decision) Allocator.Error!void {
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
        try expandBraces(a, pat, &expanded);
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
    /// trailing spaces trimmed.
    pub fn addIgnoreFile(set: *RuleSet, a: Allocator, contents: []const u8) Allocator.Error!void {
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |raw| {
            var line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            while (line.len > 0 and line[line.len - 1] == ' ' and !(line.len > 1 and line[line.len - 2] == '\\')) line = line[0 .. line.len - 1];
            try set.add(a, line, .ignore);
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
