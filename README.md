# ffs

[![CI](https://github.com/felipecruz/ffs/actions/workflows/ci.yml/badge.svg)](https://github.com/felipecruz/ffs/actions/workflows/ci.yml)

**A file searcher in about 560 lines of Zig that keeps pace with ripgrep** —
and on a Linux machine it is ahead of ripgrep at every thread count, on the
Linux kernel source dataset (1.9 GB, 92,000 files).
(1,050 lines with the optional regex engine and C library.)

No dependencies, no clever tricks. Just two ideas, done carefully:

1. **Threads:** one shared queue, `N` identical workers. A queue item is
   either a directory to read or a batch of files to search, and every worker
   does both kinds of work, so whichever worker is free takes the next piece.
   Nobody is left searching a 4,000-file directory alone while the other
   threads sit idle — which is what fixed scaling on 16 threads.
2. **SIMD:** compare 16 bytes at a time, counting line numbers in the same pass.

## Results

The Linux kernel source dataset (1.9 GB, 92,000 files) on an Apple M5 with
macOS. Every text file is searched, nothing ignored. Times are wall-clock.

| Search | **ffs** | ripgrep `-j4` | ripgrep (default) | grep |
|:---|---:|---:|---:|---:|
| Rare word `PM_RESUME` | **0.85 s** | 0.84 s | 1.93 s | 14.5 s |
| Common word `ERR_PTR` | **0.84 s** | 0.85 s | 1.90 s | 14.4 s |
| Regex `PM_[A-Z_]+` | **0.87 s** | 0.91 s | 2.02 s | 14.3 s |
| Regex with no literal `[0-9a-f]{16}` | 2.30 s | **1.33 s** | 1.67 s | 28.3 s |
| Redis (25 MB), 37,000 matching lines | **15.8 ms** | 23.5 ms | — | — |

The same dataset on a Linux machine (AMD Ryzen 9 PRO 6950H, 16 threads,
Omarchy/Arch), where both tools use every core:

| Search | **ffs** | ripgrep | GNU grep |
|:---|---:|---:|---:|
| Rare word `PM_RESUME` | **74 ms** | 94 ms | 1,112 ms |
| Common word `ERR_PTR` | **84 ms** | 102 ms | 1,046 ms |
| Case-insensitive `-i PM_RESUME` | **72 ms** | 98 ms | — |
| Regex `PM_[A-Z_]+` | **81 ms** | 104 ms | — |
| Regex with no literal `[0-9a-f]{16}` | 1,361 ms | **281 ms** | — |
| Redis (25 MB), 37,000 matching lines | **5.4 ms** | 6.5 ms | — |

Both tools held to the same thread count on that Linux machine, searching
the Linux kernel source dataset for `PM_RESUME` — this is what the shared
queue bought (`bench/h2h.sh`):

| Threads | 1 | 2 | 4 | 8 | 12 | 16 |
|:---|---:|---:|---:|---:|---:|---:|
| **ffs** | **580 ms** | **299** | **154** | **88** | **80** | **76** |
| ripgrep | 898 ms | 372 | 191 | 106 | 90 | 80 |

| | **ffs** | ripgrep | grep |
|:---|---:|---:|---:|
| Memory (kernel-tree search) | **7–9 MB** at `-j4`, 12 MB at `-j16` | 10–20 MB | 3 MB |
| Binary | **256 KB** | 6.5 MB | 252 KB |
| Dependencies | none | PCRE2 | zlib, bz2, lzma |

- **As fast as ripgrep** at the same thread count on macOS, and about 2×
  faster than ripgrep's default there, because ripgrep starts one thread per
  core and on macOS more threads than performance cores mostly fight inside
  the kernel. On a Linux machine, where threads do keep paying off, ffs is
  ahead of ripgrep at *every* thread count, from 1 to 16 (EXPERIMENTS.md,
  Experiment 15).
- **Scales 7.6× on 16 threads** (580 → 76 ms on the kernel source dataset),
  against 5.0× before the shared queue landed. ripgrep scales further
  (10.5×) but starts from a slower single-threaded time, so ffs stays ahead
  the whole way.
- **About 95% of the time is the kernel** opening and reading files. The
  search itself is no longer the bottleneck.
- **Where ripgrep wins:** regexes with no fixed text in them — 1.4× on
  macOS, 3.3–4.8× on Linux. ripgrep has a real regex engine; ffs has a small
  one (see below).

## How it works

| File | Code lines | What it does |
|---|---:|---|
| `src/main.zig` | 70 | Command line |
| `src/walk.zig` | 175 | Parallel directory walk: worker pool over one queue |
| `src/search.zig` | 168 | Thread pool; stream each file, skip binaries, report matches |
| `src/match.zig` | 141 | SIMD search |
| `src/regex.zig` | 422 | Optional regex: parser + Pike VM |
| `src/c_api.zig` | 77 | Optional C library (`include/ffs.h`) |

The line counts exclude comments, blank lines and tests.

**The SIMD loop.** For each 16-byte block, ffs compares the block with the
term's first byte, and the block shifted by `len - 1` with its last byte.
Only positions where both match get a full comparison. The same loaded
block feeds per-lane newline counters, so line numbers cost one extra
instruction per 16 bytes.

**Regex without a regex engine's complexity.** ffs takes the text every
match must contain (`PM_` in `PM_[A-Z_]+`) and lets the SIMD loop find
candidate lines. Only those lines go to a small Pike VM, which runs in
linear time with no backtracking, so no pattern can blow up.

**Streaming.** Files go through a 256 KiB buffer, never loaded whole. A
small file costs exactly `open`, `read` and `close`.

## Usage

```
ffs [-j N|auto] [-i] [-E] [--content] <folder> <term>

  -j N|auto          worker threads (default: auto = performance cores on
                     Apple silicon, every logical CPU elsewhere)
  -i, --ignore-case  ASCII case-insensitive
  -E, --regex        <term> is a regex: . [a-z] [^0-9] \d \w \s \b ^ $ * + ? {n,m} | ( )
  --content          print path:line:content instead of path:line
```

`zig build` puts the binary in `zig-out/release/ffs`. Output is one
`path:line` per matching line; the order is not deterministic.

From C:

```c
#include <stdio.h>
#include "ffs.h"   /* zig-out/include, link zig-out/lib/libffs.a */

static int on_match(void *ctx, const ffs_match *m) {
    printf("%s:%zu:%s\n", m->path, m->line, m->text);
    return 0;   /* nonzero stops the search */
}

ffs_search("src", "TODO", FFS_IGNORE_CASE, 0, on_match, NULL);
```

## Limitations

- **Tested on one Mac and one Linux box** (Apple M5; AMD Ryzen 9 PRO 6950H
  on Omarchy/Arch, EXPERIMENTS.md, Experiment 15). It builds for Windows and
  Intel macOS, but those builds have never been run. `-j auto` reads the
  performance-core count on Apple silicon and uses every logical CPU
  elsewhere.
- **No ignore files.** ffs searches everything, including `.git`, and skips
  only binary files (any file with a NUL byte).
- **ASCII semantics.** `-i`, `\w` and `\b` are ASCII-only, like ripgrep's
  `(?-u)` mode.
- **Regexes with no fixed text are slower than ripgrep's**: about 2× on
  macOS, 3.3–4.8× on Linux (the tables above).

## Correctness

`zig build test` runs randomized tests:
- the SIMD search against a naive reference;
- the regex VM against a backtracking reference matcher;
- the C API, called the way C would call it.

Every feature was also compared with ripgrep's output, byte for byte, on
both codebases. Output is identical except for one case: a file with a NUL
byte late in it, which ripgrep partly prints and ffs skips.

CI (GitHub Actions) runs the tests on Linux and macOS, checks `zig fmt`,
smoke-tests the CLI and the C library, and cross-compiles all six targets.
Line coverage for `src/` is measured with `kcov` (Zig has no coverage of its
own) and posted on each pull request as a per-file table, with the HTML
report kept as a build artifact.

`bench/h2h.sh` re-checks that on every run: ffs and ripgrep report identical
match counts for three literals and three regexes on the kernel source
dataset (38,
17,569, 0, 114,746, 17,005 and 16,957 lines), so a speed number can never
come from work that was skipped. `zig build c-example` links the static
library and reports the same count as the CLI on Linux too — it used to hang
there forever, because `libffs.a` was built without libc
(EXPERIMENTS.md, Experiment 15).

## More

- [ARCHITECTURE.md](ARCHITECTURE.md): how the code works, the 16-byte loop
  and the regex engine.
- [EXPERIMENTS.md](EXPERIMENTS.md): the full lab notebook, with 15
  experiments, every benchmark and what didn't work.
