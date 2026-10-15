# ffs

[![CI](https://github.com/felipecruz/ffs/actions/workflows/ci.yml/badge.svg)](https://github.com/felipecruz/ffs/actions/workflows/ci.yml)

**ripgrep's command line, in about 2,300 lines of Zig.** It takes the
flags coding agents actually use (`-n`, `-g`, `--files`, `-o`, `-c`, `-l`,
`-v`, `-A/-B/-C`, …), respects `.gitignore`, and prints exactly what
ripgrep prints (`tests/compat.sh` checks 97 command lines). It is faster
than ripgrep on most searches and slower on some, all listed below. No
dependencies; staying simple is the point.

## What it looks like

Run from inside the Redis source, as an agent would:

```console
$ ffs -n -w 'dictFind|dictAdd|dictDelete' src/dict.h
125: * dictAdd, dictFind, and other functions against the dictionary even while
208:int dictAdd(dict *d, void *key, void *val);
215:int dictDelete(dict *d, const void *key);
221:dictEntry * dictFind(dict *d, const void *key);

$ ffs -n -A4 '^dictEntry \*dictFind\(' src/dict.c
814:dictEntry *dictFind(dict *d, const void *key)
815-{
816-    if (dictSize(d) == 0) return NULL; /* dict is empty */
817-    const uint64_t hash = dictHashKey(d, key, d->useStoredKeyApi);
818-    return dictFindByHash(d,key,hash);

$ ffs --files src | ffs -c '\.c$'
119
```

More, all with real output, in **[EXAMPLES.md](EXAMPLES.md)**: listing files
with globs, reading function bodies, pulling out IDs, counting, exit
statuses and pipelines.

## Results

On a Linux machine (AMD Ryzen 9 PRO 6950H, 16 threads, Omarchy/Arch) unless
noted, each tool with its defaults, and every output identical. Times are
wall-clock means from hyperfine; **bold** is the faster tool.

### An agent's session

The 15 calls in `bench/agent.sh`, the kinds of search agents run
(SEARCH_CMDs.md), run from inside the Redis repository (25 MB):

| # | What the agent wants | Call | ffs | ripgrep | |
|---:|:---|:---|---:|---:|:---|
| 1 | Find the build files and docs | `rg --files -g '*README*' -g Makefile -g '*.sh' -g AGENTS.md` | **4.0 ms** | 6.5 ms | 1.6x faster |
| 2 | Look for agent instructions | `rg --files --hidden -g '*instructions*' -g CLAUDE.md -g AGENTS.md` | **4.0 ms** | 6.5 ms | 1.7x faster |
| 3 | Guess a symbol's name | `rg -n 'dictFind\|dictAdd\|dictDelete' src` | **5.1 ms** | 6.9 ms | 1.4x faster |
| 4 | Jump to a declaration | `rg -n 'struct redisServer \{\|struct client \{' src/server.h` | **1.0 ms** | 2.1 ms | 2.0x faster |
| 5 | Read a function body | `rg -n -A40 '^dictEntry \*dictFind\(' src/dict.c` | **1.0 ms** | 2.0 ms | 2.0x faster |
| 6 | Spell out case variants | `rg -n 'lazyfree\|lazyFree\|LazyFree' src` | **5.0 ms** | 8.1 ms | 1.6x faster |
| 7 | Search the whole repo | `rg -n serverAssert` | **11.0 ms** | 12.0 ms | 1.1x faster |
| 8 | Count uses per file | `rg -c 'serverLog\(LL_WARNING' src` | 6.6 ms | 6.7 ms | about the same |
| 9 | Which files call it | `rg -l aeCreateFileEvent src` | **4.8 ms** | 6.8 ms | 1.4x faster |
| 10 | Whole word only | `rg -w -n dictSize src` | **4.9 ms** | 6.9 ms | 1.4x faster |
| 11 | Pull out IDs | `rg -o -n 'REDIS_VERSION "[0-9.]+"\|RDB_VERSION [0-9]+' src` | **4.9 ms** | 7.0 ms | 1.4x faster |
| 12 | Tests that mention it | `rg -n -g '*.tcl' 'lazyfree' tests` | **4.2 ms** | 5.2 ms | 1.2x faster |
| 13 | Read a saved test log | `rg -n 'err\]\|exception\]\|Executed [0-9]+ tests'` | **2.8 ms** | 3.6 ms | 1.3x faster |
| 14 | Regex with no literal | `rg -n '[0-9a-f]{16}' src` | 17.4 ms | **7.1 ms** | 2.4x slower |
| 15 | Alternation with a common word | `rg -n 'dictFind\|struct [a-z]+ \{' src` | **5.3 ms** | 7.0 ms | 1.3x faster |

The whole session: **ffs 82 ms, ripgrep 94 ms.** The one regex with no
fixed text in it costs ffs 10 ms more than ripgrep, which gives back almost
half of the 23 ms it gains on the other 14 calls.

### A big tree

The Linux kernel source (1.9 GB, 92,000 files):

| Search | **ffs** | ripgrep | |
|:---|---:|---:|:---|
| Word `PM_RESUME` | **84 ms** | 110 ms | 1.3x faster |
| List files, `--files` | **27 ms** | 32 ms | 1.2x faster |
| Alternation `PM_RESUME\|ERR_PTR\|dictFind` | **106 ms** | 124 ms | 1.2x faster |
| Case-insensitive `-i 'todo\|fixme'` | **102 ms** | 125 ms | 1.2x faster |
| Alternation with a common word `spin_lock\|mutex_lock\|struct [a-z]+_ops` | 269 ms | **149 ms** | 1.8x slower |
| Regex with no literal `[0-9a-f]{16}` | 1,459 ms | **306 ms** | 4.8x slower |

Searching everything (`-uu` for both tools, so no ignore files), on the
same machine and on an Apple M5 with macOS, where ffs runs on the 4
performance cores:

| Search | **ffs** Linux | ripgrep Linux | **ffs** macOS | ripgrep `-j4` macOS | ripgrep macOS |
|:---|---:|---:|---:|---:|---:|
| Rare word `PM_RESUME` | **74 ms** | 94 ms | 0.85 s | **0.84 s** | 1.93 s |
| Common word `ERR_PTR` | **84 ms** | 102 ms | **0.84 s** | 0.85 s | 1.90 s |
| Regex `PM_[A-Z_]+` | **81 ms** | 104 ms | **0.87 s** | 0.91 s | 2.02 s |
| Regex with no literal `[0-9a-f]{16}` | 1,361 ms | **281 ms** | 2.30 s | **1.33 s** | 1.67 s |

With both tools held to the same thread count (`bench/h2h.sh`, Linux,
`PM_RESUME`):

| Threads | 1 | 2 | 4 | 8 | 12 | 16 |
|:---|---:|---:|---:|---:|---:|---:|
| **ffs** | **580 ms** | **299** | **154** | **88** | **80** | **76** |
| ripgrep | 898 ms | 372 | 191 | 106 | 90 | 80 |

| | **ffs** | ripgrep |
|:---|---:|---:|
| Memory (kernel-tree search) | **7–9 MB** at `-j4`, 12 MB at `-j16` | 10–20 MB |
| Binary | **410 KB** | 6.5 MB |
| Dependencies | none | PCRE2 |

**Where ripgrep wins:** regexes that don't contain a fixed piece of text,
or where that text is very common. ripgrep has a real regex engine; ffs
has a small one, and it is the slow part. The optional PCRE2 build closes
most of that gap.

### Optional: the PCRE2 build

`zig build -Dpcre2=true` links the system's PCRE2 and lets its JIT do the
small regex engine's work: checking the lines the SIMD prefilter finds, and
scanning whole files when a regex has no fixed text. Matching rules don't
change (the same 97 compat checks pass), but the binary needs libpcre2-8
installed.

| Linux kernel source | ffs | **ffs + PCRE2** | ripgrep |
|:---|---:|---:|---:|
| Regex with no literal `[0-9a-f]{16}` | 1,382 ms | 392 ms | **296 ms** |
| Alternation with a common word `spin_lock\|mutex_lock\|struct [a-z]+_ops` | 261 ms | **123 ms** | 140 ms |
| `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | 548 ms | **159 ms** | 170 ms |
| Regex with a literal `PM_[A-Z_]+` | **87 ms** | 91 ms | 113 ms |

On the agent session above, PCRE2 brings the regex with no literal from
17.4 ms to 8.4 ms (ripgrep: 7.1 ms), and the whole session to **62 ms
against ripgrep's 89 ms** (`results-linux/pcre2/agent.md`). ripgrep still
wins on regexes with no fixed text, by 1.2–1.3x instead of 2.4–4.7x.

**Why ffs is fast elsewhere:** two ideas, done carefully.

1. **Threads:** one shared queue, `N` identical workers. A queue item is
   either a directory to read or a batch of files to search, and every
   worker does both, so no thread is left alone with a 4,000-file
   directory while the others sit idle.
2. **SIMD:** compare 16 bytes at a time, counting line numbers in the same
   pass.

## How it works

| File | Code lines | What it does |
|---|---:|---|
| `src/main.zig` | 411 | ripgrep's command line (a quarter of it the `--help` text) |
| `src/walk.zig` | 321 | Parallel directory walk: worker pool over one queue; hidden, ignore files, `-g` |
| `src/glob.zig` | 229 | Globs and gitignore rules |
| `src/search.zig` | 427 | Thread pool; stream each file, skip binaries, ripgrep's output modes |
| `src/match.zig` | 198 | SIMD search, one term or several |
| `src/regex.zig` | 690 | Regex: parser, literal prefilter, Pike VM |
| `src/c_api.zig` | 95 | Optional C library (`include/ffs.h`) |
| `src/pcre.zig` | 48 | Optional PCRE2 JIT backend (`-Dpcre2=true`) |

The line counts exclude comments, blank lines and tests.

**The SIMD loop.** For each 16-byte block, ffs compares the block with the
term's first byte, and the block shifted by `len - 1` with its last byte.
Only positions where both match get a full comparison. The same loaded
block feeds per-lane newline counters, so line numbers cost one extra
instruction per 16 bytes.

**Regex without a regex engine's complexity.** ffs takes the text every
match must contain (`PM_` in `PM_[A-Z_]+`, or one of `cancel` and `launch`
in `func (cancel|launch)`) and lets the SIMD loop find candidate lines. Only those lines go to a small Pike VM, which runs in
linear time with no backtracking, so no pattern can blow up.

**Streaming.** Files go through a 256 KiB buffer, never loaded whole. A
small file costs exactly `open`, `read` and `close`.

## Usage

```
ffs [OPTIONS] PATTERN [PATH...]
ffs --files [OPTIONS] [PATH...]
```

The same command line as ripgrep, for the flags ffs has (`ffs --help` lists
them): `-e -F -i -S -s -w -x -v`, `-n -N -H -I -o -c -l -q -m`, `-A -B -C`,
`--files -g --hidden --no-ignore --no-ignore-vcs -u -a -d -j`. PATTERN is a
regex (`. [a-z] [^0-9] [[:alpha:]] \d \w \s \b ^ $ * + ? {n,m} *? | ( ) (?:)
(?i)`); one with no regex syntax in it goes straight to the SIMD search.
With no PATH, ffs searches standard input if something is piped in, else
the current directory, skipping hidden files and what `.gitignore`,
`.ignore` and `.rgignore` list. Exit status: 0 on a match, 1 on none, 2 on
an error.

`zig build` puts the binary in `zig-out/release/ffs`. The output is
ripgrep's format for a pipe (no colors, no headings; line numbers with
`-n`, or by default on a terminal); the order is not deterministic.

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
- **Not every ripgrep flag.** Missing: `-t`/`--type`, `--sort`, `--json`,
  `-r` (replace), `-U` (multiline), `-L` (follow symlinks), `-P`, colors
  and `--heading`. The global gitignore (`core.excludesFile`) is not read.
  An unknown flag is an error, never silently ignored.
- **ASCII semantics, mostly.** `-i` and `\w` are ASCII-only, like
  ripgrep's `(?-u)` mode. `\b` (and so `-w`) sees whole UTF-8 characters,
  as ripgrep does, with a table that treats letters as word characters and
  the common punctuation and symbol blocks as not.
- **Binary files are skipped** as soon as a NUL byte shows up (`-a` searches
  them); ripgrep prints the matches it found before the NUL.
- **Some regexes are slower than ripgrep's**: up to 4.8× when there is no
  fixed text in the pattern, 1.3× with the PCRE2 build (the tables above).

## Correctness

`zig build test` runs randomized tests:
- the SIMD search against a naive reference;
- the regex VM against a backtracking reference matcher;
- the C API, called the way C would call it.

`tests/compat.sh` runs about 100 command lines through both ffs and
ripgrep on a small git tree (ignore files at several levels, hidden files,
a binary file, standard input) and compares stdout and the exit status. It
covers the searches in SEARCH_CMDs.md, what coding agents actually run. On
both fixtures the outputs are also identical for every flag. The exceptions
are non-ASCII case folding and a file with a NUL byte late in it, which
ripgrep partly prints and ffs skips.

CI (GitHub Actions) runs the tests and `tests/compat.sh` on Linux and macOS,
checks `zig fmt`, smoke-tests the CLI and the C library, and cross-compiles
all six targets.
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

- [EXAMPLES.md](EXAMPLES.md): about 30 searches agents run, with real
  output.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the code works, the 16-byte loop
  and the regex engine.
- [EXPERIMENTS.md](EXPERIMENTS.md): the full lab notebook, with 15
  experiments, every benchmark and what didn't work.
