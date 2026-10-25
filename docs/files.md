# Files

## What gets searched

Each `PATH` is a directory (searched recursively), a file, or `-` for
standard input. Any number of them can be given:

```console
$ ffs -n 'aeCreateEventLoop' src/ae.h src/server.c
src/ae.h:96:aeEventLoop *aeCreateEventLoop(int setsize);
src/server.c:2753:    server.el = aeCreateEventLoop(server.maxclients+CONFIG_FDSET_INCR);
```

With no `PATH`, ffs searches standard input if something is piped in, and the
current directory otherwise:

```console
$ ffs --files src | ffs -c '\.c$'
119
```

A path that can't be read is reported, the rest are still searched, and the
exit status is 2:

```console
$ ffs -c dictFind src/nope.c src/dict.h; echo "exit $?"
ffs: src/nope.c: No such file or directory (os error 2)
src/dict.h:5
exit 2
```

## How paths are printed

Paths in the output are the `PATH` you gave, then the path inside it:

| You run | ffs prints |
|:---|:---|
| `ffs x` | `src/server.c` |
| `ffs x .` | `./src/server.c` |
| `ffs x src` or `ffs x src/` | `src/server.c` |
| `ffs x src/server.c` | no path: one file is searched |

## What a directory search skips

Inside a directory, ffs leaves out, as ripgrep does:

- **Hidden files and directories**, whose names start with `.`
  (`--hidden` or `-.` includes them).
- **What ignore files list**: `.gitignore` (inside a git repository),
  `.ignore` and `.rgignore` in each directory and in the directories above
  the search root, and `.git/info/exclude`. `--no-ignore` turns them all off,
  `--no-ignore-vcs` only the git ones.
- **Binary files**, meaning any file with a NUL byte (`-a` searches them).
- **Symbolic links** and special files.

Files named on the command line are always searched.

```console
$ ffs --files | wc -l; ffs --files --hidden | wc -l; ffs --files -uu | wc -l
1635
1703
1706
```

`-u` stacks: `-u` is `--no-ignore`, `-uu` adds `--hidden`, `-uuu` adds `-a`.

### Ignore files

Ignore files use git's syntax: `build` leaves out anything named `build` at
any depth, `/build` only at the top, `build/` only directories, `*.log` any
`.log` file, `**/gen/*.c` and `docs/**` whole subtrees, and `!keep.log`
brings something back. The file nearest to a path wins; within one
directory `.rgignore` beats `.ignore`, which beats `.gitignore`.

## Choosing files with `-g`

`-g GLOB` keeps only the files that match; `-g '!GLOB'` leaves out the files
and directories that match. Globs use the same syntax as ignore files, plus
`{a,b}`, and several can be given; the last one that matches a path decides.

```console
$ ffs --files -g '*.{h,tcl}' -g '!tests/unit/**' -g '!deps/**' | sort | head -4
modules/vector-sets/hnsw.h
src/adlist.h
src/ae.h
src/anet.h
```

Things worth knowing:

- **A glob without `/` matches the file name** at any depth (`*.c`,
  `Makefile`); **one with `/` matches the path from the current directory**,
  as ripgrep does: from the Redis root, `-g 'src/*.h'` works with `ffs x` and
  `ffs x src`, while `-g '*.h'` works anywhere.
- **A matching glob beats the other rules** for the path it matches: it
  brings back an ignored or hidden file. Directories are checked on the way
  down too, so a glob only reaches into an ignored or hidden directory if it
  matches the directory itself: `-g '*.yml'` doesn't find
  `.github/dependabot.yml` without `--hidden`, because `.github` doesn't
  match `*.yml`.
- **Including globs only filter files**, never directories: `-g '*.h'` still
  looks in every directory for `.h` files.

```console
$ ffs --files -g '.github/workflows/c*'
$ ffs --files --hidden -g '.github/workflows/c*'
.github/workflows/ci.yml
.github/workflows/codecov.yml
.github/workflows/codeql-analysis.yml
.github/workflows/coverity.yml
```

## Choosing files by type with `-t`

`-t TYPE` keeps only files of a type, by name: ripgrep's table of types
(`ffs --type-list`), such as `c` (`*.[chH]`, …), `py` or `make`
(`Makefile`, `*.mk`, …). `-T TYPE` leaves a type out, and both can be
repeated. `--iglob` is `-g` ignoring case.

```console
$ ffs --files -t make -d 2 | sort
Makefile
deps/Makefile
modules/Makefile
modules/common.mk
src/Makefile
$ ffs -c -t tcl lazyfree tests | sort -t: -k2 -rn | head -3
tests/unit/lazyfree.tcl:27
tests/unit/moduleapi/test_lazyfree.tcl:4
tests/unit/functions.tcl:4
```

As in ripgrep, a file named on the command line is searched whatever its
type, a matching `-g` glob decides on its own, and a selected type brings
back a hidden file the way a matching glob does.

## Listing files with `--files`

`--files` prints every file a search would look at, and takes no pattern. With
`-g` it replaces `find`:

```console
$ ffs --files -g '*README*' -g Makefile -d 2
Makefile
README.md
tests/README.md
deps/Makefile
deps/README.md
modules/Makefile
src/Makefile
```

`-d N` (`--max-depth`) stops N levels down; files directly in a `PATH` are at
depth 1.
