# Patterns

`PATTERN` is a regular expression, matched against one line at a time.

```console
$ ffs -n '^dictEntry \*dictFind(ByHash)?\(' src/dict.c
770:dictEntry *dictFindByHash(dict *d, const void *key, const uint64_t hash) {
814:dictEntry *dictFind(dict *d, const void *key)
```

## Syntax

| Pattern | Matches |
|:---|:---|
| `x` | the byte `x`; `\x` is `x` literally for any punctuation (`\.` `\(` `\*` `\\`) |
| `.` | any byte |
| `[abc]` `[^a-z]` | one byte from a class, or not in it; `\d` `\w` `\s` and `[:alpha:]`, `[:digit:]`, `[:upper:]`, … work inside |
| `\d` `\w` `\s` | an ASCII digit, a word byte (`[0-9A-Za-z_]`), white space; `\D` `\W` `\S` are the complements |
| `\t` `\r` `\xNN` | tab, carriage return, a byte in hex |
| `\b` | a word boundary |
| `^` `$` | the start and the end of the line |
| `*` `+` `?` | zero or more, one or more, zero or one; add `?` to make them lazy (`*?`) |
| `{n}` `{n,}` `{n,m}` | counted repetition |
| `a\|b` | either |
| `(…)` `(?:…)` | a group |
| `(?i)` `(?i:…)` | ignore case for the rest of the group, or inside it |

A pattern can't contain a newline (there's no `-U`). An invalid pattern is
an error, with exit status 2:

```console
$ ffs 'dict(Find' src; echo "exit $?"
ffs: regex parse error: UnbalancedParen in dict(Find
exit 2
```

## Options

| Option | Effect |
|:---|:---|
| `-F` | patterns are literal text: `ffs -F 'd->type->'` |
| `-e PATTERN` | one pattern; repeat for any of several (`-e DICT_OK -e DICT_ERR`) |
| `-w` | whole words only: the pattern with `\b` on each side |
| `-x` | whole lines only: the pattern with `^` and `$` |
| `-i` | ASCII letters match either case |
| `-S` | ignore case, unless the pattern has an upper-case letter |
| `-s` | match case exactly (the default; undoes `-i` and `-S`) |
| `-v` | report the lines that don't match |

```console
$ ffs -n -e DICT_OK -e DICT_ERR src/dict.h
24:#define DICT_OK 0
25:#define DICT_ERR 1
$ ffs -c -S 'lazyfree' src/lazyfree.c; ffs -c -S 'lazyFree' src/lazyfree.c
55
10
$ ffs -n -x '#define DICT_OK 0' src/dict.h
24:#define DICT_OK 0
```

`-i`, `\w` and `\d` are ASCII-only. `\b` (and so `-w`) treats non-ASCII
letters as word characters, as ripgrep does: in `返回ERR_PTR` there is no word
boundary before `E`.

## What makes a search fast

ffs looks at the pattern before searching, and takes the fastest route it
allows. Knowing the routes helps when a search is slow.

1. **No regex syntax at all** (`dictFind`, or anything with `-F`): a straight
   SIMD search, 16 bytes at a time. This is the fastest kind of search.
2. **A regex with fixed text in it** (`PM_[A-Z_]+`, `dictFind\(`): the SIMD
   search finds the lines that contain the text (`PM_`, `dictFind(`), and
   only those lines go to the regex engine. When there are several pieces
   to choose from, ffs takes the one that should be rarest in source code.
3. **Alternatives with fixed text** (`dictFind|dictAdd|dictDelete`,
   `func (cancel|launch)`): the same, with up to 16 pieces of text searched
   for at once. When the pattern is nothing but alternatives of plain text,
   the regex engine is skipped altogether.
4. **No fixed text, but a run of one class** (`[0-9a-f]{16}`,
   `[A-Za-z_]{30,}`, `\d{5,}`): a SIMD scan finds the lines with a long
   enough run (16 hex digits in a row), and only those go further. When the
   pattern is just the run, nothing else is checked.
5. **Neither** (`\d+`, `^\s*$`): the regex
   engine reads every byte, as a DFA built while it searches, one table
   lookup per byte.

The regex engine is a lazy DFA, with a Pike VM behind it. Patterns with
`\b` (and so `-w`) can't use the DFA and run on the VM, which steps every
possible match at once and is several times slower per line. That only
shows when the fixed text is common: `-w dictFind` is fast, but
`\b[a-z]+_[a-z]+\b`, whose only fixed text is `_`, sends most lines to the
VM and is about 4x slower than ripgrep. Within routes 2 and 3, a very
common piece of text slows things down the same way: in
`dictFind|struct [a-z]+ \{`, every line with `struct ` is a candidate. If you
can, spell out a rarer part.

## The PCRE2 build

`zig build -Dpcre2=true` links the system's PCRE2 (`libpcre2-8`) and lets its
JIT compiler take over where the DFA can't: patterns whose DFA would need
too many states, and `-o`. The syntax and the results stay the same: ffs
still parses every pattern itself, and patterns with `\b` keep the built-in
engine, whose `\b` matches ripgrep's. Since the DFA, the two builds are
within a few percent of each other; the README has the numbers.
