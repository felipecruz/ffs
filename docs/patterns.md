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
   only those lines go to the regex engine.
3. **Alternatives with fixed text** (`dictFind|dictAdd|dictDelete`,
   `func (cancel|launch)`): the same, with up to 16 pieces of text searched
   for at once. When the pattern is nothing but alternatives of plain text,
   the regex engine is skipped altogether.
4. **No fixed text** (`[0-9a-f]{16}`, `\d+`): every line goes through the
   regex engine. This is the slow case, where ripgrep is several times
   faster (see the README's tables).

Within route 3, a very common piece of text slows things down: in
`dictFind|struct [a-z]+ \{`, every line with `struct ` is a candidate. If you
can, spell out a rarer part.

## The PCRE2 build

`zig build -Dpcre2=true` links the system's PCRE2 (`libpcre2-8`) and lets its
JIT compiler do the regex engine's work in routes 2–4. The syntax and the
results stay the same: ffs still parses every pattern itself, and patterns
with `\b` keep the built-in engine, whose `\b` matches ripgrep's. It closes
most of the gap in route 4 and wins where route 3 has a common piece of
text; the README has the numbers.
