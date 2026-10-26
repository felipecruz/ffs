# ffs — experiment log

The lab notebook behind ffs: every change, how it was measured and what it
showed, in order. For the summary see [README.md](README.md); for how the
code works see [ARCHITECTURE.md](ARCHITECTURE.md).

## Setup

Environment: macOS 27.0.1, Apple M5, Homebrew.

> **Experiments 1–14, 16, 18 and 19 run on macOS; Experiments 15 and 17 run on Linux.**
> "Linux" in the tables below always means the *Linux kernel source tree*
> used as a fixture (`fixtures/linux`), not the Linux operating system.
> Conclusions about threads and system time in Experiments 1–14 and 16 are
> about macOS / APFS. Experiment 15 has its own environment table, and its
> numbers live in `results-linux/`; Experiment 16 re-measures this Mac with
> the current code into `results-macos/`. `results/` stays as Experiments
> 1–14 left it.

| Tool | Version | Path | Install |
|---|---|---|---|
| ripgrep | 15.2.0 | `/opt/homebrew/bin/rg` | `brew install ripgrep` |
| ack | 3.10.0 | `/opt/homebrew/bin/ack` | `brew install ack` |
| grep | 2.6.0-FreeBSD (BSD grep) | `/usr/bin/grep` | system |

> **Always invoke tools by absolute path.** Shell environments (e.g. Claude Code)
> may define `rg`/`grep` as shell functions that wrap a different binary, which
> would silently benchmark the wrong program.

### Fixture

[Redis](https://github.com/redis/redis) at tag `8.0.2`, shallow clone:

```sh
mkdir -p fixtures
git clone --depth 1 --branch 8.0.2 https://github.com/redis/redis.git fixtures/redis
```

- Commit: `994bc96bb1744cb153392fc96bdba43eae56e17f`
- ~1,680 tracked files (mostly C, plus Tcl and Lua), ~25 MB on disk including `.git`

Experiment 17 adds the [LLVM monorepo](https://github.com/llvm/llvm-project),
shallow clone of `main` at `cced08fcc92db61044c0e32ef35444fa48246345`
(2026-10-25): 188,582 files, 3.1 GB including `.git`.

```sh
git clone --depth 1 https://github.com/llvm/llvm-project.git fixtures/llvm
```

## Experiment 1 — literal search, count matches

Pattern `dictFind`, run once from `fixtures/redis`, timed with `/usr/bin/time -p`:

```sh
/opt/homebrew/bin/rg -c dictFind .
/opt/homebrew/bin/ack -c dictFind
/usr/bin/grep -rc dictFind .
```

| Tool | Matches | Wall time |
|---|---|---|
| ripgrep | 119 | 0.03 s |
| ack | 119 | 0.09 s |
| grep -r | 119 | 0.12 s |

All three tools agree on the match count.

### Caveats

- Single run, no warmup. Results include cold/warm cache noise.
- At this corpus size runtimes are tens of milliseconds, so process startup
  (notably Perl startup for ack) is a large share of the measurement.
- Default ignore rules differ: ripgrep respects `.gitignore` and skips hidden
  files/`.git`; ack skips VCS dirs and filters by known file types; `grep -r`
  searches everything, including `.git`.

## Experiment 2 — hyperfine: ffs vs rg, ack, grep

The script `bench/bench.sh [term] [fixture]` (defaults: `dictFind`,
`fixtures/redis`) runs hyperfine 2.0.0 with `-N --warmup 5 --min-runs 30`.
It writes Markdown and JSON results to `results/`. Every tool returned the
same 119 matching lines.

> This experiment was run with the first version of ffs, which also searched
> binary files. `bench/bench.sh` now runs Experiment 3 in place of the
> "same work" table below.

**Defaults:** each tool runs with its default behavior. ripgrep and ack
skip `.git`; grep and ffs do not.

| Command | Mean [ms] | vs ffs | Memory |
|:---|---:|:---|---:|
| `ffs` (ReleaseFast) | 53.5 ± 2.3 | — | 7.1 MiB |
| `rg -n` | 22.2 ± 6.8 | 2.4× faster | 8.9 MiB |
| `ack` | 94.3 ± 1.8 | 1.8× slower | 12.8 MiB |
| `grep -rn` | 125.4 ± 3.8 | 2.3× slower | 1.8 MiB |

**Same work:** every tool searches all files, including `.git`, hidden and
binary files.

| Command | Mean [ms] | vs ffs | Memory |
|:---|---:|:---|---:|
| `ffs` | 52.5 ± 0.8 | — | 7.1 MiB |
| `rg -uuu -n` | 19.3 ± 0.7 | 2.7× faster | 6.6 MiB |
| `grep -rn` | 127.1 ± 14.0 | 2.4× slower | 1.8 MiB |

Observations:

- The naive single-threaded ffs already beats ack and BSD grep.
- ripgrep is about 2.5× faster than ffs, likely because it searches with
  SIMD instructions and uses multiple threads.
- `rg -uuu` is *faster* than plain `rg` even though it searches more files.
  This suggests that reading `.gitignore` files costs more than searching
  `.git` on a repo this small.

## Experiment 3 — all text files, nothing ignored

Every tool searches the same set of files: everything under the fixture,
including `.git`, hidden files and files listed in `.gitignore`, but not
binary files.

| Tool | Flags | Binary rule |
|---|---|---|
| ffs | — | skips any file containing a NUL byte |
| ripgrep | `-uu` (no ignore files, include hidden) | default: skips a file once it finds a NUL byte |
| ack | `--ignore-ack-defaults --noenv` (no built-in ignored dirs or files) | Perl `-T` heuristic |
| BSD grep | `-rI` | `-I` skips binary files |

The tools agree on what to search. For the terms `dictFind`, `redis`, `the`
and `sample`, all four tools matched the same set of files (25, 447,
1,353 and 109 files). The matches include files under `.git`. ffs and
`rg -uu -n` also agree line for line (for example, 37,475 lines for `the`).

Results for `dictFind` on `fixtures/redis` (1,706 files on disk):

| Command | Mean [ms] | vs ffs |
|:---|---:|:---|
| `ffs` | 44.7 ± 0.5 | — |
| `rg -uu -n` | 19.6 ± 3.5 | 2.3× faster |
| `ack --ignore-ack-defaults --noenv` | 84.8 ± 0.5 | 1.9× slower |
| `grep -rnI` | 93.0 ± 10.8 | 2.1× slower |

With the binary check, ffs went from about 53 ms to about 44 ms. Checking
for a NUL byte (`std.mem.indexOfScalar`) is cheaper than running the naive
search over the git pack and index files. On the same run, the defaults
table from Experiment 2 measured ffs 43.7, rg 19.7, ack 94.4 and grep
121.4 ms.

## Experiment 4 — SIMD search in ffs

The naive byte-by-byte loop is replaced by a SIMD search (the
"first and last byte" technique):

- For each block of 16 candidate positions (`std.simd.suggestVectorLength(u8)`
  on the M5 / NEON), it compares the term's first byte at offset 0 and its
  last byte at offset `len - 1`. Only positions where both match are checked
  in full.
- Line numbers are no longer counted byte by byte. Newlines are counted only
  up to each match, with `std.mem.countScalar` (also SIMD).
- After a match, it skips to the next line with `std.mem.indexOfScalarPos`.

The original scalar loop is kept as `searchNaive`. A randomized test
(`zig build test`) runs 20,000 cases and checks that the SIMD version prints
exactly the same output. On the fixture, ffs and `rg -uu -nF` print the same
`path:line` set for `dictFind`, `the`, `redis`, `e`, `x`, `#include` and
`sample` (up to 314,778 lines).

Vector width made no difference: 16, 32 and 64 bytes all measured about
21 ms. The default width is kept.

Results for `dictFind` on `fixtures/redis`, all text files, nothing ignored:

| Command | Wall [ms] | vs ffs | CPU time [ms] (user + sys) | Instructions |
|:---|---:|:---|---:|---:|
| `ffs` (SIMD) | 21.6 ± 0.4 | — | 21.1 (2.4 + 18.7) | 364 M |
| `rg -uu -n` | 19.4 ± 1.6 | 1.1× faster | 122.2 (5.9 + 116.3) | 404 M |
| `ack --ignore-ack-defaults --noenv` | 86.8 ± 2.1 | 4.0× slower | 85.2 (44.1 + 41.2) | 1,378 M |
| `grep -rnI` | 92.8 ± 3.3 | 4.3× slower | 91.8 (69.3 + 22.6) | 1,923 M |

With each tool's default behavior: ffs 22.2, rg 19.9, ack 96.5, grep 124.5 ms.

Observations:

- SIMD halved ffs's time, from 44.7 ms to 21.6 ms. ffs is now within about
  10% of ripgrep.
- ffs is now mostly system time (18.7 of 21.1 ms): opening, reading and
  walking files. The search itself takes about 2 ms of user time.
- ripgrep uses about 6× more CPU time than ffs, spread across threads, to
  finish slightly sooner.

## Experiment 5 — parallel search with `std.Io`

Each file is now its own task, started with `Io.Group.async` on the `Io`
that `main` receives (`std.Io.Threaded`, a thread pool with CPU count − 1
threads). When every thread is busy, `async` runs the task inline on the
calling thread. The main thread walks the directory tree and starts one task
per file. Each task does the following:

1. Reads the file with `root.readFileAlloc`.
2. Skips it if it is binary.
3. Collects its matches in its own buffer (`Io.Writer.Allocating`).
4. Takes an `Io.Mutex` and writes the buffer to the shared stdout writer, so
   lines from different files never interleave.

`--io=serial` runs the same code without tasks.

**Evented I/O is not available on macOS in Zig 0.17.0.** `std.Io.Evented`
maps to `std.Io.Dispatch` (Grand Central Dispatch), which fails to compile:
`no field named 'processReplacePath' in struct 'Io.VTable'`. `std.Io.Kqueue`
fails the same way (`fileWriteStreaming`). Because ffs is written against the
`Io` interface, switching to one of them later should only change how `io` is
created.

Correctness checks:

- Both modes print the same `path:line` set as `rg -uu -nF` for `dictFind`,
  `the`, `e`, `#include` and `sample`.
- The debug build reports no leaks.
- A ThreadSanitizer build (`-fsanitize-thread`) reports no data races.

Results for `dictFind` on `fixtures/redis`, all text files, nothing ignored:

| Command | Wall [ms] | vs ffs | CPU [ms] (user + sys) | Memory |
|:---|---:|:---|---:|---:|
| `ffs` (threaded) | 16.7 ± 0.2 | — | 91.8 (4.9 + 86.8) | 8.5 MiB |
| `ffs --io=serial` | 22.0 ± 1.0 | 1.3× slower | 21.4 (2.5 + 18.9) | 7.1 MiB |
| `rg -uu -n` | 19.3 ± 0.9 | 1.2× slower | 121.3 (5.9 + 115.4) | 6.6 MiB |
| `ack --ignore-ack-defaults --noenv` | 86.9 ± 0.5 | 5.2× slower | 85.5 (44.1 + 41.3) | 12.4 MiB |
| `grep -rnI` | 92.4 ± 3.2 | 5.5× slower | 91.8 (69.4 + 22.4) | 1.8 MiB |

With each tool's default behavior: ffs 16.9, rg 19.9, ack 96.9, grep 125.7 ms.

Observations:

- **ffs is now faster than ripgrep** on this fixture: 16.7 ms vs 19.3 ms.
- Going parallel gave only a 1.3× speedup, and system time went up 4.6×
  (18.9 → 86.8 ms). The work is file-system syscalls on many small files,
  and threads mostly contend in the kernel. ripgrep shows the same pattern.
- Directory walking is still single-threaded on the main thread, which
  limits how fast tasks can be started.

## Experiment 6 — larger fixture (Linux kernel) and query shapes

Fixture: [Linux](https://github.com/torvalds/linux) at tag `v6.19`, shallow
clone:

```sh
git clone --depth 1 --branch v6.19 https://github.com/torvalds/linux.git fixtures/linux
```

- Commit: `05f7e89ab9731565d8a62e3b5d1ec206485eeb0b`
- 92,197 tracked files and 1.9 GB on disk, including a 286 MB `.git` with a
  285 MB pack file. That is about 75× Redis.
- Only 92,124 files land on disk. The macOS file system is case-insensitive,
  so files whose names differ only in case collide.

The script `bench/searches.sh [fixture]` runs hyperfine with
`-N -i --warmup 3 --min-runs 5`. It searches all text files with nothing
ignored, using the same flags as Experiment 3 plus fixed-string mode (`-F`,
`-Q`). Results are saved as `results/linux-<query>.{md,json}`. `-i` is
needed because rg, ack and grep exit 1 when nothing matches.

Correctness: ffs and `rg -uu -nF` print identical `path:line` sets for every
query below, and also for `static int __init` (8,690 lines) and
`EXPORT_SYMBOL_GPL(` (20,476 lines).

Mean wall time in seconds (warm cache):

| Query | Matching lines | ffs | ffs `--io=serial` | rg -uu | ack | grep -rI |
|:---|---:|---:|---:|---:|---:|---:|
| rare: `PM_RESUME` | 38 | 2.06 | **1.70** | 2.09 | 4.27 | 11.78 |
| common: `ERR_PTR` | 17,569 | 2.09 | **1.73** | 2.14 | 6.43 | 13.99 |
| no match: `zqxjvkwqz` | 0 | 2.10 | **1.75** | 2.09 | 11.78 | 11.98 |
| long: `#include <linux/module.h>` | 14,540 | 2.23 | **1.88** | 2.03 | 14.19 | 14.74 |

CPU time and memory, for the rare query (the other queries are similar):

| Command | CPU [s] (user + sys) | Peak memory |
|:---|---:|---:|
| ffs | 15.0 (0.27 + 14.8) | 430 MiB |
| ffs `--io=serial` | 1.6 (0.12 + 1.49) | 376 MiB |
| rg -uu | 16.2 (0.26 + 15.9) | 11 MiB |
| ack | 3.8 (1.18 + 2.63) | 23 MiB |
| grep -rI | 6.9 (4.89 + 2.00) | 2.7 MiB |

Observations:

- **Serial ffs is the fastest tool on Linux**, about 17% faster than both
  parallel ffs and ripgrep. Parallel ffs and ripgrep are tied at about 2.1 s.
- **Parallelism backfires at this scale on macOS.** With threads, system time
  goes up about 10× (1.5 s → 14.8 s) and wall time gets *worse*. The threads
  contend inside the kernel (file system / VFS locks) when opening and
  reading about 92k files. ripgrep shows the same pattern. On Redis (about
  1.7k files) parallel still won, by 1.3×.
- **The query shape barely matters.** Every query takes about the same time
  for ffs and ripgrep, because the search itself takes about 0.1–0.3 s of
  user time. The cost is file-system syscalls. ack and grep, which search
  more slowly, vary more.
- **ffs memory is too high.** ffs reads each file fully before its binary
  check, so the 285 MB `.git` pack file is loaded into memory just to be
  skipped (376–430 MiB peak, vs 11 MiB for ripgrep). It should read a small
  first chunk, check that for NUL bytes, and stream the rest.
- grep and ack have high run-to-run variance on some queries (up to ±3 s).
  Their numbers are less precise than ffs and ripgrep's.

## Experiment 7 — thread cap, streaming reads, parallel directory walk

Three changes to ffs:

1. **`-j N`** sets the number of worker threads (`Io.Threaded` with
   `async_limit = N`). It replaces `--io=serial`; `-j 1` is the serial mode.
   The main thread only starts the root task and then waits in
   `group.await`. An earlier version used `N - 1` for the limit, which made
   `-j 2` no faster than `-j 1`.
2. **Streaming reads.** Each file is read through a 256 KiB buffer with
   `File.readStreaming`. Only complete lines are searched; the partial last
   line is carried to the front of the buffer, and the starting line number
   is passed to `searchBuffer`. If a NUL byte shows up, the file is dropped
   along with any matches found so far, which haven't been written yet.
   The buffer doubles only when a single line is longer than it.
3. **Parallel directory walk.** `std.Io.Dir.walk` is replaced by one task per
   directory. A directory task iterates its entries and starts a new task
   for each subdirectory, then searches its own files using one read
   buffer, path buffer and output buffer per directory task. When all
   threads are busy, `Group.async` runs the subdirectory inline
   (depth-first).

Correctness:

- ffs prints the same `path:line` set as `rg -uu -nF` for 4 Redis queries
  (default, `-j1`, `-j4`) and 5 Linux queries (default, `-j1`). One of the
  Linux queries is `mmSPI`, which hits 15–24 MB AMD GPU headers that span
  many buffer refills.
- Hand-made edge cases, all correct:
  - a 700 KB line with matches at both ends
  - a match that straddles the 256 KiB boundary
  - a file without a final newline
  - an empty file
  - nested directories
- Debug build: no leaks. ThreadSanitizer: no races, on both fixtures.
- Known difference: ripgrep prints matches found *before* a late NUL byte,
  with a warning. ffs skips the whole file.

### Thread count

`bench/threads.sh` reproduces this sweep and the ripgrep fairness check
below. Results are saved as `results/threads-{redis,linux}.json` and
`results/{linux,redis}-rg-threads.json`. Each setting gets at least 10
runs.

| `-j` | Redis wall [ms] | Linux wall [s] | Linux sys [s] | Linux memory |
|---:|---:|---:|---:|---:|
| 1 | 23.0 | 1.93 (median) | 1.60 | 4.8 MiB |
| 2 | 18.1 | 1.26 | 1.92 | 5.7 MiB |
| 3 | 16.5 | 0.94 | 2.26 | 6.4 MiB |
| **4** | **15.4** | **0.87** | 2.94 | 7.3 MiB |
| 5 | 16.2 | 1.10 | 4.58 | 8.3 MiB |
| 6 | 16.4 | 1.57 | 6.10 | 9.2 MiB |
| 8 | 19.0 | 1.75 | 10.61 | 10.8 MiB |
| 10 | 19.2 | 1.99 | 14.02 | 12.1 MiB |

Four threads is the best setting on both fixtures, and it is now the
default. Beyond 4, system time climbs steeply (kernel contention on file
system locks) and wall time gets worse. The M5 is likely to have 4
performance cores, which may explain the sweet spot (not verified); a
different Mac may want a different default. Single-threaded runs on Linux
were very noisy (wall time well above CPU time). This may be because a
single thread gets scheduled onto efficiency cores; that is not verified.

### Results

All text files, nothing ignored. Mean wall time; on Linux, n = 5 per query.

| Fixture / query | ffs | ffs -j1 | rg -uu | ack | grep -rI |
|:---|---:|---:|---:|---:|---:|
| Redis `dictFind` | **16.4 ms** | 23.1 ms | 19.8 ms | 91.0 ms | 101.8 ms |
| Linux rare `PM_RESUME` | **0.91 s** | 2.64 s | 1.83 s | 9.39 s | 14.45 s |
| Linux common `ERR_PTR` | **0.84 s** | 2.04 s | 1.90 s | 5.20 s | 14.39 s |
| Linux no match | **0.89 s** | 1.76 s | 1.85 s | 7.73 s | 12.21 s |
| Linux long `#include <linux/module.h>` | **0.94 s** | 2.13 s | 1.82 s | 14.43 s | 14.84 s |

Peak memory on Linux dropped from 376–430 MiB to **7.0–7.5 MiB** (ripgrep:
11.6 MiB).

**Fairness check — ripgrep with the same thread cap.** By default ripgrep
uses about one thread per CPU, which Experiment 6 showed is harmful on
macOS. With `-j4` it ties ffs:

| Command | Linux `PM_RESUME` median | Redis `dictFind` median |
|:---|---:|---:|
| ffs (4 threads) | 0.849 s | 15.6 ms |
| `rg -uu -j4` | 0.838 s | 15.5 ms |
| `rg -uu -j2` | 1.097 s | — |
| `rg -uu` (default) | 1.933 s | 19.6 ms |

Observations:

- **The "2× faster than ripgrep" result is a thread-count effect, not a
  better search.** At equal thread counts, ffs and ripgrep are tied. ffs's
  edge is only a better default for this machine.
- Streaming reads fixed memory use (about 50× less) without hurting speed.
- The parallel directory walk made `-j1` → `-j4` a real 2× speedup on Linux.
  In Experiment 6, threads made Linux *slower*.
- For both tools, about 95% of CPU time is still system time. The remaining
  cost is file-system syscalls, not searching.
- The machine had background load (load average 2–15, mostly Chrome and
  WindowServer). ack and `-j1` runs show high variance; ffs and ripgrep at 4
  threads are stable to within about 5%.

## Experiment 8 — matcher micro-optimizations

Search is about 5% of ffs's total time, so end-to-end wall time can't show
matcher changes. A microbenchmark isolates them.

**Matcher microbenchmark.** Run it with `bench/match.sh [runs]`, which calls
`zig build bench-match -- <corpus> [runs]` (`src/bench_match.zig`). The
corpus is the first 512 MB of the Linux kernel's `.c`/`.h` files,
concatenated into `fixtures/linux-src.txt` on the first run. It is loaded
into memory, and each term is timed doing what `search.zig` does per read:
find the matching lines and work out the line number after the data.
Results are the best of 7 runs. The last line number (9,437,620) is printed
as a check that line counting stays exact.

Each idea from ARCHITECTURE.md's list was measured on its own. Times are in
ms; lower is better.

| Version | `PM_RESUME` | `ERR_PTR` | no match | long | `the` | `e` | total |
|:---|---:|---:|---:|---:|---:|---:|---:|
| Before: scan, then a separate `countScalar` pass | 22.17 | 22.50 | 20.52 | 20.76 | 25.44 | 107.23 | 218.62 |
| Newlines counted in the scan, bitmask + popcount per block | 22.07 | 22.26 | 20.32 | 20.57 | 25.08 | 98.02 | 208.32 |
| **Newlines counted in the scan, per-lane vector counters** | **18.36** | **18.38** | **15.86** | **16.18** | **20.82** | **98.81** | **188.41** |
| … with 32-byte blocks (unroll ×2) | 20.15 | 20.34 | 18.20 | 18.48 | 22.82 | 94.45 | 194.45 |
| … with 64-byte blocks (unroll ×4) | 19.74 | 20.07 | 18.26 | 18.45 | 23.08 | 102.02 | 201.63 |
| … filtering on the 2 rarest bytes instead of first/last (A/B, round 1) | 17.43 | 19.37 | 16.82 | 17.63 | 22.77 | 102.18 | 196.21 |
| … first/last, same A/B round | 18.39 | 18.34 | 16.17 | 16.59 | 21.06 | 99.87 | 190.41 |

The version in bold is kept: **about 14% faster overall, and 20% faster on
identifier searches** (about 28 GB/s instead of 23 GB/s).

- **Newline counting in the scan loop.** `findLines` now also returns the
  line number after the data, so `search.zig` no longer runs a separate
  `countScalar` pass. The first attempt built a newline bitmask per block,
  and it barely helped. NEON has no movemask instruction, and the emitted
  assembly showed about 7 extra instructions per block to build one. The
  kept version adds the newline compare into 16 per-lane `u8` counters (one
  `sub.16b` per block). They are summed only when a match needs its line
  number, or every 255 blocks before a lane could overflow.
- **Unrolling (32/64-byte blocks)** was 2–5% slower, so 16-byte blocks are
  kept.
- **Rarest-byte filter.** The two rarest bytes of the term were picked with
  a byte-frequency table generated from Redis, which is deliberately not
  the benchmark corpus. This was consistently about 3% slower over two A/B
  rounds; only `PM_RESUME` gained. On this C corpus, first and last byte
  already produce almost no false candidates, and the extra load costs more
  than the filter saves. Removed.
- **Not tried, by design:** folding the NUL check into the scan (the scan
  skips the rest of each matching line, so a NUL there would be missed) and
  a SIMD tail (at most 15 positions per call, and it complicates the
  newline counting).

**Correctness.** The randomized test now also checks the returned line
number. A second test covers inputs longer than 255 blocks, with newline
density up to every byte. Removing the periodic flush makes that test fail
with an integer overflow, which was verified. ffs still matches `rg -uu -nF`
on 10 queries across both fixtures, and the edge-case files are unchanged.

**End to end** (`results/{linux,redis}-matcher.json`):

| Command | Wall (median) | User CPU | System CPU | User CPU before (Exp. 7) |
|:---|---:|---:|---:|---:|
| ffs, Linux `PM_RESUME` | 0.854 s | 132 ms | 2.82 s | 152 ms |
| ffs `-j1`, Linux `PM_RESUME` | 1.575 s | 126 ms | 1.48 s | 146 ms |
| `rg -uu -j4`, Linux `PM_RESUME` | 0.824 s | 188 ms | 3.02 s | — |
| ffs, Redis `dictFind` | 15.0 ms | 2.7 ms | 30.9 ms | 2.9 ms |
| `rg -uu -j4`, Redis `dictFind` | 14.8 ms | 4.1 ms | 38.3 ms | — |

User CPU dropped about 13%, and ffs now uses about 30% less user CPU than
ripgrep. Wall time is unchanged, as expected: system time (opening and
reading files) is still about 95% of the work.

## Experiment 9 — `--content` (print the matching line)

`ffs --content <folder> <term>` prints `<path>:<line>:<content>`.

**How it works.** The matcher now passes the sink a `match.Match` instead of
just a line number. `Match` holds the line number, the searched slice, the
match position and the line end; `report` already finds the line end to
skip to the next line. `Match.text()` finds the line start on demand, by
scanning back from the match to the previous newline. Reads are cut at
newlines, so that is always within the current slice. The default
`path:line` output never calls it, so it pays nothing. See ARCHITECTURE.md,
"Reporting a match".

**Correctness.**

- The randomized tests check every `m.text()` against an independent
  oracle (the n-th line from splitting the data on `\n`). They caught a
  regression during development: the returned line number was off by one
  when the last line matched with no trailing newline.
- Compared byte for byte (sorted) with `rg -uu -nF --no-heading`:
  - identical for 8 queries across both fixtures (up to 17,569 lines),
    including a CRLF file, whose lines keep their `\r` in both tools;
  - **two known differences:**
    - *UTF-8 BOM.* ripgrep strips a byte-order mark from line 1 when
      printing it; ffs prints raw bytes, as grep does. This affects 9 Redis
      files when searching `e`. *(Since Experiment 13, ffs strips it too.)*
    - *Late NUL byte.* ripgrep prints matches found before the NUL, with a
      warning; ffs skips the file (as before).

**Cost** (`results/{linux,redis}-content.json`, medians):

| Query | Lines | ffs | ffs `--content` | `rg -uu -j4` |
|:---|---:|---:|---:|---:|
| Linux `ERR_PTR` | 17,569 | 842.9 ms | 836.8 ms | 846.1 ms |
| Redis `the` | 37,475 | 16.2 ms | 16.4 ms | 23.7 ms |

`--content` costs no measurable wall time. On Redis `the`, user CPU went
from 4.4 to 5.2 ms. Note that ripgrep always prints content, and on this
many-match Redis query it is about 45% slower than ffs.

**Matcher microbenchmark (no regression).** The microbenchmark measured
about 202 ms total in this session, against 188 ms in Experiment 8. An
alternating A/B of the previous and new `match.zig` gave identical times
(202.03/202.31 ms against 202.01/201.98 ms). So the difference is a change
in machine state (load average about 4.7), not the code. Absolute
microbenchmark numbers drift between sessions; only compare A/B runs made
in the same session.

## Experiment 10 — `-i` (ASCII case-insensitive search)

`ffs -i <folder> <term>` (or `--ignore-case`) matches `A`–`Z` and `a`–`z`
regardless of case. It combines with `--content` and `-j`.

**How it works.** The SIMD loop is the same; only the two end-byte compares
change (see ARCHITECTURE.md, "Ignoring case"):

- If the term's first or last byte is a letter, each loaded block is ORed
  with `0x20` before comparing it with the lower-case byte. Setting bit 5
  maps `A`–`Z` onto `a`–`z`, and nothing else lands on `a`–`z`, so the
  compare is exact. A non-letter end byte is compared as before.
- Candidates are verified with `std.ascii.eqlIgnoreCase`.
- The search loop is specialized at compile time (`comptime case`), so
  the case-sensitive loop is unchanged: same instructions, same timings.

A first version compared each block against both the lower- and upper-case
byte (two compares and an OR per load). The OR-`0x20` version replaced it
after an alternating A/B: 238.7/239.5 ms against 221.8/221.7 ms for the six
microbenchmark terms (7% faster).

**Correctness.**

- Both randomized tests now mix `A`/`B` with `a`/`b` and run every case
  both ways, against `findLinesNaive` (which takes the same `case`
  parameter). A unit test checks that `[`/`{` are not folded, that a
  UTF-8 `Ö` is left alone, and that matches after the first SIMD blocks are
  found. Mutation check: disabling the fold in the SIMD loop makes the
  randomized test fail.
- Compared byte for byte (sorted) with `rg -uu -i -nF --no-heading`:
  identical for 8 queries across both fixtures (`dictfind`, `THE`, `Hello`,
  `_EXPORT`, `pm_resume`, `err_ptr`, a no-match and `#INCLUDE
  <LINUX/MODULE.H>`). For `e` (Redis), `ss` and `k` (Linux, up to 7.5
  million lines), the only difference is the known UTF-8 BOM one from
  Experiment 9; outputs are identical once it is stripped (and identical
  outright since Experiment 13).
- **Known difference:** ripgrep folds Unicode case (`é`/`É`, `ß`/`ẞ`, the
  Kelvin sign U+212A for `k`). ffs folds ASCII only. None of the queries above
  were affected on these fixtures.

**Matcher microbenchmark** (`bench/match.sh`, 512 MB of Linux C source,
best of 7; it now runs every term both ways):

| Term | case-sensitive | `-i` | lines (`-i`) |
|:---|---:|---:|---:|
| `PM_RESUME` | 18.6 ms | 22.1 ms | 172 |
| `ERR_PTR` | 18.6 ms | 26.1 ms | 2,549 |
| `zqxjvkwqz` | 16.1 ms | 16.8 ms | 0 |
| `#include <linux/module.h>` | 16.4 ms | 17.3 ms | 2,702 |
| `the` | 21.0 ms | 24.5 ms | 216,855 |
| `e` | 102.9 ms | 111.3 ms | 6,977,949 |
| **total** | **193.5 ms** | **218.1 ms** | |

`-i` is about 13% slower in the matcher. Most of that is not the OR: it
is extra candidates. `PM_RESUME` matches 172 lines instead of 3, and
`p…e` pairs are much more common than `P…E` pairs, so many more
candidates reach `eqlIgnoreCase`.

**End to end** (`results/ignore-case-*.json`, hyperfine, at least 20 runs
on Linux and 189 on Redis, medians):

| Query | ffs | ffs `-i` | `rg -uu -j4` | `rg -uu -i -j4` |
|:---|---:|---:|---:|---:|
| Linux `ERR_PTR` wall | 875 ms | 858 ms | 848 ms | 834 ms |
| Linux `ERR_PTR` user CPU | 136 ms | 191 ms | 199 ms | 297 ms |
| Linux `PM_RESUME` wall | 836 ms | 857 ms | 814 ms | 831 ms |
| Linux `PM_RESUME` user CPU | 132 ms | 167 ms | 183 ms | 278 ms |
| Redis `the` wall | 15.8 ms | 15.8 ms | 23.5 ms | 23.7 ms |
| Redis `the` user CPU | 4.2 ms | 4.6 ms | 10.4 ms | 11.5 ms |

- `-i` costs no measurable wall time. Linux runs are dominated by about
  2.8–3.1 s of system time (file opens and reads), and their spread
  (±60–200 ms) is larger than every difference in the table.
- User CPU shows the real cost: `-i` adds 35–55 ms on Linux for ffs, and
  about 100 ms for ripgrep.
- hyperfine 2 also records instruction counts, which are not affected by
  machine noise. On Linux `ERR_PTR`, `-i` adds 0.7 G instructions for ffs
  (31.1 → 31.8 G) and 1.9 G for ripgrep (32.6 → 34.5 G).
- This session's Linux timings are noisier than in Experiment 9 (load from
  other processes); compare only rows from the same table.

## Experiment 11 — `-E` (regex search)

`ffs -E <folder> <pattern>` (or `--regex`) searches for a regular
expression. It combines with `-i`, `--content` and `-j`. Syntax: `.`,
`[...]`/`[^...]` with ranges, `\d \w \s` (and `\D \W \S`), `\t`, `\b`, `^`,
`$`, `* + ?`, `{n}`, `{n,}`, `{n,m}`, `|` and `( )`. It is byte-oriented,
with ASCII classes.

**Design** (`src/regex.zig`, about 420 lines without tests; see
ARCHITECTURE.md, "Regex"):

- A recursive-descent parser builds a tree. A compiler turns it into a
  Thompson NFA program. A Pike VM answers "does this line contain a
  match?" in O(line × program) time, with no backtracking, so patterns
  like `(a*)*b` can't blow up.
- **SIMD prefilter.** The longest literal that every match must contain
  (`PM_` in `PM_[A-Z_]+`) is searched for with the existing
  `match.findLines`. Only lines containing it reach the VM, through a
  filtering sink. Line numbers, chunking and output are reused unchanged.
- **First-byte skip.** When a pattern has no required literal, the VM skips
  ahead to the next byte that can start a match while no thread is alive.
  This was added after the first benchmark run: `-i todo|fixme` went from
  4.08 to 1.92 s and `[0-9a-f]{16}` from 3.38 to 2.30 s.

**Correctness.**

- Unit tests cover syntax (59 cases), errors (13), literal extraction (13)
  and prefiltered vs every-line search.
- A randomized test runs 5,000 random patterns × 20 lines, with and without
  `-i`. It compares the VM against a backtracking matcher that walks the
  parse tree directly (an independent oracle), and asserts that every
  matching line contains the required literal.
- Four mutations were each caught: `$` always true, the `split` order, the
  literal extraction ignoring optional parts, and an inverted first-byte
  skip.
- Compared byte for byte (sorted) with `rg -uu -n --no-heading` in ASCII
  mode (`(?-u)` prefix): identical on 12 patterns, from
  `dict(Find|Delete)\(` up to `\bu(8|16|32)\b` (576,922 lines). For `^$`
  and `[^ -~]` (Redis), the only differences came from the BOM (since
  fixed, Experiment 13).
- **Known difference** from ripgrep's default Unicode mode: `\w`, `\b`,
  `\s` and `.` are ASCII/byte-based in ffs. On Linux, 1 of 10,118 lines
  differed for `\bERR_PTR...`: a CJK character before `ERR_PTR` is a word
  character to ripgrep.

**Results** (`bench/regex.sh`, `results/regex-*.json`, medians; at least 10
runs, grep 3):

| Pattern | Required literal | ffs `-E` | `rg -uu -j4` | `rg -uu` |
|:---|:---|---:|---:|---:|
| Linux `PM_[A-Z_]+` | `PM_` | **868 ms** | 908 ms | 2,022 ms |
| Linux `\bERR_PTR\(-E[A-Z]+\)` | `ERR_PTR(-E` | **875 ms** | 900 ms | 1,986 ms |
| Linux `\w+_lock_irqsave\(` | `_lock_irqsave(` | **930 ms** | 955 ms | 2,067 ms |
| Linux `(spin\|mutex)_lock\(` | `_lock(` | 905 ms | 895 ms | 1,940 ms |
| Linux `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` (478k lines) | `define` | 1,167 ms | **947 ms** | 1,988 ms |
| Linux `[0-9a-f]{16}` | none | 2,304 ms | **1,330 ms** | 1,666 ms |
| Linux `-i todo\|fixme` | none | 1,921 ms | **902 ms** | 1,701 ms |
| Redis `dict(Find\|Delete)\(` | `dict` | 18.5 ms | 18.7 ms | 19.3 ms |
| Redis `[0-9]{3,}` | none | 24.6 ms | **21.4 ms** | 24.4 ms |

grep (`grep -rIEn`), 3 runs: `PM_[A-Z_]+` took 14.3 s (ffs: 1.3 s in that
noisy run), and `[0-9a-f]{16}` took 28.3 s (ffs: 3.0 s).

Observations:

- **With a required literal, regex costs nothing extra:** ffs ties
  `rg -j4` and is 2.2× faster than ripgrep's default. User CPU is about
  150 ms, the same as a literal search.
- **When many lines pass the prefilter, the VM shows.** `define` matches
  478k lines and every candidate runs the VM: ffs uses 1.2 s of user CPU
  against ripgrep's 0.48 s.
- **Without a literal, ffs is 1.7–2.1× slower than `rg -j4`.** ripgrep
  compiles to a lazy DFA and uses smarter prefilters (for example
  multi-literal search for `todo|fixme`). Closing this gap would mean a
  DFA, which would at least double `regex.zig`. ffs is still 9× faster
  than grep here.
- Memory stays at 7.5–8.6 MiB (ripgrep: 10–20 MiB).

## Experiment 12 — `-j auto`: thread count from the CPU topology

Experiment 7 found that 4 threads is best on this M5, and that more threads
mostly add kernel contention on macOS. 4 is also this chip's
performance-core count. Hypothesis: the best thread count is the number of
performance cores. The default is now `-j auto`:

- on Apple silicon, `sysctl hw.perflevel0.logicalcpu` (the top performance
  level; 4 "Super" cores on this M5, plus 6 efficiency cores);
- elsewhere, including Intel Macs (no `perflevel` sysctls), min(4, CPU
  count) as before.

It is about ten lines (`search.autoJobs`). The C API uses it when `threads`
is 0. `bench/threads.sh` now records the topology
(`results/threads-topology.txt`) and includes `auto` in the sweep.

**Results** (`bench/threads.sh`, medians):

| `-j` | auto (= 4) | 1 | 2 | 3 | 4 | 5 | 6 | 8 | 10 |
|:---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Linux `PM_RESUME` | **891 ms** | 1,625 | 1,332 | 991 | 955 | 1,328 | 1,336 | 2,017 | 2,130 |
| Redis `dictFind` | **15.3 ms** | 21.6 | 17.8 | 16.1 | 15.3 | 16.3 | 16.5 | 16.7 | 17.1 |

- On this machine `auto` picks 4, which is again the fastest setting. The
  891 against 955 ms between `auto` and `-j4` is noise, since they run the
  same thread count. The jump from 4 to 5 threads (+39% on Linux) is where
  efficiency cores start being used.
- **Not yet checked on another Mac**: only one machine was available. To
  check, run `bench/threads.sh` there and see whether `auto` lands on the
  best `-j`. A clearly better `-j` other than the performance-core count
  would disprove the hypothesis.
- ripgrep with the same thread count still ties: Linux 918 ms for ffs
  against 874 ms for `rg -j4`, and Redis 15.0 against 15.1 ms.
- A test build ran for a few seconds during this sweep, which may have
  disturbed some Linux runs.

## Experiment 13 — fewer syscalls per file, and mmap

On Linux, about 95% of ffs's CPU time is system time, and 92,000 files each
cost `open`, `read`, a second `read` that returns 0 (end of file), and
`close`. Two ideas:

- **A. A short read means end of file.** For a regular file, a read that
  returns fewer bytes than requested is at end of file. This saves the
  second `read` for every file under 256 KiB, which is nearly all of them.
  `fstat` + one `read` would not save anything: `fstat` is a syscall too.
- **B. mmap large files.** If the first read fills the buffer, `fstat`
  the file; if it is at least 1 MiB, map it and search it as one slice,
  with no copies and no carried lines. On Linux, 329 text files are over
  256 KiB, holding 531 MB (29% of all bytes; the four `.git` packs over
  256 KiB are binary and dropped at the first read).

Same build otherwise; the baseline is the code from Experiment 11 plus the
refactor for the C API.

**Correctness.** base, A and A+B gave byte-identical output (sorted) for 10
queries, including a new set of edge cases:
- files of exactly 256 KiB, with and without a final newline;
- 2.9 MB files with a match on the last line without a newline, and with a
  BOM;
- a 600 KB single line;
- a 2 MB file with a NUL byte at the end (dropped by all).

All matched ripgrep, except the late-NUL files.

**Results** (Linux `PM_RESUME`, medians):

| Run | base | A | A + B |
|:---|---:|---:|---:|
| hyperfine, 20 runs each, one after another | 844 ms | 917 ms | 901 ms |
| 12 alternating rounds, wall | 911 ms | 910 ms | 904 ms |
| 12 alternating rounds, system time | 3.07 s | 3.05 s | 2.98 s |
| Redis `dictFind`, 100 runs | 15.0 ms | 15.1 ms | 14.6 ms |

- **Neither change is measurable.** All differences are within run-to-run
  noise. When the commands run one after another, the order matters more
  than the code.
- The extra `read` that returns 0 costs about a microsecond. The expensive
  part of each file is `open` (path lookup, vnode) and `close`, which ffs
  needs no matter what.
- **Kept A**: it is free, it saves 92,000 syscalls, and the read loop got
  simpler (one "cut" computation replaced the special no-newline branch).
- **Dropped B**: 15 more lines and a new failure mode (a file truncated
  while mapped raises SIGBUS), for no gain.

Also in this change: ffs now strips a UTF-8 byte-order mark from line 1,
like ripgrep. The `e` and `^$` queries on Redis now match ripgrep exactly.

## Experiment 14 — binary size, C library, other platforms

**Binary size** (Apple M5, arm64; `results/size-variants-*.json`):

| Binary | Size | Linked libraries |
|:---|---:|:---|
| ffs, ReleaseFast, stripped (`zig build` default now) | **256 KB** | libSystem |
| ffs, ReleaseFast, not stripped (before) | 450 KB | libSystem |
| ffs, ReleaseSmall, stripped | 203 KB | libSystem |
| ripgrep 15.2.0 (Homebrew) | 6.5 MB | libSystem, libpcre2-8 |
| grep (BSD, `/usr/bin`, 3-architecture universal binary) | 252 KB | libSystem, libz, libbz2, liblzma |
| ack 3.10 | 169 KB script | Perl 5.34 |

- Stripping changes no code. On Linux `PM_RESUME`, the stripped build ran
  at 920 ms and the unstripped one at 1,080 ms in the same session; that is
  noise. The release build is now stripped.
- **ReleaseSmall is not worth it.** On a literal search it used 3× the user
  CPU (394 against 129 ms); the wall time was hidden by the kernel. On
  `[0-9a-f]{16}`, where the VM dominates, it was 26% slower (3.60 s against
  2.86 s).
- ffs is 25× smaller than ripgrep. That is fair to say only with
  ripgrep's feature set in mind: ignore files, a full Unicode regex
  engine, encodings, PCRE2, compressed files and much more.

**C library.** `zig build` also installs `zig-out/lib/libffs.a` (static,
compiler-rt bundled, 3.5 MB unstripped archive) and
`zig-out/include/ffs.h`:

```c
int ffs_search(const char *root, const char *term, unsigned flags,
               unsigned threads, ffs_callback cb, void *ctx);
```

- `flags` takes `FFS_IGNORE_CASE` and `FFS_REGEX`; `threads = 0` means
  automatic.
- The callback gets an `ffs_match` with a NUL-terminated path
  (`<root>/<rel>`), line number and text. It is never called concurrently;
  a file's lines arrive in order and files never interleave. A nonzero
  return stops the search (`FFS_STOPPED`).
- Errors: `FFS_EARG`, `FFS_EREGEX`, `FFS_EROOT`, `FFS_ENOMEM`.
- It is a thin layer (`src/c_api.zig`, about 80 lines) over the same
  `search.run` the CLI uses. The output side became a small union: print to
  a file, or call back.
- Tested by a Zig test that calls `ffs_search` exactly as C would (literal,
  `-i`, regex, early stop, every error code), and by `examples/count.c`
  (`zig build c-example -- fixtures/redis dictFind`). The example's counts
  match the CLI (119 lines for `dictFind`, and 175 for
  `-i -E 'DICT(FIND|DELETE)\('`).

**Other platforms.** `zig build -Dtarget=...` succeeds for `aarch64-linux-gnu`,
`x86_64-linux-musl`, `x86_64-windows` and `x86_64-macos` (CLI, library and
all). None of these were *run*: there is no Linux VM or Rosetta on this
machine. On Linux, `std.Io.Threaded` and the code paths are the same; `-j
auto` falls back to min(4, CPU count).

## Experiment 15 — Linux: ffs vs ripgrep at matched thread counts

The first run of the suite on an actual Linux machine, which Experiment 14
left as the obvious gap. Environment:

| | |
|---|---|
| Machine | AMD Ryzen 9 PRO 6950H, 8 cores / 16 threads, 16 MiB L3, 1 NUMA node |
| OS | Omarchy (Arch), Linux 7.2.5-3-omarchy, x86_64, ext4 on LUKS |
| ripgrep | 15.2.0 (`/usr/bin/rg`, `+pcre2`, runtime SIMD `+AVX2`) |
| grep | GNU grep (`/usr/bin/grep`) |
| ack | not packaged for Arch; its rows are missing from the Linux tables |
| hyperfine | 1.20.0 (`pacman -S hyperfine`) |

The scripts had Homebrew paths baked in, so they now resolve tools through
`bench/tools.sh` (`RG`, `ACK`, `GREP`, `HYPERFINE`, `FFS`, `OUT` override
anything), skip `ack` when it is missing, and read the topology with `lscpu`
off macOS. The Linux numbers go to `results-linux/`, so the macOS baseline in
`results/` stays untouched: the two machines are not comparable, and mixing
them would quietly replace the numbers the other experiments rest on. All
runs below are warm-cache, `hyperfine -N`.

### What the suite said first, and why it was misleading

On the kernel fixture ffs looked 2.2–2.6x *slower* than `rg -uu` (233 ms
against 90 ms), the opposite of the macOS result. Two causes, and only the
second one is interesting:

1. `-j auto` was `min(4, CPU count)` off macOS — an Apple-silicon number
   (Experiment 12) — so ffs ran on 4 threads while ripgrep used all 16.
2. Even at 16 threads ffs stopped at 135 ms, because of how the walk
   distributed work.

`bench/h2h.sh` separates the two by sweeping both tools over the same thread
counts on the same query (`PM_RESUME`, 2.0 GB, ~92,000 files):

| `-j` | ffs, one task per directory | ripgrep | ffs scaling | rg scaling |
|---:|---:|---:|---:|---:|
| 1 | 678.5 ms | 865.8 ms | 1.00x | 1.00x |
| 2 | 392.3 | 371.0 | 1.73x | 2.33x |
| 4 | 229.4 | 194.7 | 2.96x | 4.45x |
| 8 | 142.3 | 103.7 | 4.77x | 8.35x |
| 12 | 135.7 | 88.8 | 5.00x | 9.75x |
| 16 | 134.6 | 82.4 | 5.04x | 10.51x |

**ffs is 1.28x faster than ripgrep single-threaded and 1.63x slower at 16
threads.** The matcher was never the problem: it is the scaling, 5.0x against
10.5x, flat past `-j 8`.

### Why it stopped scaling

One task per directory, and `visitFile` ran inside that task
(`search.zig:117`), so the files of one directory were never searched
concurrently. The kernel tree is extremely uneven — `drivers/net/ethernet`
and `include/linux` against hundreds of three-file directories — so the run
ended on a long serial tail: one thread working through a big directory while
the others had nothing left to take.

`std.Io.Threaded` cannot rebalance that by itself. `groupAsync`
(`Threaded.zig:2194`) runs a task **inline** when `busy_count` has reached
`async_limit`; it never queues work for a thread that frees up later. So
whoever found a directory full of files was committed to searching them.

### What did not work: smaller tasks in the same group

First attempt: keep the design and hand each 16 files to their own
`Group.async` task. It was *slower everywhere*, and worse the more threads it
had:

| `-j` | one task per directory | 16-file tasks |
|---:|---:|---:|
| 1 | 678.5 ms | 770.7 ms (+14%) |
| 8 | 142.3 | 183.7 (+29%) |
| 16 | 134.6 | 200.4 (+49%) |

A flat 14% at `-j 1`, where there is no scheduling at all, is the giveaway:
this was pure overhead (a name copy per file, an extra `openDir` and a fresh
`Local` — a 256 KiB read buffer — per batch), and the inline rule above meant
the extra tasks rarely ran anywhere else. Smaller tasks do not help when the
scheduler has nowhere to put them.

### What worked: a worker pool over one queue

`src/walk.zig` is now `jobs` worker tasks sharing one LIFO queue of items,
each item a directory to read or a batch of up to 32 file names to visit.
Every worker does both kinds of work, so a free worker takes the next item
instead of waiting for the thread that owns the big directory. Two details
matter as much as the queue:

- **Hand off only when a worker is idle.** Moving files to another worker
  costs a copy of their names, so a worker checks the `idle` count first and
  otherwise visits the file itself, allocating nothing. With `-j 1` nothing is
  ever handed off.
- **One `Local` per worker**, not per directory: the 256 KiB buffer and the
  regex VM are allocated `jobs` times per run instead of ~5,000 times. This is
  what the `-j 1` column below is measuring.

| `-j` | before | after | ripgrep | after scaling | after / rg |
|---:|---:|---:|---:|---:|---:|
| 1 | 678.5 ms | **580.0 ms** | 898.5 ms | 1.00x | 0.65x |
| 2 | 392.3 | **298.6** | 372.2 | 1.94x | 0.80x |
| 4 | 229.4 | **153.9** | 190.8 | 3.77x | 0.81x |
| 8 | 142.3 | **87.9** | 106.2 | 6.60x | 0.83x |
| 12 | 135.7 | **79.7** | 89.6 | 7.28x | 0.89x |
| 16 | 134.6 | **76.0** | 80.4 | 7.63x | 0.95x |

Scaling went 5.0x → 7.6x, and ffs is now faster than ripgrep at every thread
count on this machine, including 1.69x faster than its own previous best.

### `-j auto`: what the sweep says now

`search.autoJobs` returns every logical CPU off macOS (Apple silicon still
uses `hw.perflevel0.logicalcpu`). `bench/threads.sh`, full curve with `auto`
in it:

| `-j` | auto (= 16) | 1 | 2 | 3 | 4 | 5 | 6 | 8 | 10 | 12 | 16 |
|:---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Linux `PM_RESUME` | **73.6 ms** | 570.8 | 296.0 | 200.2 | 153.0 | 125.8 | 107.6 | 86.6 | 81.1 | 77.1 | 75.1 |
| Redis `dictFind` | 5.4 ms | 10.5 | 6.2 | 4.9 | 4.5 | 4.1 | **4.0** | 4.0 | 4.4 | 4.7 | 5.3 |

- On the large fixture `auto` lands on the best setting (73.6 against 75.1 ms
  at `-j 16` is noise, same thread count). The curve still improves from 10 to
  16 threads, so nothing is lost by taking the CPU count.
- On the small fixture `auto` is **1.34x off** the optimum: 5.4 ms against
  4.0 ms at `-j 6`–`-j 8`, where 16 workers over 1,680 files is just
  oversubscription. In absolute terms that is 1.4 ms, against 60 ms saved on
  the kernel tree, which is the trade the default makes. A work-aware default
  (start narrow, widen when the queue stays full) would get both; not tried.
- Fairness check, ripgrep held to the same caps (`bench/threads.sh`): ffs
  76.1 ms, `rg -uu` 89.1, `rg -uu -j4` 189.3, `rg -uu -j2` 365.9. On redis,
  ffs 5.4 against `rg -uu -j4` 6.8.

### Literal search, full width

`bench/searches.sh`, all text files, nothing ignored, kernel tree:

| Query | ffs | ffs `-j1` | `rg -uu` | `grep -rI` |
|:---|---:|---:|---:|---:|
| Rare `PM_RESUME` | **85.3 ms** | 588.8 | 90.4 | 1,111.9 |
| Common `ERR_PTR` | **76.2** | 584.4 | 94.5 | 1,046.0 |
| No match `zqxjvkwqz` | **79.9** | 587.4 | 90.4 | 885.9 |
| Long `#include <linux/module.h>` | **76.7** | 584.1 | 100.8 | 845.2 |

`bench/h2h.sh` repeats them with a `-j4` column, which is what the old
default was costing:

| Query | ffs | ffs `-j4` | `rg -uu` | `rg -uu -j4` |
|:---|---:|---:|---:|---:|
| Rare `PM_RESUME` | **74.0 ms** | 154.7 | 93.9 | 191.6 |
| Common `ERR_PTR` | **84.4** | 159.0 | 101.8 | 199.0 |
| No match `zqxjvkwqz` | **76.5** | 153.7 | 89.7 | 188.6 |
| Long `#include <linux/module.h>` | **76.5** | 170.8 | 104.3 | 218.8 |

Redis (25 MB, 1,680 files), each tool as normally run and then at equal work
(`bench/bench.sh`):

| | ffs | ffs `-j1` | rg | grep |
|:---|---:|---:|---:|---:|
| Defaults (rg skips `.git`, ffs and grep do not) | **5.3 ms** | — | 8.3 | 19.7 |
| All text files, nothing ignored | **5.4** | 10.8 | 6.4 (`-uu`) | 19.0 (`-rI`) |

ffs is ahead of ripgrep on every literal query on both fixtures, by 1.06–1.37x
on the kernel tree and 1.19–1.56x on redis, and 11–13x ahead of GNU grep.

### Case-insensitive

`ffs -i` 71.8 ms against `rg -uu -i` 98.1 ms on `PM_RESUME` — and 71.8 ms is
*faster than the case-sensitive 74.0 ms*, which is not noise: the matcher
microbench below shows the same thing on every pattern.

### Regex: nine patterns

`bench/regex.sh`, kernel tree unless marked redis. `rg -uu -P` (PCRE2 with
JIT) comes from `bench/h2h.sh`:

| Pattern | `ffs -E` | `rg -uu` | `rg -uu -j4` | `rg -uu -P` |
|:---|---:|---:|---:|---:|
| `PM_[A-Z_]+` | **79.2 ms** | 96.4 | 205.6 | 324.7 |
| `\bERR_PTR\(-E[A-Z]+\)` | **80.3** | 92.8 | 196.4 | — |
| `\w+_lock_irqsave\(` | **76.3** | 96.4 | 200.2 | 366.6 |
| `(spin\|mutex)_lock\(` | **77.6** | 105.2 | 220.9 | — |
| `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | 490.2 | **153.2** | 325.1 | 351.2 |
| `[0-9a-f]{16}` | 1,326.9 | **281.5** | 721.5 | 498.6 |
| `-i todo\|fixme` | 1,035.3 | **101.4** | 215.2 | — |
| redis `dict(Find\|Delete)\(` | **5.7** | 6.6 | 7.3 | — |
| redis `[0-9]{3,}` | 11.5 | **7.5** | 10.2 | — |

With GNU grep for scale: `PM_[A-Z_]+` 81.6 ms for ffs against 1,426 ms
(17x), and `[0-9a-f]{16}` 1,443 against **30,029 ms** (21x).

- **A literal in the pattern keeps ffs ahead** (the first four rows, 1.16–1.36x
  faster than ripgrep): the SIMD prefilter finds the candidate lines and the
  Pike VM only sees those.
- **Without one, ffs is 1.5–10.2x behind**, worse than the 1.4x seen on macOS,
  because ripgrep's lazy DFA got much faster on this machine while ffs's VM
  did not. The worst case is `-i todo|fixme` at 10.2x: an alternation of two
  literals, where ffs has no prefilter at all and ripgrep picks both literals
  up. That is the single strongest argument for a multi-literal prefilter.
- It is the engine, not threads: PCRE2 is slower than ripgrep's own engine on
  all four patterns measured and still beats `ffs -E` on the class-heavy ones,
  and `ffs -E` scales with `-j` like everything else.

### The matcher alone

`bench/match.sh` on a 512 MB in-memory corpus (the kernel's `.c`/`.h` files
concatenated), best of 7 runs, single-threaded:

| Term | sensitive | insensitive |
|:---|---:|---:|
| `PM_RESUME` | 43.66 ms, 11.73 GB/s | 27.82 ms, **18.40 GB/s** |
| `ERR_PTR` | 43.99, 11.64 | 31.35, 16.33 |
| `zqxjvkwqz` | 40.80, 12.55 | 23.48, **21.80** |
| `#include <linux/module.h>` | 42.50, 12.05 | 24.07, 21.27 |
| `the` | 46.17, 11.09 | 29.97, 17.08 |
| `e` | 99.46, 5.15 | 104.13, 4.92 |

- 11–12.6 GB/s on realistic terms, and the one-byte term `e` (6.4 M matching
  lines) at 5.15 GB/s is reporting cost, not search cost.
- **The case-insensitive path is 1.4–1.7x faster than the case-sensitive one**
  on every term but `e`, on both runs of the suite. That is backwards — `-i`
  does strictly more work per candidate — and it is unexplained. Worth an
  experiment of its own: if the sensitive path is leaving 40% on the table,
  that is the largest single-thread win left.
- End to end, the whole 2.0 GB tree is searched in 75 ms by 16 workers, which
  is far more aggregate bandwidth than matching alone would allow, so most of
  the wall time is still `open`/`read`, as on macOS (Experiment 13).

### A Linux-only bug in the C library: `ffs_search` hung forever

`zig build c-example` had never been run off macOS, and on Linux it hung on
the first search — at *any* thread count (1, 2, 4, 16), on a 6-file directory,
100% of runs. It reproduces on the 0.0.8 tag too, so it predates the walk
rewrite above; the in-process tests never caught it because `zig build test`
links the same code into one binary instead of a separate static library.

The cause is in `build.zig`, not the search: the library module was built
**without `link_libc`**, so `libffs.a` carried its own threading runtime into
a host program that already had libc's, and the first `Io.Threaded` wait never
woke. The whole fix is `.link_libc = true` on the library module — which macOS
needed anyway, since `search.autoJobs` calls `sysctlbyname` there. With it,
`examples/count.c` reports 119 matching lines for `dictFind` on redis, the same
as the CLI and the same as the macOS run in Experiment 14.

Worth remembering as a shape of bug: *the same code, linked differently*. Every
other test in this repo exercises the Zig build of `c_api.zig`; only the C
example exercises the artifact that users actually link.

### Memory

Peak RSS now follows the thread count, since each worker holds one 256 KiB
read buffer: 8.2 MB at `-j4`, 12.2 MB at `-j16` on the kernel tree. ripgrep
is 10.8 MB on the same search.

### Correctness

Speed means nothing if the tools disagree, so `bench/h2h.sh` ends by
comparing match counts with ripgrep. Identical on all six:

```
literal PM_RESUME: 38        regex PM_[A-Z_]+: 114,746
literal ERR_PTR: 17,569      regex [0-9a-f]{16}: 17,005
literal zqxjvkwqz: 0         regex \w+_lock_irqsave\(: 16,957
```

`zig build test` passes on Linux (the randomized matcher, regex and C API
tests), `zig build c-example` gives the same counts as the CLI (119 on redis
`dictFind`) once the library links libc — see the bug below — and the debug
build, which uses the checking allocator, reports no leak from the queue's
hand-allocated items.

### Caveats

- One Linux machine, one filesystem (ext4 on LUKS), warm page cache. The
  `-j 16` runs have a visible spread (±7 ms, about 9%), since 16 workers on 8
  physical cores land differently each run.
- The walk grew from 62 to 175 code lines. That is the price of the queue:
  1.69x on this fixture, 13% even single-threaded.
- macOS was **not** re-measured with the new walk. The `results/` tables are
  still the one-task-per-directory design on an M5; `-j auto` there is
  unchanged (4 performance cores), and whether a queue helps a machine where 4
  threads was already optimal is an open question (answered in Experiment 16).
- `ack` is missing from the Linux tables, and the `ignore-case-*`,
  `*-matcher`, `*-content`, `size-variants-*` and `syscalls-*` files in
  `results/` have no script, so they have no Linux counterpart.

## Experiment 16 — macOS again: the worker-pool walk on the M5

Experiment 15 rewrote the walk for Linux and left macOS un-measured. The
question it left: on a machine where 4 threads was already the optimum
(Experiment 12) and system time is ~95% of the work (Experiment 13), does a
shared work queue buy anything? Same M5, macOS 27.0.1, same Homebrew
ripgrep 15.2.0, ack 3.10 and BSD grep as in Setup; hyperfine is now **2.0.0**
(see below). Current `main` (4681f99), which is the pool walk plus
everything since: ripgrep's command line, the multi-literal regex prefilter,
the ignore-file hardening.

Every script in `bench/` was run with `OUT=results-macos`; `bench/h2h.sh`
with `1,2,4,6,8,10`, this machine's thread counts. `results/` is left as
Experiments 1–14 wrote it. All numbers below are **medians**, not means:
on the kernel tree, runs here are bimodal (most near the median, a few
taking 2–8x as long), and the mean mostly measures how many slow runs a
command happened to draw.

### Old walk against new, in alternating rounds

Experiment 13 showed that on this machine the order commands run in can
matter more than the code, so the direct answer comes from an A/B, not from
comparing today's run with the old `results/`. Three builds: 263bd0b (one
task per directory, the last commit before the pool), f279c41 (the pool,
Experiment 15) and `main`. Eight rounds, each running the three one after
another (5 kernel runs, 20 redis runs each), pooled
(`results-macos/ab/`):

| Search | one task per directory | worker pool | `main` | pool wins |
|:---|---:|---:|---:|---:|
| Linux `PM_RESUME`, `-j auto` (= 4) | 1,159 ms | 1,166 | 1,146 | 3 / 8 rounds |
| Redis `dictFind`, `-j auto` | 18.0 ms | **15.0** | 15.4 | **8 / 8** |
| Linux `PM_RESUME`, `-j1` | 1,696 ms | 1,893 | 1,677 | 1 / 4 |
| Redis `dictFind`, `-j1` | 21.6 ms | 21.7 | 21.3 | 2 / 4 |

- **On the kernel tree, nothing.** All three builds land within 2% of each
  other, and the round medians swing from 853 to 2,122 ms for the *same*
  binary. The long serial tail that the queue fixed on 16 Linux threads
  does not exist with 4 workers: there are few enough of them that the big
  directories are always shared out anyway, and the bottleneck is APFS, not
  scheduling (system time is 3.2–3.7 s for 1.1 s of wall, user 130 ms).
- **On redis, 17% faster**, in every round. 1,680 files is small enough
  that per-directory setup was a visible part of the run, and this is the
  per-worker `Local` (one 256 KiB buffer per worker, not one per directory)
  rather than the queue.
- **Single-threaded, no change.** Linux gained 13% at `-j1` from the same
  per-worker buffer; on macOS the allocation was never the cost, `open` is.
- The kernel-tree medians here (~1.15 s) are slower than the same command
  elsewhere in this experiment (~0.87 s): the A/B ran while the machine was
  busiest (see Caveats). Only the comparison within one table holds.

### Thread count

`bench/threads.sh` (`results-macos/threads-*.json`), against Experiment 12:

| `-j` | auto (= 4) | 1 | 2 | 3 | 4 | 5 | 6 | 8 | 10 |
|:---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Linux `PM_RESUME`, now | 941 ms | 1,819 | **1,114** | 1,123 | 1,128 | 1,293 | 1,429 | 1,932 | 1,845 |
| Linux, Experiment 12 | **891** | 1,625 | 1,332 | 991 | 955 | 1,328 | 1,336 | 2,017 | 2,130 |
| Redis `dictFind`, now | **11.7 ms** | 20.7 | 15.5 | 12.9 | 14.8 | 15.5 | 15.3 | 15.3 | 15.4 |
| Redis, Experiment 12 | 15.3 | 21.6 | 17.8 | 16.1 | **15.3** | 16.3 | 16.5 | 16.7 | 17.1 |

`-j auto` and `-j 4` are the same thread count, so the 941 against 1,128 ms
(and 11.7 against 14.8) is this machine's noise; `bench/h2h.sh`'s own sweep
has `-j4` at 935 ms and 12.1 ms. Read that way, **the curve has not moved**:
2–4 threads is the plateau, and from 5 threads on, when the efficiency cores
join, system time climbs (3.3 s at `-j4`, 7.3 s at `-j6`, 12 s at `-j8`) and
wall time follows. Experiment 12's hypothesis holds with the new walk:
`auto` = performance cores is right on this M5, and it is the opposite of
Linux, where every added thread helped.

### ffs and ripgrep at the same thread count

`bench/h2h.sh`, kernel tree, `PM_RESUME`:

| `-j` | 1 | 2 | 4 | 6 | 8 | 10 |
|:---|---:|---:|---:|---:|---:|---:|
| ffs | 2,557 ms | **1,182** | 935 | 1,408 | 1,766 | 2,102 |
| ripgrep | **2,018** | 1,220 | **848** | **1,320** | 1,762 | **1,875** |

Within noise of each other at every count, both best at 4, both 2x slower
at 10. Unlike Linux, there is no algorithmic gap left to show: both tools
spend their time waiting on the same `open` calls. (The `-j1` row is the
bimodal case at its worst — ffs's own sweep had `-j1` at 1,819 ms an hour
earlier.)

### Literal search

`bench/searches.sh`, kernel tree, each tool as normally run:

| Query | ffs | ffs `-j1` | `rg -uu` | `ack` | `grep -rI` |
|:---|---:|---:|---:|---:|---:|
| Rare `PM_RESUME` | **919 ms** | 1,549 | 2,133 | 3,973 | 8,042 |
| Common `ERR_PTR` | **823** | 1,938 | 2,141 | 13,674 | 14,274 |
| No match `zqxjvkwqz` | **891** | 1,576 | 2,077 | 9,247 | 11,966 |
| Long `#include <linux/module.h>` | **816** | 3,424 | 1,964 | 14,193 | 14,668 |

`bench/h2h.sh`, with ripgrep held to 4 threads:

| Query | ffs | ffs `-j4` | `rg -uu` | `rg -uu -j4` |
|:---|---:|---:|---:|---:|
| Rare `PM_RESUME` | 870 ms | 866 | 2,043 | **845** |
| Common `ERR_PTR` | **855** | 874 | 1,962 | 950 |
| No match `zqxjvkwqz` | 890 | 876 | 1,908 | **868** |
| Long `#include <linux/module.h>` | 852 | **838** | 1,801 | 978 |
| `-i PM_RESUME` | **928** | — | 1,841 (`-i`) | — |

The same picture as Experiments 7–12: 2.2–2.4x ahead of ripgrep as each is
normally run, because ripgrep uses all 10 cores and macOS punishes that, and
a tie with `rg -j4` (±10%, either way). ffs, its default and `-j4` are the
same thing here, as they should be.

Redis (`bench/bench.sh`, then `bench/h2h.sh`):

| | ffs | ffs `-j1` | rg | ack | grep |
|:---|---:|---:|---:|---:|---:|
| Defaults | **15.3 ms** | — | 19.7 | 105.1 | 138.2 |
| All text files, nothing ignored | **15.7** | 24.4 | 18.7 (`-uu`) | 93.2 | 97.6 (`-rI`) |
| Same, `bench/h2h.sh` | **11.7** | — | 18.4 (`-uu`) | — | — |

The same command took 15.7 ms in one script and 11.7 ms in another, half an
hour apart: on redis the machine's state moves the number more than any
change in this experiment except the A/B above.

### Regex

`bench/regex.sh`, kernel tree unless marked redis; `rg -P` from
`bench/h2h.sh`; "before" is `ffs -E` in `results/` (Experiment 11, macOS):

| Pattern | ffs | before | `rg -uu -j4` | `rg -uu` | `rg -uu -P` |
|:---|---:|---:|---:|---:|---:|
| `PM_[A-Z_]+` | 1,020 ms | 868 | **864** | 2,063 | 1,621 |
| `\bERR_PTR\(-E[A-Z]+\)` | **872** | 875 | 946 | 2,053 | — |
| `\w+_lock_irqsave\(` | 899 | 930 | **891** | 2,078 | 1,562 |
| `(spin\|mutex)_lock\(` | **871** | 905 | 927 | 1,979 | — |
| `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | 1,179 | 1,167 | **942** | 1,988 | 1,589 |
| `[0-9a-f]{16}` | 2,386 | 2,304 | **1,167** | 1,597 | 1,572 |
| `-i todo\|fixme` | **874** | 1,921 | 884 | 1,817 | — |
| redis `dict(Find\|Delete)\(` | **12.0** | 18.5 | 15.5 | 18.7 | — |
| redis `[0-9]{3,}` | **16.1** | 24.6 | 20.9 | 23.6 | — |

- **`-i todo|fixme` went from 2.2x behind `rg -j4` to a tie** (1,921 →
  874 ms). That is the multi-literal prefilter (6522b74), not the walk: it
  was the case Experiment 15 named as the strongest argument for one, and on
  this machine it closes the gap completely.
- Patterns with a literal tie `rg -j4`, as before; `PM_[A-Z_]+` at 1,020 ms
  is one noisy run, `bench/h2h.sh` has it at 870.
- **No literal, still behind**: `[0-9a-f]{16}` 2.0x behind `rg -j4`, the
  `#define` pattern 1.25x. That is the Pike VM (user time 6.4 s against
  ripgrep's 2.0 s), and it is the same gap as before.
- Redis gained ~35% on both. The A/B puts the walk's share at 17%; the rest
  is between-session drift (see the redis table above), not a regex change.
- BSD grep for scale: `PM_[A-Z_]+` 846 ms against 9,244 (11x), and
  `[0-9a-f]{16}` 2,615 against 29,160 (11x).

### An agent's session

`bench/agent.sh`, from inside the redis checkout (`results-macos/agent.md`),
the first macOS run of it:

| # | What the agent wants | ffs | ripgrep | |
|---:|:---|---:|---:|:---|
| 1 | Find the build files and docs | **2.4 ms** | 6.0 ms | 2.5x faster |
| 2 | Look for agent instructions | **2.5** | 6.5 | 2.6x faster |
| 3 | Guess a symbol's name | **5.4** | 10.2 | 1.9x faster |
| 4 | Jump to a declaration | **1.3** | 2.2 | 1.6x faster |
| 5 | Read a function body | **1.4** | 2.3 | 1.6x faster |
| 6 | Spell out case variants | **6.6** | 10.3 | 1.6x faster |
| 7 | Search the whole repo | **11.7** | 19.3 | 1.6x faster |
| 8 | Count uses per file | **5.4** | 10.1 | 1.9x faster |
| 9 | Which files call it | **5.3** | 10.0 | 1.9x faster |
| 10 | Whole word only | **5.6** | 10.1 | 1.8x faster |
| 11 | Pull out IDs | **5.6** | 10.3 | 1.9x faster |
| 12 | Tests that mention it | **2.9** | 6.5 | 2.2x faster |
| 13 | Read a saved test log | **2.4** | 3.4 | 1.4x faster |
| 14 | Regex with no literal | 15.9 | **10.9** | 1.5x slower |
| 15 | Alternation with a common word | **5.6** | 10.4 | 1.9x faster |

**The whole session: ffs 80.1 ms, ripgrep 128.4 ms** (Linux: 82 against
94). The calls agents make are small, so the Mac's penalty for using every
core shows up as ripgrep's ~10 ms floor on anything that walks `src/`, and
ffs's 4 workers avoid it. The regex with no literal costs 5 ms here against
10 ms on Linux.

The first run of this script printed a table of absurd times (ffs
"20,666,368,039 ms"). **hyperfine 2.0 writes JSON schema 2**, where each
result has a `summary` with a `mean` for every metric (CPU cycles,
instructions, memory, then times), and `agent.sh` took the first `"mean"` it
found — the cycle count. `agent.sh` now reads the mean under
`time_wall_clock` when the file has a `schema_version`, and the old one
otherwise; it gives the same numbers as before on `results-linux/`. The
other scripts only export JSON, so their files are fine, but anything that
reads `results-macos/*.json` must use the new layout (`results/` and
`results-linux/` are schema 1).

### The matcher alone

`bench/match.sh`, best of 7, single-threaded, 512 MB in memory:

| Term | sensitive | insensitive | Linux (Exp. 15), sensitive / insensitive |
|:---|---:|---:|---:|
| `PM_RESUME` | **18.67 ms, 27.4 GB/s** | 22.08, 23.2 | 11.7 / 18.4 GB/s |
| `ERR_PTR` | **18.60, 27.5** | 26.15, 19.6 | 11.6 / 16.3 |
| `zqxjvkwqz` | **16.40, 31.2** | 16.87, 30.4 | 12.6 / 21.8 |
| `#include <linux/module.h>` | **16.95, 30.2** | 17.30, 29.6 | 12.1 / 21.3 |
| `the` | **21.37, 24.0** | 24.53, 20.9 | 11.1 / 17.1 |
| `e` | **103.46, 4.95** | 112.00, 4.57 | 5.15 / 4.92 |

- Unchanged from Experiment 8 (18.36 ms on `PM_RESUME` then).
- **On the M5 the case-sensitive path is faster than `-i`**, by 2–40%, as it
  should be. Experiment 15's backwards result (`-i` 1.4–1.7x *faster*) is
  therefore x86-specific: same source, so it is in what the 16-byte vector
  code compiles to for AVX2 — the sensitive path is probably leaving work
  on the table there, not the insensitive one doing something clever. That
  narrows the experiment Experiment 15 asked for.
- On realistic terms the M5's single core searches at 24–31 GB/s, 2.3x the
  Ryzen's; end to end the Mac is 11x slower on the kernel tree. All of that
  is the filesystem.

### Memory

Peak RSS on the kernel tree is **3.9 MB**, down from 7.7 MB (`results/`,
Experiment 12): four buffers instead of one per directory in flight.
`rg -uu -j4` is 9.8 MB and `rg -uu` 12.4 MB. The regex with a big VM state
(`#define`) peaks at 11.1 MB. Redis: 3.3 MB, from 4.1.

### Correctness

`bench/h2h.sh`'s match counts agree with ripgrep on all six queries, the
same numbers as on Linux (38; 17,569; 0; 114,746; 17,005; 16,957).
`bench/agent.sh` checks that ffs and ripgrep give identical output on all
15 calls before timing them, and it passed. The three A/B builds give the
same 119 lines on redis `dictFind`.

### Conclusion

On the M5 **the worker pool is a wash on the large tree and a 17% win on the
small one**, and the win is the per-worker buffer, not the queue. Keeping it
costs nothing here; Experiment 15 is the reason it exists. `-j auto` is
still right on both machines, for opposite reasons. The multi-literal
prefilter, measured here on macOS for the first time, removed the worst
regex loss. The no-literal patterns are still 1.25–2x behind ripgrep.

### Caveats

- **A busy machine.** The load average was 4–7 for the whole run (other
  work was running; it was not stopped), which is the likeliest cause of the bimodal runs and
  of the ~30% drift between scripts. The A/B, where every round runs all
  three builds back to back, is the only table that cancels that out; the
  others compare tools within one hyperfine call, which is fair to each
  tool but not reproducible to better than ±15%.
- One Mac, warm cache, APFS on the internal SSD.
- The A/B binaries were built from worktrees at 263bd0b and f279c41, with
  their own command line (`ffs [-j N] DIR TERM`), so `-uu` was not needed
  there; the JSON in `results-macos/ab/` has the exact commands.
- `README.md`'s macOS column (0.84–0.87 s literal, 2.30 s hex) still holds
  within this noise, so it was left alone.

## Experiment 17 — LLVM: rare probes, a lazy DFA and class runs

A new fixture, the LLVM monorepo (Setup), on the Linux box of Experiment
15 (same ripgrep 15.2.0 and hyperfine 1.20.0). LLVM is mostly C++ with
long template-heavy lines and large test directories of `.ll`, `.td` and
`.mlir` files. `bench/llvm.sh` runs 21 searches with ffs and ripgrep:
literals, `-i`, the default ignore-file filtering, `-g`, `-l`, `-c`, `-w`,
regexes with a literal, alternations, and three with no literal. It checks
that both tools report the same number of lines (they do, for all 21, in
every run below). Following the convention that serious regex numbers use
the PCRE2 build, the build compared is `-Dpcre2=true`; the default build is
checked too.

### Where ffs lost

On the first run (`results-linux/llvm-pcre2-base/`), ffs won 18 of 21, by
1.2–1.9x. It lost three:

| Search (`-uu -n`) | ffs + PCRE2 | ripgrep | |
|:---|---:|---:|:---|
| `[A-Za-z_]{30,}` | 1,038 ms | **479 ms** | 2.2x slower |
| `[0-9a-f]{16}` | 589 ms | **453 ms** | 1.3x slower |
| `class \w+ : public \w+` | 210 ms | **178 ms** | 1.2x slower |

The default build lost the first two by 11x and 6x (its user time reached
77 s on `{30,}`; `results-linux/llvm-vm-base/`).

Two causes. **(1)** `class \w+ : public \w+` has a literal, `" : public "`,
and the SIMD search compares a term's first and last byte, here two
spaces: nearly every indented line was a candidate. `-F ' : public '` took
187 ms, `-F ': public'` 120 ms. **(2)** With no literal, every byte went to
PCRE2 (or the Pike VM). Inside a long identifier, a backtracker can match
29 bytes of `[A-Za-z_]{30,}`, fail, and start again one byte later, so its
work grows with the repeat count; the Pike VM keeps up to 30 threads alive
per byte. On the default build `{10,}` took 3.3 s, `{20,}` 4.8 s; ripgrep's
DFA reads each byte once.

### What changed, one step at a time

Each step was timed against the baseline binary built from `7256ab4`,
both PCRE2 builds, 10–15 runs, warm cache.

1. **Rare probes** (`match.probes`). A byte-frequency table (`match.rarity`,
   -4·log2 of each byte's frequency in a 470 MB sample of the three
   fixtures) picks the term's two rarest bytes as the SIMD probes, here
   `:` and `b`. `class \w+ : public \w+`: 195 → **126 ms** (user 1,488 →
   639 ms). The first version cost 8% on `-i -F DenseMap` and 4% on a
   three-literal alternation, even where the probes stayed at the ends.
   Two reasons: `probes` ran once per buffer (188,000 times) and did float
   `exp2`/`log2` per letter under `-i`; and runtime offsets meant the
   newline-counting load could no longer double as the first probe.
   A comptime table for the folded case and a comptime copy of the loop
   for end probes fixed the first (115.1 ms before, 116.6 after). For the second, the
   rare pair is used only when the ends are common (more than 1 position in
   1,024) and the rare pair is at least 4x better: the alternation's end
   pairs (`i`/`>`, `d`/`>`) were already rare, so the swap bought nothing
   and cost a load. After that, user time was level with the baseline on
   every other query.
2. **Choosing the literal by rarity** (`regex.score`). Of the literals a
   regex requires, the one estimated rarest wins (byte rarities summed),
   not the longest. A set of several literals pays 4 bits per extra
   literal: on LLVM, `-e 'Find|Delete'` took 839 ms of user time against
   609 ms for `-F dict`, so `dict` stays the choice for
   `dict(Find|Delete)\(` even though `{Find, Delete}` is estimated 2 bits
   rarer. This changed no choice in the suite; it is a correctness-of-
   heuristic fix (`eee[0-9]Kj` now prefilters with `Kj`).
3. **Lazy DFA** (`src/dfa.zig`, ARCHITECTURE.md). One table lookup per
   byte, states built on demand from the Pike VM's program, a 2 MB cache
   per thread, and a fallback to the VM/PCRE2 if the cache thrashes. It
   answers `isMatch` for prefiltered lines and scans whole buffers when
   there is no literal. Not for `\b`.

   | `-uu -n` | before | DFA | ripgrep |
   |:---|---:|---:|---:|
   | `[0-9a-f]{16}` | 580 ms | **366 ms** | 442 ms |
   | `[A-Za-z_]{30,}` | 1,029 ms | **369 ms** | 476 ms |
   | `[0-9]{5,}` | 437 ms | **378 ms** | 608 ms |

   For lines the literal prefilter hands over, the DFA and PCRE2 are
   equally fast: with PCRE2 asked first instead, seven regex queries moved
   by -2 to +2 ms. Checking the candidates is not where the time goes. The
   DFA stays first, so the default build gets the same speed.
4. **Class-run prefilter** (`match.findLinesRun`). With no literal, a run
   of at least `min` bytes from one class that every match contains (16
   from `[0-9a-f]`), when the class has at most 4 ranges and the run is
   rare (8 bits or more). The SIMD scan marks the class's bytes per block
   and finds runs by AND-ing the bitmask with itself shifted. When the
   regex is just the run, its lines are the answer; otherwise the DFA
   checks them.

   | `-uu -n` | DFA | **+ class runs** | ripgrep |
   |:---|---:|---:|---:|
   | `[0-9a-f]{16}` | 366 ms | **156 ms** | 443 ms |
   | `[A-Za-z_]{30,}` | 369 ms | **154 ms** | 477 ms |
   | `[0-9]{5,}` | 378 ms | **169 ms** | 613 ms |
5. **PCRE2.** Restarting PCRE2 past a failed run, the other idea, became
   moot: the class-run scan and the DFA take those patterns before PCRE2
   sees them. Its start-of-match optimizations were already on
   (`pcre.zig` never passes `PCRE2_NO_START_OPTIMIZE`). PCRE2 is now used
   for `\b` patterns, a DFA that gave up, and `-o`.

### The suite after

`results-linux/llvm-pcre2/`, PCRE2 build, against the first run. Rows 6–9
use each tool's defaults (ignore files on); the rest `-uu -n`.

| Search | ffs before | **ffs after** | ripgrep | |
|:---|---:|---:|---:|:---|
| `-F ZQXJVKWQZ_NOPE` | 122 ms | **121 ms** | 167 ms | 1.38x faster |
| `-F getOperandBundle` | 123 ms | **121 ms** | 167 ms | 1.38x faster |
| `-F getOperand` | 124 ms | **123 ms** | 171 ms | 1.39x faster |
| `-F return` | 134 ms | **133 ms** | 253 ms | 1.90x faster |
| `-i -F DenseMap` | 118 ms | **119 ms** | 181 ms | 1.52x faster |
| `-F getOperandBundle` (defaults) | 140 ms | **139 ms** | 192 ms | 1.38x faster |
| `-g "*.cpp" -F getOperandBundle` (defaults) | 50 ms | **50 ms** | 61 ms | 1.23x faster |
| `-l -F getOperandBundle` (defaults) | 140 ms | **139 ms** | 192 ms | 1.37x faster |
| `-c -F getOperand` (defaults) | 140 ms | **139 ms** | 195 ms | 1.40x faster |
| `-w Value` | 148 ms | **146 ms** | 182 ms | 1.25x faster |
| `Fixup[A-Z][a-z]+` | 123 ms | **123 ms** | 169 ms | 1.37x faster |
| `std::unique_ptr<\w+>` | 124 ms | **123 ms** | 173 ms | 1.41x faster |
| `class \w+ : public \w+` | 210 ms | **125 ms** | 178 ms | 1.43x faster |
| `llvm::\w+::\w+\(` | 126 ms | **125 ms** | 175 ms | 1.39x faster |
| `isa<CallInst>\|dyn_cast<LoadInst>\|getTerminator` | 147 ms | **142 ms** | 180 ms | 1.27x faster |
| `getOperand\|struct [A-Z]\w+Info` | 149 ms | **143 ms** | 188 ms | 1.31x faster |
| `%[0-9]+ = load` | 132 ms | **128 ms** | 197 ms | 1.54x faster |
| `^\s*// CHECK-NEXT:\s+%\w+` | 128 ms | **125 ms** | 174 ms | 1.40x faster |
| `[0-9a-f]{16}` | 589 ms | **158 ms** | 446 ms | 2.83x faster |
| `[A-Za-z_]{30,}` | 1,038 ms | **156 ms** | 478 ms | 3.07x faster |
| `[0-9]{5,}` | 440 ms | **177 ms** | 643 ms | 3.62x faster |

**21 of 21.** The literal rows don't move: the changes only touch them
through `probes`, which keeps their end probes.

### The other fixtures

No regressions on the kernel and Redis queries of `bench/regex.sh` and
Experiment 15 (`-uu -n`, base → new, ripgrep):

| | PCRE2 build | default build | ripgrep |
|:---|---:|---:|---:|
| kernel `[0-9a-f]{16}` | 378 → **97 ms** | 1,369 → **99 ms** | 285 ms |
| kernel `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | 148 → **116 ms** | 539 → **114 ms** | 155 ms |
| kernel `PM_RESUME\|ERR_PTR\|struct [a-z]+_ops` | 119 → **118 ms** | 231 → **118 ms** | 121 ms |
| kernel `PM_[A-Z_]+` | 78 → **75 ms** | 80 → **74 ms** | 97 ms |
| kernel `-F PM_RESUME` | **72** → 73 ms | 74 → **72 ms** | 90 ms |
| kernel `-i 'todo\|fixme'` | 91 → **89 ms** | 89 → **86 ms** | 104 ms |
| kernel `-w ERR_PTR` | **72** → 74 ms | 78 → **75 ms** | 95 ms |
| Redis `[0-9]{3,}` | 6.7 → **5.1 ms** | 11.6 → **5.8 ms** | 7.4 ms |

The rest (`\bERR_PTR\(-E[A-Z]+\)`, `\w+_lock_irqsave\(`,
`(spin|mutex)_lock\(`, the three-literal alternation, `dict(Find|Delete)\(`)
moved by at most 6 ms, and by at most 1.2 ms where slower. The two builds are now within a few
percent of each other everywhere: PCRE2 no longer buys speed, only `\b`
patterns on its engine. The agent session (`bench/agent.sh`) went from
81.8 to **60.1 ms** on the default build and 62.2 to **55.6 ms** with
PCRE2 (ripgrep 89.4 ms); call 14, `[0-9a-f]{16}`, from 17.4 to 4.7 ms, and
ffs now wins all 15 calls.

### Correctness

All 97 compat checks against ripgrep pass on both builds, and the docs
examples (`tests/docs.sh`) pass. New tests: the DFA is checked against the
backtracking reference in the randomized regex test (5,000 patterns), and
its whole-buffer search against the VM line by line (3,000 patterns, with
empty lines and with and without a final '\n'); a pattern with too many
states (`a[ab]{14}c`) must make the DFA clear or give up and still answer
right; `findLinesRun` is checked against a line-by-line reference; the
randomized test also asserts that every matching line has the class run,
and that an exact run is the whole answer.

## Experiment 18 — LLVM: a tree that does not fit in the page cache

A third, larger fixture: the [LLVM monorepo](https://github.com/llvm/llvm-project),
shallow clone of `main` at `eddc1360d9dc066398f393c5d613afa160eeeb32`
(2026-10-23) in `fixtures/llvm`. 3.0 GB on disk including a 360 MB `.git`,
188,431 files, 165 of them over 1 MB (long `.ll` and `.mlir` tests). Same M5,
tools and `main` (7256ab4) as Experiment 16; no code was changed for this
experiment. Results in `results-macos/llvm-survey/` and
`results-macos/llvm-pcre2/` (hyperfine 2.0 JSON, schema 2, with the exact
commands). Medians throughout.

### What the survey said

14 query shapes, `ffs`, `rg -uu` and `rg -uu -j4`, 5 runs each after 1
warm-up, whole tree (`llvm-<slug>.json`):

| Query | ffs | `rg -uu` | `rg -uu -j4` | ffs user CPU |
|:---|---:|---:|---:|---:|
| Rare `isNoopIntrinsic` | 4,733 ms | 2,957 | 2,960 | 242 ms |
| Common `getContext` | 4,674 | 3,340 | 3,646 | 240 |
| No match `zqxjvkwqz` | 4,588 | 3,189 | 3,071 | 233 |
| Long `#include "llvm/ADT/SmallVector.h"` | 4,359 | 3,542 | 3,788 | 227 |
| `-i getcontext` | 4,651 | 3,516 | 5,041 | 265 |
| `-w Value` | 4,657 | 3,307 | 3,729 | 367 |
| `LLVM_[A-Z_]+` | 4,657 | 3,266 | 4,031 | 248 |
| `\w+Pass\b` | 4,698 | 3,424 | 3,870 | 266 |
| `(Sema\|Parser)::Act` | 4,665 | 3,207 | 3,521 | 238 |
| `-i todo\|fixme` | 4,727 | 3,426 | 3,664 | 444 |
| `[0-9a-f]{16}` | 7,210 | 3,195 | 5,397 | 9,882 |
| `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | 4,672 | 3,491 | 3,399 | 304 |
| `-c getContext` | 4,679 | 3,427 | 3,322 | 243 |
| `-l getContext` | 4,697 | 4,244 | 3,278 | 237 |

The first macOS result where ripgrep wins nearly everything, including at
the same thread count. But the shape says it is not the search: ffs takes
~4.6 s **whatever the pattern**, with 230–440 ms of user CPU, and its system
CPU (6.2 s) is the same as `rg -j4`'s (6.0 s). Same work, more wall time:
ffs's four workers are waiting on something.

### Not the walk

`--files`, which walks and lists without opening a file
(`llvm-walk.json`): ffs 676 ms, `rg -uu -j4` 652 ms; on the kernel tree ffs
188 ms, ripgrep 232 ms. The walk is not where 1.5 s goes.

### It is the page cache

Pages read in from disk during one search (`vm_stat` Pageins before and
after): 10,000–38,000 pages of 16 KiB, **160–600 MB per run, for both
tools**. On the kernel tree, Experiment 16, a warm run reads nothing. This
Mac has 24 GiB, but at the time ~18.5 GiB of application memory sat in the
compressor (a video call, browsers, mail) and file-backed pages were
292,303, about **4.5 GiB for every cached file on the system**. LLVM
(3.0 GB) next to the kernel tree (2.0 GB) does not fit, so every run starts
with part of LLVM evicted and pays for it at SSD speed.

Two consequences:

- **The survey's order was unfair.** hyperfine runs all of one command's
  runs, then the next command's; with a cache that holds most but not all of
  the tree, what ran before decides how much is left. Alternating the tools
  every run (`alternating-rare.json`, 8 rounds, order reversed every round)
  shrinks the gap from 1.6x to **1.23x**: ffs 4.28 s, `rg -j4` 3.47, `rg`
  3.58, with about the same page-ins (19,600, 20,900, 26,300). A later set
  of 5 alternating pairs, with the machine quieter, was 3.29 against 3.01 s
  (1.09x), and ffs won two of the five (not saved; `/usr/bin/time -l`).
- **Where it all fits, it is a tie again** (`llvm-cached-subtree.json`, 10
  runs after 3 warm-ups):

| Subtree | ffs | `rg -uu -j4` | `rg -uu` |
|:---|---:|---:|---:|
| `llvm/` (1.5 GB), `isNoopIntrinsic` | 776 ms | **767** | 1,796 |
| `clang/` (477 MB), `getContext` | **322** | 333 | — |

That is the Experiment 16 result exactly: even with `rg -j4`, 2.3x ahead of
ripgrep's default.

### What is left: ffs pays more for a cold tree at `-j4`

Even alternating, ffs at 4 threads is slower than ripgrep at 4 threads on
the whole tree. What was looked at:

- **Time per file.** A throwaway build logged open/search/close time for
  every file. 99.9% of files take under 0.5 ms and no file over 2.5 ms;
  there is no slow outlier, the time is spread over everything. Between
  runs of the *same binary*, the thread time spent in `llvm/` alone went
  from 1.9 to 8.3 s: how cold the cache is decides it.
- **Where threads block.** `sample`, 2 s mid-run, top of stack: ffs
  `readv` 3,156, `openat` 792, `__ulock_wait2` 1,015 (the idle main
  thread); ripgrep `read` 1,893, `open` 1,927, `__ulock_wait` 1,002. Both
  have four threads blocked in the kernel nearly all the time; ffs waits on
  file data, ripgrep about equally on opening and reading.
- **Context switches.** For both tools, wall time follows voluntary context
  switches (each a thread blocking) on the same line, about 2.2 s plus
  ~10 µs per switch. The cost of a miss is the same; ffs's slow runs are the
  ones with more misses.
- **Not read size.** A build with 64 KiB reads, ripgrep's buffer size
  instead of 256 KiB (in case ffs waited for 4x more of each cold binary
  file before seeing its NUL), was no better: 4.78 against 4.68 s
  (`alternating-64k.json`).
- **Not `.git`.** Without hidden files (`-u --no-ignore`, 187,156 files):
  ffs 4.44 s, `rg -j4` 4.07, `rg` 3.73 (`alternating-nohidden.json`).
- **Not thread count, as such.** Both run 4 workers plus a main thread
  (`ps -M` mid-run).

But more threads do help ffs here (`alternating-threads.json`, 5 rounds):

| | ffs `-j4` | ffs `-j6` | ffs `-j8` | ffs `-j10` | `rg -j4` | `rg -j8` |
|:---|---:|---:|---:|---:|---:|---:|
| Whole tree, `isNoopIntrinsic` | 4,680 ms | 3,340 | **3,090** | 3,350 | 3,260 | **3,000** |

With part of the tree on the SSD, more reads in flight is worth more than
the kernel contention that makes 4 threads best on a cached tree
(Experiment 12): ffs `-j8` matches `rg -j8`. Why ripgrep gets nearly that
much out of 4 threads and ffs does not is **not explained**. The candidate
left is the order of reads: ffs's workers take the deepest queued directory
and visit its files while reading it, so the four stay close together in the
tree; ripgrep reads a directory whole and its workers steal from each
other's stacks, so they spread out. That would change which files are still
cached when each one gets there. Untested.

### Regex, and PCRE2

The one row above that is not I/O: `[0-9a-f]{16}`, with 9.9 s of user CPU
against ripgrep's 3.5. To compare engines without the cache in the way,
`clang/` (cached), `zig build -Dpcre2=true` against Homebrew's PCRE2, 10
runs after 3 warm-ups (`results-macos/llvm-pcre2/`); all three engines gave
the same match counts on every pattern:

| Pattern | ffs | ffs + PCRE2 | `rg -j4` | `rg` | `rg -P -j4` |
|:---|---:|---:|---:|---:|---:|
| `getContext` (literal) | **309 ms** | 330 | 320 | 559 | 344 |
| `LLVM_[A-Z_]+` | **302** | 309 | 336 | 732 | 370 |
| `(Sema\|Parser)::Act` | **320** | **320** | 331 | 652 | 383 |
| `-i todo\|fixme` | **324** | 326 | 337 | 535 | 399 |
| `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | **314** | 318 | 321 | 539 | 341 |
| `\w+Pass\b` | 385 | 333 | **328** | 541 | 453 |
| `[0-9a-f]{16}` | 674 | **391** | 398 | 498 | 411 |

- **The only engine loss is a pattern with no literal**, and PCRE2's JIT
  closes it: 674 → 391 ms, user CPU 1.6 s → 0.49 s, a tie with `rg -j4`.
  `\w+Pass\b` too (385 → 333): its literal `Pass` is common, so the VM sees
  many candidate lines.
- Everywhere else PCRE2 changes nothing, because the SIMD prefilter does
  the work and the VM barely runs. ffs is level with or ahead of `rg -j4` on
  all of them.
- The `#define` pattern, 1.25x behind on the kernel tree (Experiment 16),
  ties here: LLVM has few `#define … 0x` lines, so few candidates.

### Conclusion

ripgrep wins on LLVM on this Mac because **the tree does not fit in the
memory left for the file cache**, and every run reads hundreds of MB from
the SSD. Cached, it is the kernel-tree result again: ffs ties `rg -j4` on
everything with a literal. What is real:

1. On a cold tree ffs at its default 4 threads loses 10–25% to ripgrep at 4;
   at 8 threads it ties. `-j auto` is tuned for cached trees.
2. A regex with no literal is 1.7x behind in ffs's VM; `-Dpcre2=true`
   closes it.

### Caveats

- The cache state is set by everything else on the machine, which was not
  controlled: there was no `sudo purge` for a truly cold start, and no way to
  give LLVM the whole cache. Absolute times on the whole tree moved from 2.8
  to 4.8 s for the same binary.
- The survey's ordering bias (above) applies to its whole table; only the
  alternating runs and the cached subtrees compare the tools fairly.
- One Mac, APFS on the internal SSD. Not run on Linux.

## Experiment 19 — LLVM again: the DFA on the M5, and why a big tree runs cold

Same M5 and fixture as Experiment 18, two questions it left open.

### The lazy DFA on the M5

Experiment 18 ran 7256ab4, before the lazy DFA and the class-run scan of
Experiment 17. The same `clang/` set (cached, 10 runs after 3 warm-ups),
7256ab4 against `main` (dd71234), `main` with `-Dpcre2=true`, and `rg -uu
-j4`, plus the `\b` pattern from Next steps; all four gave the same lines on
every pattern (`results-macos/llvm-dfa/`). Median wall time, ms:

| Pattern | ffs 7256ab4 | ffs `main` | `main` + PCRE2 | `rg -j4` |
|:---|---:|---:|---:|---:|
| `getContext` (literal) | 301 | 303 | 302 | 308 |
| `LLVM_[A-Z_]+` | 302 | 303 | 305 | 317 |
| `(Sema\|Parser)::Act` | 316 | 306 | 308 | 320 |
| `-i todo\|fixme` | 311 | 309 | 310 | 328 |
| `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | 320 | 352 | 367 | 317 |
| `\w+Pass\b` | 304 | 304 | 306 | 308 |
| `[0-9a-f]{16}` | 620 | **310** | 311 | 379 |
| `\b[a-z]+_[a-z]+\b` | 619 | 618 | 619 | **453** |

- **`[0-9a-f]{16}` is closed**: 620 → 310 ms, user CPU 1.53 s → 0.11 s,
  ahead of `rg -j4` (541 ms of user CPU) and level with PCRE2. The DFA
  makes the PCRE2 build unnecessary on this machine.
- The `#define` row is noise: 30 runs each (`clang-define-30runs.json`) give
  medians of 301 and 302 ms and the same user CPU; `main` had a few slow
  outliers.
- `\w+Pass\b` is 304 ms on both builds, not Experiment 18's 385: that
  difference was the machine, not the code.
- `\b` is the loss left, 1.37x here (Next steps).

### A repeatable cold start

`results-macos/llvm-walk/evict.c` drops a tree's files from the page cache
without `sudo`: map each file and `msync(MS_INVALIDATE)`, as `vmtouch -e`
does on macOS, and `mincore` to check. After it, `clang/` is 0% resident and
a search takes 0.84 s instead of 0.30. Directory metadata stays cached (the
tool walks the tree to find the files), so "cold" here means cold file data.

### Walk order does not matter cold

To test Experiment 18's candidate, a throwaway build
(`walk-variants.diff`) picks the walk order from `FFS_WALK`: `lifo` (today:
one shared stack, deepest directory first), `fifo` (breadth first), `steal`
(a stack per worker, an idle one steals the oldest item of another, as
ripgrep does), and `dirfirst` (read the whole directory before visiting its
files, as ripgrep does). All give the same matches and file count.
Whole tree evicted before every run, commands alternating, 6 rounds,
`-uu -n -F isNoopIntrinsic` (`cold-all.json`):

| | `lifo` | `fifo` | `steal` | `lifo,dirfirst` | `steal,dirfirst` | `rg -j4` |
|:---|---:|---:|---:|---:|---:|---:|
| `-j4`, median | 4.45 s | 4.52 | 4.48 | 4.50 | 4.46 | 4.93 |

`-j8`: ffs 2.72 s, `rg -j8` 2.86. Spreads under 0.1 s. Fully cold, the
order makes no difference, and **ffs is ahead of ripgrep** at both thread
counts. Experiment 18's loss is not about cold reads.

### It is the same order every run

Experiment 18's runs were never fully cold: the tree is bigger than the
cache, and right after a full read 55% of it was resident. With no
eviction, each command run 4 times back to back (first run dropped), two
passes in opposite order (`self-all.json`):

| | after another command (run 0) | after itself (runs 1–3, median) | page-ins |
|:---|---:|---:|---:|
| ffs `lifo` (today) | 3.1–4.6 s | **4.75 s** | 23,180 |
| ffs `fifo` | 3.0–6.5 | 4.77 | 22,420 |
| ffs `steal` | 2.6–3.0 | 3.74 | 19,532 |
| ffs `lifo,dirfirst` | 2.5–2.9 | 4.65 | 22,814 |
| `rg -j4` | 3.2–3.4 | **3.17** | 12,632 |

After itself, ffs is as slow as fully cold (4.45 s). Every ffs order is
deterministic, so each run reads the tree in the order the last run did, and
an LRU cache smaller than the tree has, at every point, just evicted what
comes next: the textbook worst case for a repeated scan. ripgrep's order
differs from run to run (its workers steal from each other at random
moments), so about half its reads hit. `steal` is the least deterministic
of the ffs orders and the least bad. hyperfine runs one command's runs back
to back, which is why Experiment 18's survey had ffs at ~4.6 s **whatever
the pattern**, and why alternating the tools shrank the gap.

### The fix: a different order every run

`shuffle` reads a directory whole, shuffles its subdirectories and its files
with a seed taken from the clock (mixed with the directory's path), then
pushes and visits them. Same matches, a different order every run
(`self-shuffle.json`, `cold-shuffle.json`, `cached-*.json`):

| | ffs `lifo` | ffs `shuffle` | `rg -j4` |
|:---|---:|---:|---:|
| Whole tree, after itself | 4.38 s | **2.22** | 2.51 |
| page-ins | 18,082 | **2,406** | 7,921 |
| Whole tree, fully cold | **4.44 s** | 4.51 | 4.91 |
| Kernel tree, cached, `EXPORT_SYMBOL` | 849 ms | **811** | — |
| Kernel tree, cached, no match | 809 | 802 | — |
| `clang/`, cached, `getContext` | 317 | **300** | — |
| Redis, cached, no match | 12 | 12 | — |

(The machine was quieter for this table than for the ones above, so its
"after itself" times are lower across the board; compare within it.)

- **Searched again right after itself, `shuffle` is 2x faster than today's walk**
  and ahead of `rg -j4`, with a third of ripgrep's page-ins.
- Fully cold it costs 1.5%; cached, it is level or 2–5% faster (reading the
  directory whole before visiting its files seems to be the gain).
- No contract changes: output order is already documented as not fixed
  (`docs/output.md`), and `--sort` goes to ripgrep. Only `-j1`, "exactly
  depth-first" in `src/walk.zig`, stops being reproducible.

### Conclusion

1. The lazy DFA closes the literal-free regex gap on the M5 too;
   `\b` is the one regex loss left.
2. Experiment 18's "ffs blocks more on a cold tree" was ffs reading a tree
   bigger than the cache in the same order every run. A random order per run
   fixes it and costs nothing measurable elsewhere. More threads (`-j8`) help
   both tools cold, but ffs at `-j4` already beats `rg -j4` there, so
   `-j auto` does not need a cold-tree rule.

### Caveats

- One Mac. The cache size is set by the rest of the machine (here ~4.4 GiB
  file-backed, 55% of LLVM after a full read); with more free memory the tree
  fits and none of this shows.
- `shuffle` is a throwaway build behind an environment variable, not in
  `main`. Its `-j1` order is random too, which a real version might keep
  fixed.
- Eviction leaves directory metadata cached, so "fully cold" is not a boot
  cold start.

## Next steps

- Run on more machines: `bench/threads.sh` on another Mac (does `-j auto`
  land on the best `-j`? see Experiment 12; Experiment 16 confirms it again
  on the M5 with the new walk). Linux is covered by Experiment 15, on one
  16-thread box.
- Shuffle the walk order per run (Experiment 19): put `shuffle` into the
  walker for real, without the environment variable, and decide whether
  `-j1` keeps a fixed order. Re-run Experiment 18's survey with it.
- Case-sensitive matcher on x86: 1.4–1.7x slower than `-i` on the Ryzen,
  2–40% faster on the M5 (Experiment 16). Look at what the AVX2 build emits.
- `\b` in the DFA: `-w` and `\b` patterns still run on the Pike VM (PCRE2
  doesn't take them either). Where the only literal is common this is the
  one measured loss left: `\b[a-z]+_[a-z]+\b` on the kernel, 2.4 s against
  ripgrep's 0.65 s (`\b[0-9a-f]{16}\b` is fine, 97 ms against 418, since
  the class run picks the lines); on LLVM `clang/` on the M5, 618 ms against
  453 (Experiment 19). An ASCII-only `\b` would be one byte of lookbehind in the state;
  ffs's Unicode `\b` needs the DFA to fall back only on non-ASCII bytes.
- A DFA skip loop: while the DFA sits in its start state, jump with SIMD to
  the next byte that can start a match (`first`), as the Pike VM does.
- ffs as Claude Code's ripgrep, in shadow mode first. ffs now takes every
  command line the Grep tool passes (`--json`, `--null`, `--max-columns`,
  `-t`, `--iglob`; see `docs/ripgrep.md`) and hands the rest to `FFS_RG`.
  Next, an `rg` shim on `PATH` (with `USE_BUILTIN_RIPGREP=0`) that runs
  both tools on every call, returns ripgrep's output, and logs the command
  line, both timings and any difference in output (timings in `--json`
  taken out). A few days of real sessions would show the differences
  `tests/compat.sh` misses and the time saved per call. Once the log is
  clean, the shim returns ffs's output and keeps ripgrep as the fallback.
  Known difference to fix first: a binary file under `--json`, where
  ripgrep reports the matches before the NUL and `binary_offset` and ffs
  prints nothing.
- Ignore files (`.gitignore`), probably as an option, since searching
  everything is the point of the current benchmarks.
- Unicode: case folding for `-i`, Unicode `\w`/`\b` for `-E`.
- Try `std.Io.Evented` once its macOS backend compiles.
