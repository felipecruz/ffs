const std = @import("std");
const build_options = @import("build_options");
const glob = @import("glob.zig");
const regex = @import("regex.zig");
const search = @import("search.zig");
const Regex = regex.Regex;

// Usage: ffs [OPTIONS] PATTERN [PATH...]
//        ffs --files [OPTIONS] [PATH...]
// A drop-in for ripgrep's command line, as agents use it: PATTERN is a
// regex, and by default hidden files and whatever .gitignore, .ignore and
// .rgignore list are left out. Output is ripgrep's format for a pipe
// (`path:line:text` with -n). Output order is not deterministic.
//
// Layers:
//   main.zig    command line
//   c_api.zig   the same search as a C library (include/ffs.h)
//   walk.zig    parallel recursive directory walk (worker pool, one queue)
//   glob.zig    globs and ignore-file rules
//   search.zig  thread pool, per-file work: open, read, binary check, output
//   match.zig   finding the term in bytes (SIMD), no I/O
//   regex.zig   regex: parser, Pike VM, SIMD literal prefilter
//
// A pattern with no regex syntax in it skips the regex engine and goes
// straight to the SIMD search, so `ffs PM_RESUME` costs what it did before
// regexes were the default.
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
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var cli = Cli.parse(arena, args[1..]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => usage(),
    };

    if (cli.help) {
        std.debug.print(help, .{search.autoJobs()});
        std.process.exit(0);
    }
    if (cli.version) {
        std.debug.print("ffs {s}\n", .{build_options.version});
        std.process.exit(0);
    }

    var positional: []const []const u8 = cli.positional.items;
    if (cli.print.mode != .files and cli.patterns.items.len == 0) {
        if (positional.len == 0) usage();
        try cli.patterns.append(arena, positional[0]);
        positional = positional[1..];
    }
    // No path: standard input if something is piped in, as rg does, else
    // the current directory.
    if (positional.len == 0 and cli.print.mode != .files and readableStdin(io)) positional = &.{"-"};

    const term = try cli.pattern(arena);
    var re: ?Regex = null;
    if (term.regex) re = Regex.compile(gpa, term.source, term.ignore_case) catch |err| {
        std.debug.print("ffs: regex parse error: {t} in {s}\n", .{ err, term.source });
        std.process.exit(2);
    };
    defer if (re) |*r| r.deinit();

    var print = cli.print;
    print.file = .stdout();
    // On a terminal rg numbers lines; in a pipe only with -n.
    if (cli.line_number == null) cli.line_number = std.Io.File.stdout().isTty(io) catch false;
    print.line_number = cli.line_number.?;

    const result = search.run(gpa, .{
        .paths = positional,
        .term = term.source,
        .jobs = if (cli.jobs == 0) search.autoJobs() else cli.jobs,
        .ignore_case = term.ignore_case,
        .regex = if (re) |*r| r else null,
        .filter = .{
            .hidden = cli.hidden,
            .ignore_files = cli.ignore,
            .vcs_ignore = cli.vcs_ignore,
            .globs = if (cli.globs.rules.items.len > 0) &cli.globs else null,
            .max_depth = cli.max_depth,
        },
        .invert = cli.invert,
        .max_count = cli.max_count,
        .binary = cli.binary,
    }, .{ .print = print }) catch |err| switch (err) {
        error.WriteFailed => std.process.exit(0), // e.g. `| head` closed the pipe
        else => {
            std.debug.print("ffs: {t}\n", .{err});
            std.process.exit(2);
        },
    };
    if (print.mode == .quiet and result.matched) std.process.exit(0);
    std.process.exit(if (result.errors) 2 else if (result.matched) 0 else 1);
}

const Case = enum { sensitive, insensitive, smart };

const Cli = struct {
    patterns: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,
    fixed: bool = false,
    case: Case = .sensitive,
    word: bool = false,
    whole_line: bool = false,
    invert: bool = false,
    line_number: ?bool = null,
    print: search.Print = .{ .file = undefined },
    max_count: ?usize = null,
    globs: glob.RuleSet = .{},
    hidden: bool = false,
    ignore: bool = true,
    vcs_ignore: bool = true,
    binary: bool = false,
    max_depth: ?usize = null,
    jobs: usize = 0, // 0: automatic
    help: bool = false,
    version: bool = false,

    // Flags may come anywhere, as in rg; `--` ends them. Short flags
    // combine (`-in`), and a value may be attached (`-A5`, `--glob=x`).
    fn parse(a: std.mem.Allocator, args: []const []const u8) !Cli {
        var c: Cli = .{};
        var i: usize = 0;
        var only_positional = false;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (only_positional or arg.len < 2 or arg[0] != '-') {
                try c.positional.append(a, arg);
            } else if (std.mem.eql(u8, arg, "--")) {
                only_positional = true;
            } else if (arg[1] == '-') {
                const eq = std.mem.indexOfScalar(u8, arg, '=');
                const name = arg[2 .. eq orelse arg.len];
                const flag = longFlag(name) orelse return error.UnknownFlag;
                var value: ?[]const u8 = null;
                if (flag.takesValue()) {
                    if (eq) |e| value = arg[e + 1 ..] else {
                        i += 1;
                        if (i == args.len) return error.MissingValue;
                        value = args[i];
                    }
                } else if (eq != null) return error.UnexpectedValue;
                try c.apply(a, flag, value);
            } else {
                var k: usize = 1;
                while (k < arg.len) : (k += 1) {
                    const flag = shortFlag(arg[k]) orelse return error.UnknownFlag;
                    if (flag.takesValue()) {
                        var value = arg[k + 1 ..];
                        if (value.len == 0) {
                            i += 1;
                            if (i == args.len) return error.MissingValue;
                            value = args[i];
                        }
                        try c.apply(a, flag, value);
                        break;
                    }
                    try c.apply(a, flag, null);
                }
            }
        }
        return c;
    }

    fn apply(c: *Cli, a: std.mem.Allocator, flag: Flag, value: ?[]const u8) !void {
        const v = value orelse "";
        switch (flag) {
            .regexp => try c.patterns.append(a, v),
            .fixed_strings => c.fixed = true,
            .ignore_case => c.case = .insensitive,
            .case_sensitive => c.case = .sensitive,
            .smart_case => c.case = .smart,
            .word_regexp => c.word = true,
            .line_regexp => c.whole_line = true,
            .invert_match => c.invert = true,
            .line_number => c.line_number = true,
            .no_line_number => c.line_number = false,
            .with_filename => c.print.with_filename = true,
            .no_filename => c.print.with_filename = false,
            .only_matching => c.print.mode = .only_matching,
            .count => c.print.mode = .count,
            .files_with_matches => c.print.mode = .files_with_matches,
            .quiet => c.print.mode = .quiet,
            .files => c.print.mode = .files,
            .max_count => c.max_count = try number(v),
            .after_context => c.print.after = try number(v),
            .before_context => c.print.before = try number(v),
            .context => {
                c.print.after = try number(v);
                c.print.before = c.print.after;
            },
            .glob => try c.globs.add(a, v, .include),
            .hidden => c.hidden = true,
            .no_hidden => c.hidden = false,
            .no_ignore => c.ignore = false,
            .no_ignore_vcs => c.vcs_ignore = false,
            // -u: no ignore files; -uu: and hidden files; -uuu: and binary files.
            .unrestricted => if (!c.ignore) {
                if (c.hidden) c.binary = true else c.hidden = true;
            } else {
                c.ignore = false;
            },
            .text => c.binary = true,
            .max_depth => c.max_depth = try number(v),
            .threads => c.jobs = if (std.mem.eql(u8, v, "auto")) 0 else try number(v),
            .help => c.help = true,
            .version => c.version = true,
            // Accepted for compatibility; ffs prints no color and no headings.
            .color, .no_heading, .heading, .no_messages => {},
        }
    }

    const Term = struct { source: []const u8, regex: bool, ignore_case: bool };

    // The patterns as one search: a literal for the SIMD search when that
    // is enough, else one regex.
    fn pattern(c: *const Cli, a: std.mem.Allocator) !Term {
        const pats = c.patterns.items;
        const ignore_case = switch (c.case) {
            .sensitive => false,
            .insensitive => true,
            // Smart case: ignore case unless a pattern has an upper-case letter.
            .smart => for (pats) |p| {
                if (hasUpper(p)) break false;
            } else true,
        };
        for (pats) |p| if (std.mem.indexOfScalar(u8, p, '\n') != null) {
            std.debug.print("ffs: the literal '\\n' is not allowed in a pattern\n", .{});
            std.process.exit(2);
        };
        if (pats.len == 1 and !c.word and !c.whole_line and pats[0].len > 0 and (c.fixed or !hasMeta(pats[0]))) {
            return .{ .source = pats[0], .regex = false, .ignore_case = ignore_case };
        }
        var src: std.ArrayList(u8) = .empty;
        if (c.whole_line) try src.appendSlice(a, "^(?:");
        if (c.word) try src.appendSlice(a, "\\b(?:");
        for (pats, 0..) |p, k| {
            if (k > 0) try src.append(a, '|');
            if (pats.len > 1) try src.appendSlice(a, "(?:");
            try src.appendSlice(a, if (c.fixed) try regex.escape(a, p) else p);
            if (pats.len > 1) try src.append(a, ')');
        }
        if (c.word) try src.appendSlice(a, ")\\b");
        if (c.whole_line) try src.appendSlice(a, ")$");
        return .{ .source = src.items, .regex = true, .ignore_case = ignore_case };
    }
};

fn hasMeta(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, "\\.+*?()|[]{}^$") != null;
}

fn hasUpper(p: []const u8) bool {
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\') {
            i += 1; // \W, \S, \D are classes, not letters
        } else if (std.ascii.isUpper(p[i])) return true;
    }
    return false;
}

fn number(v: []const u8) !usize {
    return std.fmt.parseInt(usize, v, 10);
}

fn readableStdin(io: std.Io) bool {
    const st = std.Io.File.stdin().stat(io) catch return false;
    return switch (st.kind) {
        .named_pipe, .file, .unix_domain_socket => true,
        else => false,
    };
}

const Flag = enum {
    regexp,
    fixed_strings,
    ignore_case,
    case_sensitive,
    smart_case,
    word_regexp,
    line_regexp,
    invert_match,
    line_number,
    no_line_number,
    with_filename,
    no_filename,
    only_matching,
    count,
    files_with_matches,
    quiet,
    files,
    max_count,
    after_context,
    before_context,
    context,
    glob,
    hidden,
    no_hidden,
    no_ignore,
    no_ignore_vcs,
    unrestricted,
    text,
    max_depth,
    threads,
    help,
    version,
    color,
    no_heading,
    heading,
    no_messages,

    fn takesValue(f: Flag) bool {
        return switch (f) {
            .regexp, .max_count, .after_context, .before_context, .context, .glob, .max_depth, .threads, .color => true,
            else => false,
        };
    }
};

fn shortFlag(c: u8) ?Flag {
    return switch (c) {
        'e' => .regexp,
        'F' => .fixed_strings,
        'i' => .ignore_case,
        's' => .case_sensitive,
        'S' => .smart_case,
        'w' => .word_regexp,
        'x' => .line_regexp,
        'v' => .invert_match,
        'n' => .line_number,
        'N' => .no_line_number,
        'H' => .with_filename,
        'I' => .no_filename,
        'o' => .only_matching,
        'c' => .count,
        'l' => .files_with_matches,
        'q' => .quiet,
        'm' => .max_count,
        'A' => .after_context,
        'B' => .before_context,
        'C' => .context,
        'g' => .glob,
        '.' => .hidden,
        'u' => .unrestricted,
        'a' => .text,
        'd' => .max_depth,
        'j' => .threads,
        'h' => .help,
        'V' => .version,
        else => null,
    };
}

fn longFlag(name: []const u8) ?Flag {
    const aliases = [_]struct { []const u8, Flag }{
        .{ "regexp", .regexp },
        .{ "fixed-strings", .fixed_strings },
        .{ "ignore-case", .ignore_case },
        .{ "case-sensitive", .case_sensitive },
        .{ "smart-case", .smart_case },
        .{ "word-regexp", .word_regexp },
        .{ "line-regexp", .line_regexp },
        .{ "invert-match", .invert_match },
        .{ "line-number", .line_number },
        .{ "no-line-number", .no_line_number },
        .{ "with-filename", .with_filename },
        .{ "no-filename", .no_filename },
        .{ "only-matching", .only_matching },
        .{ "count", .count },
        .{ "files-with-matches", .files_with_matches },
        .{ "quiet", .quiet },
        .{ "files", .files },
        .{ "max-count", .max_count },
        .{ "after-context", .after_context },
        .{ "before-context", .before_context },
        .{ "context", .context },
        .{ "glob", .glob },
        .{ "hidden", .hidden },
        .{ "no-hidden", .no_hidden },
        .{ "no-ignore", .no_ignore },
        .{ "no-ignore-vcs", .no_ignore_vcs },
        .{ "unrestricted", .unrestricted },
        .{ "text", .text },
        .{ "max-depth", .max_depth },
        .{ "maxdepth", .max_depth },
        .{ "threads", .threads },
        .{ "help", .help },
        .{ "version", .version },
        .{ "color", .color },
        .{ "colour", .color },
        .{ "no-heading", .no_heading },
        .{ "heading", .heading },
        .{ "no-messages", .no_messages },
    };
    for (aliases) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

const help =
    \\usage: ffs [OPTIONS] PATTERN [PATH...]
    \\       ffs [OPTIONS] -e PATTERN... [PATH...]
    \\       ffs --files [OPTIONS] [PATH...]
    \\
    \\A ripgrep-compatible search. PATTERN is a regex (see src/regex.zig).
    \\With no PATH, searches standard input if it is a pipe or file, else
    \\the current directory. Hidden files and paths listed in .gitignore,
    \\.ignore and .rgignore are skipped. Exit status: 0 if something
    \\matched, 1 if nothing did, 2 on an error.
    \\
    \\Patterns:
    \\  -e, --regexp PATTERN    a pattern; repeat to search for any of several
    \\  -F, --fixed-strings     patterns are literal text, not regexes
    \\  -i, --ignore-case       ASCII letters match either case
    \\  -S, --smart-case        ignore case unless a pattern has an upper-case letter
    \\  -s, --case-sensitive    the default
    \\  -w, --word-regexp       matches must be whole words
    \\  -x, --line-regexp       matches must be whole lines
    \\  -v, --invert-match      report the lines that do not match
    \\
    \\Output:
    \\  -n, --line-number       print line numbers (default on a terminal)
    \\  -N, --no-line-number
    \\  -H, --with-filename     print the path (default unless one file is searched)
    \\  -I, --no-filename
    \\  -o, --only-matching     print each match, not the whole line
    \\  -c, --count             print the number of matching lines per file
    \\  -l, --files-with-matches  print only the paths of files with a match
    \\  -q, --quiet             print nothing; the exit status says if anything matched
    \\  -m, --max-count N       stop reading a file after N matching lines
    \\  -A, --after-context N   N lines after each match
    \\  -B, --before-context N  N lines before each match
    \\  -C, --context N         N lines before and after each match
    \\
    \\Files:
    \\      --files             list the files that would be searched; no PATTERN
    \\  -g, --glob GLOB         search only files matching GLOB; !GLOB excludes
    \\  -., --hidden            search hidden files and directories too
    \\      --no-hidden         skip hidden files and directories (the default)
    \\      --no-ignore         don't use .gitignore, .ignore or .rgignore files
    \\      --no-ignore-vcs     don't use .gitignore files
    \\  -u, --unrestricted      -u: --no-ignore; -uu: and --hidden; -uuu: and --text
    \\  -a, --text              search binary files as if they were text
    \\  -d, --max-depth N       descend at most N directory levels
    \\
    \\  -j, --threads N|auto    worker threads (default: auto = {d} here, the
    \\                          performance-core count on Apple silicon, else
    \\                          every logical CPU)
    \\  -h, --help
    \\  -V, --version
    \\
;

fn usage() noreturn {
    std.debug.print(
        \\usage: ffs [OPTIONS] PATTERN [PATH...]
        \\       ffs --files [OPTIONS] [PATH...]
        \\Try 'ffs --help' for more.
        \\
    , .{});
    std.process.exit(2);
}

test {
    _ = @import("c_api.zig");
    _ = @import("glob.zig");
    _ = @import("match.zig");
    _ = @import("regex.zig");
    _ = @import("search.zig");
    _ = @import("walk.zig");
}

test "command line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try Cli.parse(a, &.{ "-nA5", "-g", "*.swift", "--glob=!build", "foo|bar", "Sources", "-i", "--", "-x" });
    try std.testing.expect(c.line_number.?);
    try std.testing.expectEqual(5, c.print.after);
    try std.testing.expectEqual(2, c.globs.rules.items.len);
    try std.testing.expectEqual(.insensitive, c.case);
    try std.testing.expectEqual(3, c.positional.items.len);
    try std.testing.expectEqualStrings("-x", c.positional.items[2]);
    try std.testing.expectError(error.UnknownFlag, Cli.parse(a, &.{"-Z"}));
    try std.testing.expectError(error.MissingValue, Cli.parse(a, &.{"-A"}));

    var lit = try Cli.parse(a, &.{"PM_RESUME"});
    try lit.patterns.append(a, "PM_RESUME");
    try std.testing.expect(!(try lit.pattern(a)).regex);

    var multi = try Cli.parse(a, &.{ "-F", "-w", "-e", "a.b", "-e", "c" });
    const t = try multi.pattern(a);
    try std.testing.expect(t.regex);
    try std.testing.expectEqualStrings("\\b(?:(?:a\\.b)|(?:c))\\b", t.source);

    var smart = try Cli.parse(a, &.{ "-S", "-e", "\\Wfoo" });
    try std.testing.expect((try smart.pattern(a)).ignore_case);
    var smart_upper = try Cli.parse(a, &.{ "-S", "-e", "Foo" });
    try std.testing.expect(!(try smart_upper.pattern(a)).ignore_case);
}
