# Changelog

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
