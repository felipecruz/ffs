# Changelog

## 0.0.10 — unreleased

ffs can stand in for ripgrep under Claude Code's own search tools, which
call rg with flags ffs didn't have.

**Command line**

- `--json`: ripgrep's JSON Lines messages (`begin`, `match`, `context`,
  `end`, `summary`), field for field; only the timings differ. Text that
  isn't UTF-8 comes base64-encoded, as ripgrep's `bytes`.
- `-0`/`--null`: a NUL byte after each path instead of `:` or a newline.
- `-M`/`--max-columns N`: lines longer than N bytes, newline included,
  print as `[Omitted long matching line]`.
- `-t`/`--type`, `-T`/`--type-not`, `--type-list`: ripgrep 15.2's file
  types, with its rules (a named file is searched whatever its type, a
  matching `-g` decides alone, a selected type brings back a hidden file).
- `--iglob`: `-g` with ASCII letters matching either case.
- `FFS_RG`: the path of a ripgrep binary that runs, unchanged, any command
  line ffs can't (`-U`, `--sort`, `--follow`, `--type-add`, unknown flags).
  Without it, an unknown flag is still an error, now naming the flag.
- `tests/compat.sh` adds the command lines Claude Code's Grep tool builds:
  `-l --null`, `-c -H --null` and `--json -n`, with `--hidden`, the VCS
  directories left out and `--max-columns 500`; 124 checks in all. On the
  Linux kernel those take 75–80 ms, against ripgrep's 102–106 ms.

## 0.0.9 — 2026-10-25

Regexes with no fixed text, the one kind of search where ripgrep was
several times faster, are now faster in ffs too. On the Linux kernel,
`[0-9a-f]{16}` takes 97 ms (0.0.8: 1.3 s; ripgrep 281 ms), and on the
LLVM monorepo ffs is faster than ripgrep on all 21 searches of the new
`bench/llvm.sh`, 1.2x to 3.6x. EXPERIMENTS.md, Experiment 17, has every
step and number.

**Regex**

- A lazy DFA (`src/dfa.zig`) answers "does this line match?" in one table
  lookup per byte, building its states while it searches. It checks the
  lines the literal prefilter finds and scans whole files when a regex has
  no fixed text. Patterns with `\b` stay on the Pike VM, as do patterns
  that need too many states (the DFA notices and gives up).
- A SIMD scan for runs of one character class is the prefilter for regexes
  with no fixed text that need such a run (`[0-9a-f]{16}`,
  `[A-Za-z_]{30,}`, `\d{5,}`). LLVM `[A-Za-z_]{30,}`: 1,038 ms to 156 ms
  (ripgrep 478).
- Of the pieces of fixed text a regex requires, the prefilter now uses the
  one that should be rarest in source code, not the longest.
- The default and PCRE2 builds are now within a few percent of each other;
  PCRE2 is used where the DFA can't answer.

**Search**

- The SIMD search compares a term's two rarest bytes when its first and
  last are common, from a byte-frequency table of real source trees:
  `class \w+ : public \w+` on LLVM went from 210 ms to 125 ms (ripgrep
  178).

**Hardening**

- `.gitignore` lines and `-g` globs: `**` is matched with a state set
  instead of backtracking (`**a**a**a**a**b` hung ffs), patterns are capped
  at 4096 bytes and brace expansion is bounded; ignore-file lines that are
  too complex are skipped, a `-g` glob that is too complex is an error.
- Regexes nested deeper than 250 are rejected (they overflowed the stack),
  and repeats of an empty body (`(){4294967295}`) no longer loop.
- PCRE2 JIT and match-limit errors fall back to the Pike VM instead of
  counting as "no match".
- Running out of memory during the walk exits 2, not 1; the C API reports
  it as `FFS_ENOMEM` or `FFS_EROOT`.

**Docs and benchmarks**

- A terminal demo (`docs/demo.gif`) and install instructions for the
  release archives.
- `bench/llvm.sh` and the LLVM fixture; the kernel, Redis and LLVM suites
  re-measured on Linux (`results-linux/`), and the macOS suite with the
  worker-pool walk (`results-macos/`, Experiment 16).
- Known slow case: a `\b` pattern whose only fixed text is common,
  `\b[a-z]+_[a-z]+\b` on the kernel, 2.4 s against ripgrep's 0.65 s.

## 0.0.8 — 2026-10-15

First release: a file searcher with ripgrep's command line, for the flags
coding agents use (SEARCH_CMDs.md), measured on macOS (Apple M5) and Linux
(AMD Ryzen 9 PRO 6950H, 16 threads, Omarchy/Arch). Every number below is in
the README and EXPERIMENTS.md.

**Command line**

- `ffs PATTERN [PATH...]` and `ffs --files [PATH...]`, as in ripgrep.
  PATTERN is a regex; one with no regex syntax goes straight to the SIMD
  search. `-e` (several patterns), `-F`, `-w`, `-x`, `-i`, `-S`, `-s`, `-v`.
- Paths: any number of files and directories, `-` for standard input, and
  standard input by default when something is piped in. No path: the
  current directory, printed without `./`.
- ripgrep's defaults: hidden files and whatever `.gitignore` (inside a git
  repository), `.ignore`, `.rgignore` and `.git/info/exclude` list are
  skipped, including ignore files in the directories above the search root.
  `--hidden`, `--no-ignore`, `--no-ignore-vcs`, `-u`/`-uu`/`-uuu`, `-a`.
- `--files`, `-g`/`--glob` (gitignore syntax, `**`, `{a,b}`, `!` to
  exclude, matched against the path as printed), `-d`/`--max-depth`.
- Output as ripgrep prints it in a pipe: `-n`/`-N`, `-H`/`-I`, `-o`, `-c`,
  `-l`, `-q`, `-m`, `-A`/`-B`/`-C` with `-` and `--` separators. Exit status
  0 on a match, 1 on none, 2 on an error (a missing path is reported and the
  other paths are still searched). `-j N|auto`, `-V`, `-h`.
- `tests/compat.sh` runs 97 command lines through ffs and ripgrep and
  compares stdout and exit status; CI runs it on Linux and macOS.

**Search**

- SIMD search: first/last byte filter over 16-byte blocks, with line
  numbers counted in the same pass. Streaming reads through a 256 KiB
  buffer (7–12 MB peak memory); a UTF-8 byte-order mark is stripped and
  files with a NUL byte are skipped, as binary.
- Regex: `.` `[...]` `[[:alpha:]]` `\d \w \s \b` `\t \r \xNN` `^ $`
  `* + ? {n,m}` and lazy forms, `|`, `(...)`, `(?:...)`, `(?i)`, on a Pike
  VM that never backtracks. `\b` sees UTF-8 characters, as ripgrep does.
- A literal prefilter in front of the VM: the SIMD search finds the lines
  containing one of up to 16 literals every match needs (`PM_` in
  `PM_[A-Z_]+`, either name in `dictFind|dictAdd`), and an alternation of
  plain text skips the VM. `PM_RESUME|ERR_PTR|dictFind` on the Linux kernel:
  106 ms, against 124 ms for ripgrep.
- Optional PCRE2 build, `zig build -Dpcre2=true`: the system's PCRE2 JIT
  does the VM's work. `[0-9a-f]{16}` on the Linux kernel: 1,382 ms to
  392 ms (ripgrep 296).

**Threads**

- A worker pool over one shared queue of directories and file batches, so
  a directory with thousands of files no longer pins one thread. Thread
  scaling on 16 threads: 7.6x; ahead of ripgrep at every thread count from
  1 to 16 on Linux.
- `-j auto`: the performance-core count on Apple silicon, every logical CPU
  elsewhere.

**C library**

- `libffs.a` + `ffs.h` with `ffs_search()` and `ffs_version()`. Built with
  `link_libc`: without it, `ffs_search` hung forever on Linux.

**Docs and tooling**

- `docs/`: a page per topic, about 30 examples and a man page (`docs/ffs.1`,
  installed by `zig build`), published at https://felipecruz.github.io/ffs/.
  `tests/docs.sh` runs every example inside the Redis 8.0.2 source and
  checks its output, and checks that every flag is documented.
- CI on GitHub Actions: `zig fmt`, the tests, CLI and C library smoke tests,
  ripgrep compatibility, the docs check, the PCRE2 build, a version check,
  six cross-compiled targets and a `kcov` coverage report on pull requests.
  `release.yml` builds every target on a tag and attaches the archives.
- Benchmarks: `bench/agent.sh` (an agent's search session, ffs vs ripgrep),
  `bench/h2h.sh` (matched thread counts) and the rest of `bench/`, with tools
  found through `bench/tools.sh`.

Builds for Windows and Intel macOS are untested.
