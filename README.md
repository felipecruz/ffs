# ffs

**A file searcher in about 450 lines of Zig that keeps pace with ripgrep.**
(940 with the optional regex engine and C library.)

No dependencies, no clever tricks. Just two ideas, done carefully:

1. **Threads:** one task per directory, one worker per performance core.
2. **SIMD:** compare 16 bytes at a time, counting line numbers in the same pass.

## Results

The Linux kernel source (1.9 GB, 92,000 files) on an Apple M5 with macOS.
Every text file is searched, nothing ignored. Times are wall-clock.

| Search | **ffs** | ripgrep `-j4` | ripgrep (default) | grep |
|:---|---:|---:|---:|---:|
| Rare word `PM_RESUME` | **0.85 s** | 0.84 s | 1.93 s | 14.5 s |
| Common word `ERR_PTR` | **0.84 s** | 0.85 s | 1.90 s | 14.4 s |
| Regex `PM_[A-Z_]+` | **0.87 s** | 0.91 s | 2.02 s | 14.3 s |
| Regex with no literal `[0-9a-f]{16}` | 2.30 s | **1.33 s** | 1.67 s | 28.3 s |
| Redis (25 MB), 37,000 matching lines | **15.8 ms** | 23.5 ms | — | — |

| | **ffs** | ripgrep | grep |
|:---|---:|---:|---:|
| Memory (Linux search) | **7–9 MB** | 10–20 MB | 3 MB |
| Binary | **256 KB** | 6.5 MB | 252 KB |
| Dependencies | none | PCRE2 | zlib, bz2, lzma |

- **As fast as ripgrep** at the same thread count, and about 2× faster
  than ripgrep's default. That gap comes from the thread count: ripgrep
  starts one thread per core, and on macOS more threads than performance
  cores mostly fight inside the kernel.
- **About 95% of the time is the kernel** opening and reading files. The
  search itself is no longer the bottleneck.
- **Where ripgrep wins:** regexes with no fixed text in them. ripgrep has a
  real regex engine; ffs has a small one (see below).

## How it works

| File | Code lines | What it does |
|---|---:|---|
| `src/main.zig` | 70 | Command line |
| `src/walk.zig` | 62 | Parallel directory walk: one task per directory |
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

  -j N|auto          worker threads (default: auto = performance cores)
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

- **Tested on one Mac.** It builds for Linux, Windows and Intel macOS, but
  those builds have never been run. `-j auto` reads the performance-core
  count on Apple silicon, and uses 4 elsewhere.
- **No ignore files.** ffs searches everything, including `.git`, and skips
  only binary files (any file with a NUL byte).
- **ASCII semantics.** `-i`, `\w` and `\b` are ASCII-only, like ripgrep's
  `(?-u)` mode.
- **Regexes with no fixed text are about 2× slower than ripgrep's** (the
  table above).

## Correctness

`zig build test` runs randomized tests:
- the SIMD search against a naive reference;
- the regex VM against a backtracking reference matcher;
- the C API, called the way C would call it.

Every feature was also compared with ripgrep's output, byte for byte, on
both codebases. Output is identical except for one case: a file with a NUL
byte late in it, which ripgrep partly prints and ffs skips.

## More

- [ARCHITECTURE.md](ARCHITECTURE.md): how the code works, the 16-byte loop
  and the regex engine.
- [EXPERIMENTS.md](EXPERIMENTS.md): the full lab notebook, with 14
  experiments, every benchmark and what didn't work.
