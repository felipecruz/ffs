# ffs documentation

ffs searches files for a pattern, with ripgrep's command line: the same
flags, the same defaults and the same output, for the flags it has. If you
know `rg`, you know ffs; these pages are for the details.

![ffs searching the Linux kernel source, and ripgrep for comparison](demo.gif)

```console
$ ffs -n -w 'dictFind|dictAdd|dictDelete' src/dict.h
125: * dictAdd, dictFind, and other functions against the dictionary even while
208:int dictAdd(dict *d, void *key, void *val);
215:int dictDelete(dict *d, const void *key);
221:dictEntry * dictFind(dict *d, const void *key);
```

| Page | What's in it |
|:---|:---|
| [Patterns](patterns.md) | Regex syntax, `-F` `-e` `-w` `-x` `-i` `-S`, and how a pattern decides how fast a search is |
| [Files](files.md) | Which files get searched: paths, standard input, hidden files, ignore files, `-g` globs, `--files` |
| [Output](output.md) | The output format, context lines, `-o` `-c` `-l` `-q` `-m` `-v`, exit status |
| [ffs and ripgrep](ripgrep.md) | What's the same, what's missing, where results can differ, and using ffs as `rg` |
| [Examples](examples.md) | About 30 searches agents run, with their real output |
| [`man ffs`](ffs.1) | Every option, as a man page |

## Install

### From a release

Each [release](https://github.com/felipecruz/ffs/releases) has an archive
per platform, holding the `ffs` binary, the man page, the C library with its
header, and the README and CHANGELOG:

| Platform | Archive |
|:---|:---|
| Linux, x86-64 | `ffs-VERSION-x86_64-linux-gnu.tar.gz`, or `x86_64-linux-musl` for a static binary |
| Linux, ARM64 | `ffs-VERSION-aarch64-linux-gnu.tar.gz` |
| macOS, Apple silicon | `ffs-VERSION-aarch64-macos.tar.gz` |
| macOS, Intel | `ffs-VERSION-x86_64-macos.tar.gz` |
| Windows, x86-64 | `ffs-VERSION-x86_64-windows.zip` |

To download one, check it against the release's `SHA256SUMS`, and install
it in `~/.local`:

```sh
v=0.0.8 t=x86_64-linux-gnu
url=https://github.com/felipecruz/ffs/releases/download/v$v
curl -LO "$url/ffs-$v-$t.tar.gz" -LO "$url/SHA256SUMS"
grep " ffs-$v-$t.tar.gz\$" SHA256SUMS | sha256sum -c    # macOS: shasum -a 256 -c
tar xzf "ffs-$v-$t.tar.gz"
mkdir -p ~/.local/bin ~/.local/share/man/man1
cp "ffs-$v-$t/ffs" ~/.local/bin/
cp "ffs-$v-$t/ffs.1" ~/.local/share/man/man1/
```

With `~/.local/bin` on your `PATH`, `man ffs` finds the page too: `man`
looks in `../share/man` next to each directory on the `PATH`. On Windows,
unzip the archive and put `ffs.exe` in a directory on the `PATH`.

### From source

ffs builds with Zig 0.17 and has no dependencies:

```sh
zig build                       # zig-out/release/ffs, zig-out/share/man/man1/ffs.1
cp zig-out/release/ffs ~/.local/bin/
MANPATH="$PWD/zig-out/share/man:" man ffs
```

`zig build -Dpcre2=true` builds a variant that uses the system's PCRE2 for
faster regexes (see [Patterns](patterns.md#the-pcre2-build)).

## Every example here is tested

The examples in these pages are not typed in by hand. `tests/docs.sh` runs
each `$ ffs ...` line inside the Redis 8.0.2 source and checks that the
output is what the page shows; CI does the same on every push. It also checks
that every flag ffs accepts is in the man page and in `ffs --help`. After
changing ffs, `tests/docs.sh --update` rewrites the outputs from real runs.
The terminal demo above is recorded with
[vhs](https://github.com/charmbracelet/vhs) from `demo.tape`
(`docs/demo.sh`).

Lines can come out in another order than shown: ffs searches files in
parallel, as ripgrep does. A block ending in `...` was cut short.
