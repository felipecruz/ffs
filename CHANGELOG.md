# Changelog

## 0.0.8 — 2026-10-14

First tagged release.

- `ffs <folder> <term>`: recursive search of every text file (nothing
  ignored, binary files skipped), printing `path:line`.
- Threads: one task per directory on `std.Io.Threaded`; `-j N` or `-j auto`
  (default: the performance-core count on Apple silicon, else 4).
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
