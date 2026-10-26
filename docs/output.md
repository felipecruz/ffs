# Output

## Matching lines

Each matching line is printed as `path:line:text`:

```console
$ ffs -n 'aeCreateEventLoop' src
src/ae.c:47:aeEventLoop *aeCreateEventLoop(int setsize) {
src/ae.h:96:aeEventLoop *aeCreateEventLoop(int setsize);
src/iothread.c:568:        t->el = aeCreateEventLoop(server.maxclients+CONFIG_FDSET_INCR);
src/server.c:2753:    server.el = aeCreateEventLoop(server.maxclients+CONFIG_FDSET_INCR);
src/redis-benchmark.c:989:    thread->el = aeCreateEventLoop(1024*10);
src/redis-benchmark.c:1711:    config.el = aeCreateEventLoop(1024*10);
```

- The **path** is left out when the only `PATH` is a file or standard
  input. `-H` always prints it, `-I` never does.
- The **line number** comes with `-n`, or by default when the output is a
  terminal; `-N` turns it off. Agents run ffs in a pipe, so they pass `-n`.
- Files come out in no fixed order, since several are searched at once (as
  in ripgrep), but the lines of one file are always together and in order.
  Pipe through `sort` when order matters.
- There are no colors or headings; `--color` and `--no-heading` are accepted
  and do nothing, so scripts written for ripgrep still run.

## Context lines

`-A N`, `-B N` and `-C N` add N lines after, before, or around each match.
Context lines use `-` where matching lines use `:`, and `--` separates
groups of lines that aren't next to each other:

```console
$ ffs -n -B1 -A2 'void serverLogRaw\(' src/server.c
112- * serverLog() is to prefer. */
113:void serverLogRaw(int level, const char *msg) {
114-    const int syslogLevelMap[] = { LOG_DEBUG, LOG_INFO, LOG_NOTICE, LOG_WARNING };
115-    const char *c = ".-*#";
```

## Other things to print

| Option | Prints |
|:---|:---|
| `-o` | each match on its own line, not the whole line |
| `-c` | `path:count`, the number of matching lines, for each file with a match |
| `-l` | the paths of the files with a match |
| `-q` | nothing; the exit status says if something matched |
| `-m N` | at most N matching lines per file |
| `-v` | the lines that don't match (with `-c`: how many) |
| `--json` | ripgrep's JSON Lines messages for the matching lines, for programs |
| `--null` (`-0`) | a NUL byte after each path instead of `:`, or of the newline with `-l` |
| `-M N` | `[Omitted long matching line]` for lines longer than N bytes (0: no limit) |

As in ripgrep, `--json`, `-c`, `-l` and `--files` are one setting and the
last one given wins: `-l --json` prints JSON, `--json -l` paths. `-o` and
`-q` don't change it, and `-q --json` still prints the `summary` message.

```console
$ ffs -o -N 'CVE-[0-9]{4}-[0-9]+' 00-RELEASENOTES | sort -u | tail -3
CVE-2024-51741
CVE-2025-21605
CVE-2025-27151
$ ffs -c 'serverLog\(LL_WARNING' src | sort -t: -k2 -rn | head -3
src/replication.c:66
src/debug.c:60
src/server.c:54
$ ffs -m1 -n '#include' src/dict.c src/ae.c
src/dict.c:16:#include "fmacros.h"
src/ae.c:13:#include "ae.h"
$ ffs -v -c '^\s*$' src/dict.c
1994
```

## Exit status

| Status | Meaning |
|:---:|:---|
| 0 | something matched (with `--files`: some file was listed) |
| 1 | nothing matched |
| 2 | an error: an unknown option, an invalid pattern, or a path that couldn't be read |

Scripts can test it directly; errors go to standard error, and the other
paths are still searched (see [Files](files.md#what-gets-searched)):

```console
$ ffs -q REDIS_VERSION src/version.h && echo found
found
$ ffs zz_no_such_symbol src; echo "exit $?"
exit 1
```
