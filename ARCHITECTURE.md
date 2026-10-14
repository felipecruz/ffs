# ffs architecture

How ffs is put together, then a close look at how it finds a term inside a
file's bytes: the 16-byte SIMD loop in `src/match.zig`. Measurements are in
[EXPERIMENTS.md](EXPERIMENTS.md); Experiment 8 covers this loop.

## Code layout

| File | Responsibility |
|---|---|
| `src/main.zig` | Command line; calls `search.run` |
| `src/walk.zig` | Parallel recursive directory walk; knows nothing about searching |
| `src/search.zig` | `run`: thread pool, walk; per-file work: open, read (streaming), binary check, output |
| `src/c_api.zig` | C ABI (`include/ffs.h`): `ffs_search` with a callback, over `search.run` |
| `src/match.zig` | Finding the term in bytes (SIMD), with no I/O; naive reference and randomized test |
| `src/regex.zig` | `-E`: regex parser, compiler and Pike VM, behind the SIMD search as a prefilter |
| `src/bench_match.zig` | Matcher microbenchmark (`bench/match.sh`, EXPERIMENTS.md, Experiment 8) |

The layers connect through two small interfaces that are resolved at compile
time (`anytype`, no runtime cost):

- **walk → search.** A *visitor* has a per-directory-task `Local` state
  (`initLocal`, `deinitLocal`) and a `visitFile(local, file)` function.
  `file` gives the open directory handle, the file name and the path
  relative to the root. The visitor opens and reads the file itself, so
  reading strategies (mmap, whole-file reads, buffer sizes, and so on) can
  be tried without touching the walker. `Local` is used by only one task at
  a time, so it holds reusable buffers.
- **search → match.** `match.findLines(data, term, first_line, sink)` calls
  `sink.onLine(m)` for each matching line, with a `match.Match` (line
  number, position and line end; `m.text()` gives the line's text on
  demand). `first_line` lets a file be searched in chunks.
  `match.findLinesIgnoreCase` has the same signature, and so does
  `regex.findLines` apart from its compiled regex and VM scratch space. New
  matching algorithms go here, next to `findLinesNaive`, and the randomized
  test checks them against it.

## Where the loop sits

```
walk.zig     one task per directory ──► visitFile(local, file)
search.zig   read 256 KiB ─► NUL check ─► cut at last '\n' (or EOF) ─► findLines ─► carry partial line
match.zig    findLines: 16-byte SIMD scan + newline count ─► verify candidate ─► report line ─► skip to next line
```

`search.zig` hands `match.findLines` a slice that always ends on a line
boundary, except at end of file. It also passes `first_line`, the line
number of the slice's first byte. `findLines` returns the line number just
after the slice, which becomes `first_line` for the next read.
`findLines` therefore never has to deal with a line split across two reads,
and nothing else has to count lines.

## Data flow for one read (`src/search.zig`)

`search.run` creates the thread pool (`-j auto`: the performance-core count
from `sysctl hw.perflevel0.logicalcpu`, see `search.autoJobs`), opens the
root and starts the walk. Each file then goes through `Searcher.scan`. For
every `readStreaming` call into the 256 KiB buffer (`search.zig:166`):

1. **End of file:** a read that returns less than asked for means end of
   file, for a regular file (`search.zig:174`). A small file therefore
   costs `open`, one `read` and `close`, with no extra `read` that only
   returns 0. This saves one syscall per small file but no measurable
   time (EXPERIMENTS.md, Experiment 13).
2. **Byte-order mark:** on the first read, a UTF-8 BOM is removed, as
   ripgrep does (`search.zig:175`).
3. **Binary check:** `indexOfScalar(fresh, 0)` runs on the newly read bytes
   (`search.zig:183`). If it finds a NUL, the file is dropped along with any
   matches collected so far.
4. **Cut:** at end of file, everything is searched. Otherwise the cut is
   after the last newline (`findScalarLast`, `search.zig:187`); with no
   newline, all bytes are carried and the loop reads more. The buffer
   doubles if a single line fills it (`search.zig:163`).
5. **Search and count lines:** `line = findLines(filled[0..cut], line,
   sink)` (`search.zig:188`).
6. **Carry:** the partial last line is copied to the front of the buffer
   (`search.zig:192`).

A file whose size is an exact multiple of the free buffer space ends with a
read that returns nothing; the carried bytes are searched then
(`search.zig:167`).

**Output.** The sink is `PrintLine` for the CLI: it formats `path:line[:content]`
into a per-file buffer. For the C API it is `Collect`, which stores each line's
number and text. Either way, a file's results are only reported (under one
mutex) once the file is known not to be binary. That is also why files never
interleave. The C API (`src/c_api.zig`, `include/ffs.h`) is a thin wrapper:
`ffs_search` compiles the regex if asked, calls `search.run` with a callback
output, and turns each hit into an `ffs_match` with NUL-terminated strings.

## The 16-byte loop (`src/match.zig`)

### Setup

```zig
const vec_len = std.simd.suggestVectorLength(u8) orelse 16;   // 16 on Apple M5 (NEON)
const Vec  = @Vector(vec_len, u8);                             // one 128-bit register
const Mask = @Int(.unsigned, vec_len);                         // u16: one bit per lane
```

`vec_len` is chosen at compile time for the target CPU. It is 16 on this
machine's aarch64/NEON (verified). 32- and 64-byte blocks (that is,
unrolling by 2 or 4) were measured and were slightly slower (Experiment 8).

For a term of length `n`:

```zig
const first: Vec = @splat(term[0]);       // 16 copies of the first byte
const last:  Vec = @splat(term[n - 1]);   // 16 copies of the last byte
const newline: Vec = @splat('\n');
const end = data.len - n + 1;             // valid start positions are [0, end)
var nl_acc: Vec = @splat(0);              // per-lane newline counters (u8)
```

### The main loop (`match.zig:73`)

Each iteration examines **16 candidate start positions** `i … i+15` at
once, and counts the newlines among bytes `i … i+15`:

```zig
outer: while (i + vec_len <= end) {
    const a: Vec = data[i..][0..vec_len].*;            // bytes at i … i+15
    const b: Vec = data[i + n - 1 ..][0..vec_len].*;   // bytes at i+n-1 … i+n+14
    const is_nl = a == newline;
    var mask: Mask = first.eqlMask(a) & last.eqlMask(b); // a == first, b == last
    while (mask != 0) : (mask &= mask - 1) {           // each set bit = one candidate
        const lane = @ctz(mask);                       // lowest set bit → leftmost candidate
        const pos = i + lane;
        if (eql(case, data[pos..][0..n], term)) {          // std.mem.eql
            line += flush(&nl_acc, &nl_blocks);        // newlines before this block
            line += @popCount(@bitCast(is_nl) & ((1 << lane) - 1));  // … and in data[i..pos]
            i = try report(...) orelse return line;    // match: jump to the next line
            continue :outer;
        }
    }
    nl_acc += @select(u8, is_nl, ones, zeros);         // count this block's newlines
    nl_blocks += 1;
    if (nl_blocks == 255) line += flush(&nl_acc, &nl_blocks);
    i += vec_len;                                      // no match here: next 16 positions
}
```

#### Finding candidates: first and last byte

This is the "first and last byte" filter, also known as Wojciech Muła's
"generic SIMD" substring search:

- **Load `a`** holds the bytes where the term would *start*.
- **Load `b`** holds the bytes where the term would *end*. It is the same
  window shifted by `n - 1`.
- `a == first` and `b == last` each give 16 booleans. `&` keeps only the
  positions where **both** ends match.
- `@ctz(mask)` (count trailing zeros) picks the leftmost candidate, and
  `mask &= mask - 1` clears that bit to move on to the next one.
- Only a surviving candidate pays for a full `std.mem.eql` against the
  term.

LLVM compiles the candidate test as `cmeq`, `cmeq`, `and`, then `umaxv`
(horizontal max) and a branch. It builds the actual bitmask only when some
lane is set, which is rare. NEON has no movemask instruction (unlike x86's
`pmovmskb`), so building a bitmask costs about 5 instructions (`and` with
bit weights, `ext`, `zip1`, `addv`, `fmov`). Avoiding it in the common case
matters.

#### Counting newlines without a bitmask

Line numbers come from the same loop and the same `a` load, but **not** via
a bitmask:

- `is_nl` is turned into 0/1 per lane with `@select` and added into
  `nl_acc`, 16 per-lane `u8` counters. On NEON this is a single vector
  subtract of the compare result.
- `flush` sums the counters into `line` (`@reduce(.Add)` over `u16` lanes)
  and clears them. It runs only:
  - when a match needs its line number;
  - every 255 blocks, before a `u8` lane could overflow;
  - once after the loop.
- On a match, the newlines *inside* the current block but before the match
  come from a bitmask of `is_nl`, built only then:
  `popCount(nl_mask & ((1 << lane) - 1))`.

An earlier version built the newline bitmask and ran `popCount` on every
block. That cost about 7 extra instructions per 16 bytes, and was about 20%
slower on identifier searches and 10% slower over all six benchmark terms
(Experiment 8).

**Bounds:** the condition `i + vec_len <= end` is equivalent to
`i + n - 1 + vec_len <= data.len`, so both 16-byte loads stay in range.

### Worked example

Term `PM_RESUME` (`n = 9`, first byte `P`, last byte `E`), block at `i = 0`.
Lane 0 is on the left (`↵` = newline, `⇥` = tab):

```
lane        0123456789abcdef
a           if (PM_RESUME) {          data[0..16]
a == 'P'    0000100000000000
b           ESUME) {↵⇥PAGE_S          data[8..24]  (shifted by n-1 = 8)
b == 'E'    1000100000000100
mask        0000100000000000          (a == 'P') & (b == 'E')
a == '\n'   0000000000000000          no newline in this block's a-window
```

- Lanes 0 and 13 have an `E` at the end position but no `P` at the start,
  so they are filtered out without any byte-by-byte work.
- Lane 4 survives: `@ctz(mask) = 4`, so `pos = 4`. `eql(data[4..13],
  "PM_RESUME")` is true. `flush` adds the newlines counted in earlier
  blocks (none here), plus zero newlines below lane 4. The line reported is
  `first_line`.
- `report` then jumps past the `↵` at byte 16, adds 1 to `line`, and the
  next block starts at `i = 17`.

For a typical identifier, nearly all 16-lane blocks have `mask == 0`. The
generated code per 16 bytes is then: `ldr` and `ldur` (2 loads), three
`cmeq`, `and`, `umaxv`, `fmov` and `tbz`, then `sub.16b` into the newline
counters, plus the 255-block counter check and the loop branch (verified in
the emitted assembly).

### Ignoring case (`-i`, `Byte` at `match.zig:114`)

`findLines` and `findLinesIgnoreCase` both call `find(comptime case, ...)`,
so each gets its own copy of the loop. In the case-sensitive copy,
`eqlMask(v)` is exactly `@bitCast(v == byte)` and `eql` is `std.mem.eql`:
the code above, unchanged.

In the case-insensitive copy, each end byte of the term is stored as its
lower-case form plus a `fold` vector, `0x20` if it is a letter and `0`
otherwise, and the block is compared as:

```zig
(v | fold) == lower      // one extra `orr` per load
```

Setting bit 5 turns `A`–`Z` (0x41–0x5A) into `a`–`z` (0x61–0x7A) and leaves
`a`–`z` as they are. No other byte ends up in 0x61–0x7A, so the compare is
exact: there are no extra candidates from the fold itself. For a non-letter
end byte such as `#` or `_`, `fold = 0` and it is a plain compare (`[` and
`{` differ only in bit 5, so they must not be folded). Candidates are
verified with `std.ascii.eqlIgnoreCase`.

Only ASCII is folded; multi-byte UTF-8 sequences must match exactly. The
newline counting is untouched.

The extra work per block is two `orr`s. Most of the measured 13% slowdown
in the microbenchmark comes from having more candidates: `p…e` is far more
common than `P…E` in C source (EXPERIMENTS.md, Experiment 10). An earlier version
compared each block with both the lower- and upper-case byte and ORed the
masks. It was 7% slower.

### Reporting a match: `report` (`match.zig:161`)

`report` is called with `line` already equal to the match's line number:

1. `indexOfScalarPos(data, pos, '\n')` (SIMD) finds the end of the line.
2. `sink.onLine(m)` is called with a `Match` (`match.zig:16`): `line`,
   `data`, `pos` (where the term starts) and `end` (the line's `\n`, or
   `data.len`). In ffs the sink prints `<root>/<path>:<line>` into the
   file's output buffer. With `--content` it prints
   `<root>/<path>:<line>:<content>`, where the content comes from
   `m.text()`.
3. If there was a newline, `line` goes up by 1 and the scan resumes at the
   start of the next line (`continue :outer`). Each line is therefore
   reported at most once, and the rest of a matching line is never scanned.
   Otherwise this was the last line, and `findLines` returns.

`Match.text()` finds the line's start **on demand**, by scanning back from
`pos` to the previous `\n` (`findScalarLast`, byte by byte), or to the
start of `data`. That is always a line start, because `search.zig` cuts
reads at newlines. The cost is paid only by sinks that call it, so the
default `path:line` output does no extra work. Even with `--content`, the
backward scan covers only the part of the line before the match.

### The tail (`match.zig:97`)

Once fewer than 16 candidate positions remain (`i + 16 > end`), a scalar
loop checks them one at a time: `data[i] == term[0]`, then `eql`. It counts
newlines as it goes. The last `n - 1` bytes can't start a match, but their
newlines still count, so they are added with `countScalar`
(`match.zig:106`). This happens once per `findLines` call, so it covers at
most 15 positions per 256 KiB read. For small files, which are most files,
it is the last 15 positions of the file.

### Correctness

`findLinesNaive` (`match.zig:171`) is the original pointer-walking version.
Two randomized tests check that both versions report exactly the same line
numbers **and** return the same line number after the data. For every
match, they also check `m.text()` against an independent oracle: the
corresponding line from splitting `data` on `\n`.

- `"SIMD search matches naive search"` (`match.zig:212`): 20,000 cases
  with data up to 600 bytes over `a`, `b`, `A`, `B` and `\n`, terms of 1–8 bytes and
  a random `first_line`. The small alphabet makes candidates, overlapping
  matches and block boundaries very frequent.
- `"... on long inputs"` (`match.zig:242`): 300 cases longer than 255
  blocks, with newline density 1/40, 1/2 or every byte. This exercises the
  periodic `flush`. Removing the flush makes this test fail with an integer
  overflow, which was verified.

Both randomized tests use upper- and lower-case `a`/`b` and check `find(.sensitive, ...)` and `find(.insensitive, ...)` against
`findLinesNaive` with the same `case`. `"ignore case folds ASCII letters
only"` (`match.zig:274`) checks `[`/`{` and a UTF-8 `Ö`. Disabling the
fold in the SIMD loop makes the first randomized test fail (verified).

Run them with `zig build test`.

## Regex (`-E`, `src/regex.zig`)

A regex search is a literal search plus a filter:

```
pattern ─► parse (tree) ─► compile (NFA program) ─► required literal
data    ─► match.findLines(literal) ─► candidate line ─► Pike VM: any match? ─► sink
```

1. **Parse.** A recursive-descent parser builds a tree of `Node`s. There
   is one node per construct: a byte set, `^`, `$`, `\b`, a concatenation,
   an alternation or a repetition. Every byte-consuming construct (a
   literal byte, `.`, `[...]`, `\d`, or a letter under `-i`) is a 256-bit
   byte set, so the VM has one kind of "consume" instruction.
2. **Compile** to a Thompson NFA program: `set`, `split`, `jmp`, `bol`,
   `eol`, `word_boundary` and `match`. `e{n,m}` is expanded into copies of
   `e`, and programs are capped at 10,000 instructions.
3. **Required literal.** This is the longest run of single bytes that every
   match must contain (`PM_` in `PM_[A-Z_]+`, `define` in
   `^\s*#\s*define\s+...`). Alternations and optional parts contribute
   nothing.
4. **Search.** If there is a literal, the SIMD `match.findLines` (or
   `findLinesIgnoreCase`) runs with it, and its sink is a `Filter` that
   passes a line on only if the VM accepts `m.text()`. Line numbering,
   chunking and output are all reused unchanged. Without a literal
   (`[0-9a-f]{16}`, `todo|fixme`), every line goes to the VM.
5. **Pike VM.** All NFA threads advance in lockstep, one byte at a time,
   and a new thread starts at every position (an unanchored search). A
   generation-stamped `seen` array keeps each instruction at most once per
   position. It stops at the first `match`: only "does this line match?"
   is needed, not where. The cost is O(line × program) with no
   backtracking, so `(a*)*b` is as safe as `ab`. The scratch arrays (`Vm`)
   live in each task's `Local`, sized once from the program.
6. **First-byte skip.** `first` is the set of bytes that can start a match
   (`t T f F` for `-i todo|fixme`). While no thread is alive, the VM jumps
   straight to the next such byte instead of starting a thread at every
   position. This roughly halves the time for patterns with no literal
   (EXPERIMENTS.md, Experiment 11). It is null when a match can start with
   an assertion or be empty.

Semantics are byte-oriented and ASCII: `.` is one byte, `\w`/`\s`/`\b`
are ASCII, and `-i` folds A–Z only. This matches ripgrep's `(?-u)` mode
exactly (EXPERIMENTS.md, Experiment 11).

**Tests:**
- table-driven syntax, error and literal-extraction cases;
- a randomized test (5,000 patterns × 20 lines, with and without `-i`)
  comparing the VM against a small backtracking matcher that walks the
  parse tree directly. It also asserts that every matching line contains
  the required literal, so the prefilter can never drop a match;
- a check that the prefiltered and every-line paths give the same lines
  and line numbers.

Three deliberate bugs (in `$`, `split` order and literal extraction) were
each caught.

## Cost per byte

How many times each byte is touched, for one read:

| Pass | Where | Step | Notes |
|---|---|---|---|
| NUL check | `search.zig:183` | SIMD (std) | every byte |
| match scan + newline count, `a` load | `match.zig:74` | 16 B | every byte, except skipped rest-of-line after a match |
| match scan, `b` load | `match.zig:75` | 16 B | same bytes, shifted by `n - 1` (mostly L1 hits) |
| candidate check | `match.zig:81` | `eql`, byte-wise | only where first and last byte both match |
| last newline | `search.zig:187` | **1 B, backwards** | stops at the last `\n`, usually within one line |
| carry | `search.zig:192` | memmove | only the partial last line |
| tail | `match.zig:97` | **1 B** | at most 15 positions per call |

So each byte is read about **twice** (NUL check, then the combined match
scan and newline count), each pass 16 bytes at a time. Byte-by-byte work is
limited to candidate checks, the tail and the backward newline search.

Even so, searching is a small part of the total. On the Linux kernel
source, ffs spends about 0.13 s of user time against about 2.8 s of system
time (EXPERIMENTS.md, Experiment 8).

## Ideas tried

| Idea | Result | Kept? |
|---|---|---|
| Count newlines in the scan loop, with a bitmask + popcount per block | about 5% faster than a separate `countScalar` pass | replaced by the next row |
| Count newlines in the scan loop, with per-lane vector counters | about 14% faster than the separate pass (20% on identifiers) | **yes** |
| Unroll: 32- or 64-byte blocks | 2–5% slower | no |
| Filter on the term's two rarest bytes (frequency table from Redis) | 3% slower overall; only rare uppercase identifiers gained | no |
| Fold the NUL check into the scan | not tried: the scan skips the rest of each matching line, so a NUL there would be missed | — |
| `-i`: compare with both the lower- and upper-case byte | 7% slower than OR `0x20` | replaced |
| mmap files ≥ 1 MiB (329 Linux files, 29% of bytes) | no measurable change | no: more code, crashes if a file is truncated while mapped |
| Short read = end of file | one fewer `read` per small file; no measurable time | **yes**: the code got simpler too |
| SIMD tail (overlapping last block) | not tried: at most 15 positions per call, and it complicates the newline counting | — |
