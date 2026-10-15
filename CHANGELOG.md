# Changelog

## 0.0.9 — unreleased

**Breaking: the command line is now ripgrep's**, so ffs can stand in for
`rg` in what coding agents run (SEARCH_CMDs.md).
`ffs <folder> <term>` is now `ffs PATTERN [PATH...]`; `-E` and `--content`
are gone (PATTERN is a regex, and `-n` prints `path:line:content`).

- PATTERN is a regex by default; one with no regex syntax still goes
  straight to the SIMD search, so literal searches cost what they did.
  `-F`, `-e` (several patterns), `-w`, `-x`, `-S`, `-s`.
- Paths: any number of files and directories, `-` for standard input, and
  standard input by default when something is piped in. No path: the
  current directory, printed without `./`.
- ripgrep's defaults: hidden files and whatever `.gitignore` (inside a git
  repository), `.ignore`, `.rgignore` and `.git/info/exclude` list are
  skipped, including ignore files in the directories above the search
  root. `--hidden`, `--no-ignore`, `--no-ignore-vcs`, `-u`/`-uu`/`-uuu`.
  On the Linux kernel fixture the default search is still 79 ms, against
  100 ms for ripgrep's default.
- `--files`, `-g`/`--glob` (gitignore syntax, `**`, `{a,b}`, `!` to
  exclude), `-d`/`--max-depth`.
- Output modes: `-n`/`-N`, `-H`/`-I`, `-o`, `-c`, `-l`, `-q`, `-m`, `-v`,
  `-A`/`-B`/`-C` (with ripgrep's `-` and `--` separators), `-a`.
- Exit status as in ripgrep: 0 on a match, 1 on none, 2 on an error (a
  missing path is reported and the other paths are still searched).
- Regex: `(?:...)`, `(?i)`, lazy `*?` `+?` `??`, `\r`, `\xNN`, POSIX classes
  (`[[:alpha:]]`), and `\b` sees UTF-8 characters, as in ripgrep.
- Regex prefilter for alternations, the most common shape of agent search
  (`a|b|c`): every match must contain one of a set of up to 16 literals,
  and a new SIMD loop (`match.findLinesAny`) finds the lines that contain
  any of them. When the regex is nothing but those literals, the VM is
  skipped. `PM_RESUME|ERR_PTR|dictFind` on the Linux kernel fixture: 1.18 s
  to 106 ms (ripgrep: 124 ms).
- Optional PCRE2 build, `zig build -Dpcre2=true` (links the system's
  libpcre2-8). Patterns are still parsed and validated by regex.zig; PCRE2's
  JIT replaces the Pike VM for candidate lines, `-o` and whole-buffer scans
  of regexes with no literal. Kernel fixture: `[0-9a-f]{16}` 1,382 to
  392 ms (ripgrep 296), `spin_lock|mutex_lock|struct [a-z]+_ops` 261 to
  123 ms (ripgrep 140). Patterns with `\b` keep the VM, whose `\b` sees
  UTF-8 as ripgrep's does.
- New `bench/agent.sh`: 15 agent-style calls on the Redis source, each
  timed against ripgrep with identical output required; the table is in
  the README. ffs is faster on 14 of them and 2.4x slower on a regex with
  no literal.
- New `tests/compat.sh`: about 100 command lines run through ffs and
  ripgrep, comparing output and exit status; run in CI on Linux and macOS.

Measured on Linux for the first time (AMD Ryzen 9 PRO 6950H, 16 threads,
Omarchy/Arch): see EXPERIMENTS.md, Experiment 15.

- Threads: a worker pool over one shared queue of directories and file
  batches, instead of one task per directory. A directory with thousands of
  files no longer pins the thread that found it, and the read buffer is
  allocated once per worker instead of once per directory. On the Linux
  kernel fixture: 1.69x faster at `-j 16` (135 ms to 79 ms), and 13% faster
  even at `-j 1`; thread scaling 5.0x to 7.4x.
- `-j auto` now uses every logical CPU off macOS, instead of 4. The old
  fallback was an Apple-silicon number and cost 1.74x on a 16-thread box.
  Apple silicon still uses its performance-core count.
- Fixed: `ffs_search` from the C library hung forever on Linux, at any thread
  count. `libffs.a` was built without `link_libc`, so it brought its own
  threading runtime into a host program that already had libc's. Present in
  0.0.8; never seen because the C example had only ever been run on macOS.
- CI/CD on GitHub Actions: `ci.yml` runs `zig fmt`, the tests, a CLI smoke
  test, a C library smoke test (with a timeout, so the hang above cannot
  come back unnoticed) and a version-consistency check on Linux and macOS,
  cross-compiles all six targets, and publishes a `kcov` line-coverage
  report for `src/`, posted on each pull request as a per-file table (one
  comment, edited in place) and kept as an HTML artifact.
  `release.yml` builds every target on a tag and attaches
  the archives, with the CHANGELOG section as the release notes. New
  `zig build test-bin` builds the test binary without running it, for the
  coverage tool.
- Benchmark scripts find their tools through `bench/tools.sh` (`RG`, `ACK`,
  `GREP`, `HYPERFINE`, `FFS`, `OUT` all overridable) instead of hardcoded
  Homebrew paths, skip `ack` when it is not installed, and read the CPU
  topology with `lscpu` off macOS. New `bench/h2h.sh`: ffs vs ripgrep at
  matched thread counts.

## 0.0.8 — 2026-10-14

First tagged release.

- `ffs <folder> <term>`: recursive search of every text file (nothing
  ignored, binary files skipped), printing `path:line`.
- Threads: one task per directory on `std.Io.Threaded`; `-j N` or `-j auto`
  (default: the performance-core count on Apple silicon, else 4). Both
  changed in Unreleased, above.
- SIMD search: first/last byte filter over 16-byte blocks, with line
  numbers counted in the same pass.
- `--content` prints `path:line:content`.
- `-i` ASCII case-insensitive search.
- `-E` regex: `.` `[...]` `\d \w \s \b` `^ $` `* + ? {n,m}` `|` `( )`, a Pike
  VM behind a SIMD literal prefilter.
- Streaming reads through a 256 KiB buffer (7–9 MB peak memory); a UTF-8
  byte-order mark is stripped, as ripgrep does.
- C library: `libffs.a` + `ffs.h` with `ffs_search()` and `ffs_version()`.
- `-V`/`--version`.

Tested on macOS (Apple M5) only; builds for Linux, Windows and Intel macOS
are untested. See EXPERIMENTS.md for every benchmark.
