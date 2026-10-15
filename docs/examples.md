# Examples

Searches agents run while finding their way around a repository, here the
Redis 8.0.2 source, with their real output: `tests/docs.sh` runs every one
of them and checks the output on every push. Lines can come out in another
order, since ffs searches files in parallel; `...` marks a cut. Each command
is what you would type with `rg`, with `ffs` in its place.

Contents:

- [Finding your way around a repository](#finding-your-way-around-a-repository)
- [Finding code](#finding-code)
- [Pulling facts out of documents](#pulling-facts-out-of-documents)
- [Counting and listing](#counting-and-listing)
- [Pipelines](#pipelines)

## Finding your way around a repository

What agents do first in almost every job: list the files that matter instead of reading the directory tree.

**Build files and docs, two levels deep**

```console
$ ffs --files -g '*README*' -g Makefile -g AGENTS.md -d 2
Makefile
README.md
modules/Makefile
tests/README.md
deps/Makefile
deps/README.md
src/Makefile
```

**Instructions and CI config live in hidden folders, so add --hidden (Redis has no AGENTS.md)**

```console
$ ffs --files --hidden -g '*instructions*' -g CLAUDE.md -g AGENTS.md -g '.github/workflows/*'
.github/workflows/ci.yml
.github/workflows/codecov.yml
.github/workflows/codeql-analysis.yml
.github/workflows/coverity.yml
...
```

**Every C file under `src/`, minus the modules**

```console
$ ffs --files -g '*.c' -g '!src/modules/**' src | wc -l
111
```

**Test files, by a name guessed from the task**

```console
$ ffs --files -g '*test*' src
src/memtest.c
src/testhelp.h
src/commands/latency-latest.json
src/commands/pfselftest.json
```

**What `.gitignore` and hidden files keep out**

```console
$ ffs --files | wc -l; ffs --files -uu | wc -l
1635
1706
```

## Finding code

Most searches look for a symbol whose exact name the agent doesn't know yet, so they try several names at once.

**Several guesses in one call**

```console
$ ffs -n 'dictFind|dictAdd|dictDelete' src/dict.h
125: * dictAdd, dictFind, and other functions against the dictionary even while
208:int dictAdd(dict *d, void *key, void *val);
209:dictEntry *dictAddRaw(dict *d, void *key, dictEntry **existing);
210:dictEntry *dictAddNonExistsByHash(dict *d, void *key, const uint64_t hash);
211:void *dictFindPositionForInsert(dict *d, const void *key, dictEntry **existing);
213:dictEntry *dictAddOrFind(dict *d, void *key);
215:int dictDelete(dict *d, const void *key);
221:dictEntry * dictFind(dict *d, const void *key);
222:dictEntry *dictFindByHash(dict *d, const void *key, const uint64_t hash);
223:dictEntry *dictFindByHashAndPtr(dict *d, const void *oldptr, const uint64_t hash);
```

**Jump to a declaration**

```console
$ ffs -n 'struct redisServer \{|struct client \{' src/server.h
1279:typedef struct client {
1698:struct redisServer {
```

**A brace list of files (the shell expands it)**

```console
$ ffs -n 'aeCreateEventLoop|aeDeleteEventLoop' src/{ae.h,server.c}
src/ae.h:96:aeEventLoop *aeCreateEventLoop(int setsize);
src/ae.h:97:void aeDeleteEventLoop(aeEventLoop *eventLoop);
src/server.c:2753:    server.el = aeCreateEventLoop(server.maxclients+CONFIG_FDSET_INCR);
src/server.c:7560:    aeDeleteEventLoop(server.el);
```

**Read a whole function in one step**

```console
$ ffs -n -A6 '^dictEntry \*dictFind\(' src/dict.c
814:dictEntry *dictFind(dict *d, const void *key)
815-{
816-    if (dictSize(d) == 0) return NULL; /* dict is empty */
817-    const uint64_t hash = dictHashKey(d, key, d->useStoredKeyApi);
818-    return dictFindByHash(d,key,hash);
819-}
820-
```

**Context before and after**

```console
$ ffs -n -B2 -A3 'void serverLogRaw\(' src/server.c
111-/* Low level logging. To use only for very big messages, otherwise
112- * serverLog() is to prefer. */
113:void serverLogRaw(int level, const char *msg) {
114-    const int syslogLevelMap[] = { LOG_DEBUG, LOG_INFO, LOG_NOTICE, LOG_WARNING };
115-    const char *c = ".-*#";
116-    FILE *fp;
```

**Spelled-out case variants**

```console
$ ffs -n 'lazyfree|lazyFree|LazyFree' src -g '*.h'
src/bio.h:43:void bioCreateLazyFreeJob(lazy_free_fn free_fn, int arg_count, ...);
src/server.h:1142:    monotime lazyfreeStartTime;
src/server.h:2198:    int lazyfree_lazy_eviction;
src/server.h:2199:    int lazyfree_lazy_expire;
...
```

**Or ignore case**

```console
$ ffs -n -i 'LAZYFREE_THRESHOLD' src
src/lazyfree.c:181:#define LAZYFREE_THRESHOLD 64
src/lazyfree.c:190:    if (free_effort > LAZYFREE_THRESHOLD && obj->refcount == 1) {
src/lazyfree.c:221:    if (tracking->numnodes > LAZYFREE_THRESHOLD) {
src/lazyfree.c:233:    if (errors->numnodes > LAZYFREE_THRESHOLD) {
src/lazyfree.c:244:    if (dictSize(lua_scripts) > LAZYFREE_THRESHOLD) {
src/lazyfree.c:254:    if (functionsLibCtxFunctionsLen(functions_lib_ctx) > LAZYFREE_THRESHOLD) {
src/lazyfree.c:265:    if (listLength(blocks) > LAZYFREE_THRESHOLD ||
src/lazyfree.c:266:        raxSize(index) > LAZYFREE_THRESHOLD)
```

**Smart case: lower case ignores case, upper case doesn't**

```console
$ ffs -c -S 'lazyfree' src/lazyfree.c; ffs -c -S 'lazyFree' src/lazyfree.c
55
10
```

**Whole words only**

```console
$ ffs -w -n dictSize src/dict.h
179:#define dictSize(d) ((d)->ht_used[0]+(d)->ht_used[1])
```

**Fixed strings, no regex**

```console
$ ffs -n -F 'd->type->' src/dict.c | head -3
78:    if (d->useStoredKeyApi && d->type->storedKeyCompare)
79:        return d->type->storedKeyCompare;
80:    if (d->type->keyCompare)
```

**Several patterns with -e**

```console
$ ffs -n -e DICT_OK -e DICT_ERR src/dict.h
24:#define DICT_OK 0
25:#define DICT_ERR 1
```

**The whole repository, `.gitignore` respected**

```console
$ ffs -n 'TODO' -g '!deps/**'
tests/test_helper.tcl:490:    # TODO: print the status, exit with the right exit code.
tests/assets/test_cli_hint_suite.txt:28:# TODO: The following hints end with an unbalanced "]" which shouldn't be there.
src/dict.h:66:    /* TODO: Add a 'keys_are_even' flag and use a similar optimization if that
...
```

## Pulling facts out of documents

Markdown headings, version strings and IDs, treated like a small database.

**A document's outline**

```console
$ ffs -n '^#+ ' README.md | head -5
5:### What is Redis?
29:### What is Redis Open Source?
38:### Redis Open Source - binary distributions
50:### Using Redis with redis-cli
74:### Using Redis with Redis Insight
```

**Only the match, not the line**

```console
$ ffs -o 'REDIS_VERSION "[0-9.]+"' src/version.h
REDIS_VERSION "8.0.2"
```

**The latest IDs of some kind**

```console
$ ffs -o -N 'CVE-[0-9]{4}-[0-9]+' 00-RELEASENOTES | sort -u | tail -3
CVE-2024-51741
CVE-2025-21605
CVE-2025-27151
```

**Count entries**

```console
$ ffs -c '^### ' README.md
23
```

**Did my edit land? (exit status only)**

```console
$ ffs -q 'REDIS_VERSION' src/version.h && echo yes
yes
```

## Counting and listing

**Who logs the most warnings**

```console
$ ffs -c 'serverLog\(LL_WARNING' src | sort -t: -k2 -rn | head -3
src/replication.c:66
src/debug.c:60
src/server.c:54
```

**Which files call a function**

```console
$ ffs -l aeCreateFileEvent src
src/ae.c
src/ae.h
src/iothread.c
src/bio.c
src/replication.c
src/module.c
src/sentinel.c
src/tls.c
src/server.c
src/rdb.c
src/redis-benchmark.c
src/socket.c
```

**The first match per file only**

```console
$ ffs -m1 -n '#include' src/dict.c src/ae.c
src/dict.c:16:#include "fmacros.h"
src/ae.c:13:#include "ae.h"
```

**Non-blank lines (inverted match)**

```console
$ ffs -v -c '^\s*$' src/dict.c
1994
```

**Nothing found: exit status 1, as in rg**

```console
$ ffs zz_no_such_symbol src; echo "exit $?"
exit 1
```

**A path that doesn't exist: an error, exit status 2**

```console
$ ffs -c dictFind src/nope.c src/dict.h; echo "exit $?"
ffs: src/nope.c: No such file or directory (os error 2)
src/dict.h:5
exit 2
```

## Pipelines

With no path and something piped in, ffs searches standard input, like rg.

**Narrow down a file list**

```console
$ ffs --files src | ffs -c '\.c$'
119
```

**Leave some files out of a result**

```console
$ ffs -l aeCreateFileEvent src | ffs -v '^src/ae'
src/iothread.c
src/bio.c
src/replication.c
src/module.c
src/sentinel.c
src/tls.c
src/server.c
src/socket.c
src/rdb.c
src/redis-benchmark.c
```

**Search another command's output**

```console
$ ls src/modules | ffs -n 'Makefile|\.c$'
1:helloacl.c
2:helloblock.c
3:hellocluster.c
4:hellodict.c
5:hellohook.c
6:hellotimer.c
7:hellotype.c
8:helloworld.c
9:Makefile
```

**Search the files a first search found**

```console
$ ffs -l 'rewriteAppendOnlyFile' src | ffs -v 'aof'
src/server.c
src/server.h
```
