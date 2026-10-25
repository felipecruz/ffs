# ffs

[![CI](https://github.com/felipecruz/ffs/actions/workflows/ci.yml/badge.svg)](https://github.com/felipecruz/ffs/actions/workflows/ci.yml)

**ripgrep's command line, in about 3,000 lines of Zig.** It takes the
flags coding agents actually use (`-n`, `-g`, `--files`, `-o`, `-c`, `-l`,
`-v`, `-A/-B/-C`, …), respects `.gitignore`, and prints exactly what
ripgrep prints (`tests/compat.sh` checks 97 command lines). It is faster
than ripgrep on every search benchmarked below, on the Linux kernel, Redis
and LLVM trees, regexes included; the one kind of regex where it is still
slower is under Limitations.

![ffs searching the Linux kernel source, and ripgrep for comparison](docs/demo.gif)

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

More in **[docs/](docs/README.md)**: a page per topic (patterns, which files
get searched, output) and [about 30 examples](docs/examples.md), every one
run and checked in CI, plus a man page.

## Results

On a Linux machine (AMD Ryzen 9 PRO 6950H, 16 threads, Omarchy/Arch) unless
noted, each tool with its defaults, and every output identical. Times are
wall-clock means from hyperfine; **bold** is the faster tool.

### An agent's session

The 15 calls in `bench/agent.sh`, the kinds of search agents run
(SEARCH_CMDs.md), run from inside the Redis repository (25 MB):

| # | What the agent wants | Call | ffs | ripgrep | |
|---:|:---|:---|---:|---:|:---|
| 1 | Find the build files and docs | `rg --files -g '*README*' -g Makefile -g '*.sh' -g AGENTS.md` | **3.9 ms** | 6.4 ms | 1.7x faster |
| 2 | Look for agent instructions | `rg --files --hidden -g '*instructions*' -g CLAUDE.md -g AGENTS.md` | **3.9 ms** | 6.4 ms | 1.7x faster |
| 3 | Guess a symbol's name | `rg -n 'dictFind\|dictAdd\|dictDelete' src` | **4.8 ms** | 7.0 ms | 1.4x faster |
| 4 | Jump to a declaration | `rg -n 'struct redisServer \{\|struct client \{' src/server.h` | **1.1 ms** | 2.1 ms | 1.8x faster |
| 5 | Read a function body | `rg -n -A40 '^dictEntry \*dictFind\(' src/dict.c` | **1.0 ms** | 2.0 ms | 1.9x faster |
| 6 | Spell out case variants | `rg -n 'lazyfree\|lazyFree\|LazyFree' src` | **4.8 ms** | 7.0 ms | 1.5x faster |
| 7 | Search the whole repo | `rg -n serverAssert` | **5.4 ms** | 8.3 ms | 1.5x faster |
| 8 | Count uses per file | `rg -c 'serverLog\(LL_WARNING' src` | **4.6 ms** | 6.8 ms | 1.5x faster |
| 9 | Which files call it | `rg -l aeCreateFileEvent src` | **4.5 ms** | 6.7 ms | 1.5x faster |
| 10 | Whole word only | `rg -w -n dictSize src` | **4.6 ms** | 7.0 ms | 1.5x faster |
| 11 | Pull out IDs | `rg -o -n 'REDIS_VERSION "[0-9.]+"\|RDB_VERSION [0-9]+' src` | **4.8 ms** | 7.0 ms | 1.5x faster |
| 12 | Tests that mention it | `rg -n -g '*.tcl' 'lazyfree' tests` | **4.0 ms** | 5.1 ms | 1.3x faster |
| 13 | Read a saved test log | `rg -n 'err\]\|exception\]\|Executed [0-9]+ tests'` | **2.9 ms** | 3.4 ms | 1.2x faster |
| 14 | Regex with no literal | `rg -n '[0-9a-f]{16}' src` | **4.7 ms** | 7.2 ms | 1.5x faster |
| 15 | Alternation with a common word | `rg -n 'dictFind\|struct [a-z]+ \{' src` | **4.9 ms** | 7.1 ms | 1.4x faster |

The whole session: **ffs 60 ms, ripgrep 89 ms.** ffs is faster on all 15
calls, including the regex with no fixed text in it (call 14), which a lazy
DFA and a SIMD scan for runs of a character class brought from 17.4 ms to
4.7 ms.

### A big tree

The Linux kernel source (1.9 GB, 92,000 files), each tool with its
defaults (hidden and ignored files skipped):

| Search | **ffs** | ripgrep | |
|:---|---:|---:|:---|
| Word `PM_RESUME` | **77 ms** | 99 ms | 1.3x faster |
| List files, `--files` | **26 ms** | 30 ms | 1.1x faster |
| Alternation `PM_RESUME\|ERR_PTR\|dictFind` | **96 ms** | 110 ms | 1.1x faster |
| Case-insensitive `-i 'todo\|fixme'` | **93 ms** | 112 ms | 1.2x faster |
| Alternation with a common word `spin_lock\|mutex_lock\|struct [a-z]+_ops` | **117 ms** | 134 ms | 1.1x faster |
| Regex with no literal `[0-9a-f]{16}` | **102 ms** | 288 ms | 2.8x faster |

Searching everything (`-uu` for both tools, so no ignore files), on the
same machine and on an Apple M5 with macOS, where ffs runs on the 4
performance cores:

| Search | **ffs** Linux | ripgrep Linux | **ffs** macOS | ripgrep `-j4` macOS | ripgrep macOS |
|:---|---:|---:|---:|---:|---:|
| Rare word `PM_RESUME` | **72 ms** | 91 ms | 0.85 s | **0.84 s** | 1.93 s |
| Common word `ERR_PTR` | **73 ms** | 95 ms | **0.84 s** | 0.85 s | 1.90 s |
| Regex `PM_[A-Z_]+` | **74 ms** | 98 ms | **0.87 s** | 0.91 s | 2.02 s |
| Regex with no literal `[0-9a-f]{16}` | **97 ms** | 281 ms | 2.30 s\* | **1.33 s** | 1.67 s |

\* Measured before the lazy DFA and the class-run scan (Experiment 17),
which made this search 14x faster on Linux; not yet re-measured on the M5.

With both tools held to the same thread count (`bench/h2h.sh`, Linux,
`PM_RESUME`):

| Threads | 1 | 2 | 4 | 8 | 12 | 16 |
|:---|---:|---:|---:|---:|---:|---:|
| **ffs** | **592 ms** | **305** | **158** | **88** | **78** | **74** |
| ripgrep | 902 ms | 371 | 192 | 105 | 91 | 81 |

On Redis (25 MB), `dictFind`: ffs 5.3 ms, ripgrep 8.2 ms, grep 19.7 ms
with each tool's defaults; 5.1 ms against 6.4 ms with `-uu`
(`results-linux/defaults.md`, `all-text.md`).

| | **ffs** | ripgrep |
|:---|---:|---:|
| Memory (kernel-tree search) | **7–9 MB** at `-j4`, 12 MB at `-j16` | 10–20 MB |
| Binary | **410 KB** | 6.5 MB |
| Dependencies | none | PCRE2 |

### Regexes

ffs looks for a fixed piece of text every match must contain (`PM_` in
`PM_[A-Z_]+`) or, failing that, a run of one character class (16 hex
digits in `[0-9a-f]{16}`), with SIMD, and checks the few lines that have
it with a lazy DFA. `bench/regex.sh`, `-uu -n`, kernel and Redis:

| Search | **ffs** | ffs + PCRE2 | ripgrep | |
|:---|---:|---:|---:|:---|
| kernel `PM_[A-Z_]+` | **74 ms** | 79 ms | 98 ms | 1.3x faster |
| kernel `\bERR_PTR\(-E[A-Z]+\)` | **72 ms** | 73 ms | 95 ms | 1.3x faster |
| kernel `\w+_lock_irqsave\(` | **73 ms** | 74 ms | 97 ms | 1.3x faster |
| kernel `(spin\|mutex)_lock\(` | **74 ms** | 75 ms | 107 ms | 1.4x faster |
| kernel `-i 'todo\|fixme'` | **86 ms** | 86 ms | 104 ms | 1.2x faster |
| kernel `spin_lock\|mutex_lock\|struct [a-z]+_ops` | 114 ms | **109 ms** | 127 ms | 1.1x faster |
| kernel `^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+` | **114 ms** | 116 ms | 156 ms | 1.4x faster |
| kernel `[0-9a-f]{16}` | **97 ms** | 97 ms | 281 ms | 2.9x faster |
| Redis `dict(Find\|Delete)\(` | 5.5 ms | **5.0 ms** | 6.7 ms | 1.2x faster |
| Redis `[0-9]{3,}` | 5.9 ms | **5.1 ms** | 7.7 ms | 1.3x faster |

GNU grep takes 30 s on the kernel's `[0-9a-f]{16}`, and 1.4 s on
`PM_[A-Z_]+`.

On the LLVM monorepo (188,000 files, 3.1 GB, mostly C++), ffs + PCRE2 is
faster than ripgrep on all 21 searches in `bench/llvm.sh`, 1.2x to 3.6x
(`results-linux/llvm-pcre2/`):

| LLVM, `-uu -n` | ffs + PCRE2 | ripgrep | |
|:---|---:|---:|:---|
| Common word `-F return` | **133 ms** | 253 ms | 1.9x faster |
| Case-insensitive `-i -F DenseMap` | **119 ms** | 181 ms | 1.5x faster |
| `class \w+ : public \w+` | **125 ms** | 178 ms | 1.4x faster |
| `getOperand\|struct [A-Z]\w+Info` | **143 ms** | 188 ms | 1.3x faster |
| `^\s*// CHECK-NEXT:\s+%\w+` | **125 ms** | 174 ms | 1.4x faster |
| `[0-9a-f]{16}` | **158 ms** | 446 ms | 2.8x faster |
| `[A-Za-z_]{30,}` | **156 ms** | 478 ms | 3.1x faster |
| `[0-9]{5,}` | **177 ms** | 643 ms | 3.6x faster |

### Optional: the PCRE2 build

`zig build -Dpcre2=true` links the system's PCRE2 and lets its JIT do the
work the lazy DFA can't: patterns with `\b` (`-w`), and patterns whose DFA
would need too many states. Matching rules don't change (the same 97 compat
checks pass), but the binary needs libpcre2-8 installed. Since the DFA,
the two builds are within a few percent of each other (table above). On
the agent session, the PCRE2 build takes **56 ms against ripgrep's 89 ms**
(`results-linux/pcre2/agent.md`).

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
| `src/match.zig` | 372 | SIMD search: one term or several, or a run of a character class |
| `src/regex.zig` | 827 | Regex: parser, literal and class-run prefilters, Pike VM |
| `src/dfa.zig` | 249 | Lazy DFA: one table lookup per byte to check a line or scan a buffer |
| `src/c_api.zig` | 95 | Optional C library (`include/ffs.h`) |
| `src/pcre.zig` | 48 | Optional PCRE2 JIT backend (`-Dpcre2=true`) |

The line counts exclude comments, blank lines and tests.

**The SIMD loop.** For each 16-byte block, ffs compares the block with the
term's first byte, and the block shifted by `len - 1` with its last byte.
Only positions where both match get a full comparison. When those two
bytes are common (the spaces around `" : public "`), it compares the
term's two rarest bytes instead, by a byte-frequency table from real
source trees. The same loaded block feeds per-lane newline counters, so
line numbers cost one extra instruction per 16 bytes.

**Regex without a regex engine's complexity.** ffs takes the text every
match must contain (`PM_` in `PM_[A-Z_]+`, or one of `cancel` and `launch`
in `func (cancel|launch)`) and lets the SIMD loop find candidate lines.
With no such text, a SIMD scan finds runs of a character class
(`[0-9a-f]{16}`) instead. Only the lines found go to a lazy DFA, one
table lookup per byte, built on demand from a small Pike VM's program.
Both run in linear time with no backtracking, so no pattern can blow up.

**Streaming.** Files go through a 256 KiB buffer, never loaded whole. A
small file costs exactly `open`, `read` and `close`.

## Install

Download the archive for your platform from the
[releases](https://github.com/felipecruz/ffs/releases) (Linux x86-64, glibc
or static musl, and ARM64; macOS Apple silicon and Intel; Windows x86-64),
and put `ffs` on your `PATH` and `ffs.1` in a `man1` directory. Or build it
with Zig 0.17: `zig build`. The [install page](docs/README.md#install) has
the commands, with the checksum check.

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

`zig build` puts the binary in `zig-out/release/ffs` and the man page in
`zig-out/share/man/man1/ffs.1`. The output is ripgrep's format for a pipe
(no colors, no headings; line numbers with `-n`, or by default on a
terminal); the order is not deterministic. The full reference is
[docs/](docs/README.md) and `man ffs`.

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
- **Regexes with `\b` skip the DFA**, and PCRE2 too (ffs's `\b` sees
  whole UTF-8 characters). They are fast when a rare literal or class run
  picks the lines (`\b[0-9a-f]{16}\b`: 97 ms against ripgrep's 418 on the
  kernel), but when the only literal is common the Pike VM checks most
  lines: `\b[a-z]+_[a-z]+\b` takes 2.4 s against ripgrep's 0.65 s. The
  same goes for the rare patterns that need too many DFA states, once the
  DFA gives up.

## Correctness

`zig build test` runs randomized tests:
- the SIMD search, and the class-run scan, against naive references;
- the regex VM and the lazy DFA against a backtracking reference matcher,
  and the DFA's whole-buffer search against the VM line by line;
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

- [docs/](docs/README.md), also at
  [felipecruz.github.io/ffs](https://felipecruz.github.io/ffs/): how to use
  ffs, a page per topic, with tested examples, and the man page.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the code works, the 16-byte loop
  and the regex engine.
- [EXPERIMENTS.md](EXPERIMENTS.md): the full lab notebook, with 15
  experiments, every benchmark and what didn't work.
