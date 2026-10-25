# ffs and ripgrep

ffs takes ripgrep's command line for the options it has, and prints the same
thing: the same lines, paths, separators and exit status.
`tests/compat.sh` checks this by running 124 command lines through both tools
and comparing their output; CI runs it on Linux and macOS.

## Options

| | Options |
|:---|:---|
| **Same as ripgrep** | `-e` `-F` `-i` `-S` `-s` `-w` `-x` `-v` · `-n` `-N` `-H` `-I` `-o` `-c` `-l` `-q` `-m` `-A` `-B` `-C` · `--json` `-0`/`--null` `-M`/`--max-columns` · `--files` `-g` `--iglob` `-t`/`--type` `-T`/`--type-not` `--type-list` `--hidden` `--no-hidden` `--no-ignore` `--no-ignore-vcs` `-u` `-a` `-d` · `-j` `-h` `-V` |
| **Accepted, no effect** | `--color`, `--heading`, `--no-heading`, `--no-messages` |
| **Not there** | `--sort`, `--type-add`, `-r` (replace), `-U` (multi-line), `-L` (follow links), `-P`, `-z`, `--stats`, `--column`, `-b`, `--vimgrep`, … |

An option ffs doesn't have is an error (exit status 2), never silently
ignored, so a script can't get wrong results from it; unless `FFS_RG` names
a ripgrep binary, which then runs the whole command line instead (below).

`-t` uses ripgrep 15.2's table of file types (`ffs --type-list`). `--json`
prints the same messages as ripgrep, field for field; only the timings in
`end` and `summary` differ.

## Where results can differ

- **Case and Unicode.** `-i` and `\w` are ASCII-only in ffs; ripgrep's are
  Unicode-aware, so `rg -i 'é'` also finds `É` and ffs doesn't.
- **Binary files.** ffs skips a file as soon as it sees a NUL byte; ripgrep
  prints the matches it found before the NUL, then a warning.
- **A terminal.** On a terminal ripgrep groups matches under file headings,
  in color; ffs prints the same `path:line:text` lines as in a pipe.
- **The global git ignore file** (`core.excludesFile`) is not read.
- **Binary files under `--json`.** ripgrep reports the matches before the
  NUL and the NUL's offset (`binary_offset`); ffs prints nothing for the
  file.

## Using ffs as `rg`

Since the command line is the same, anything that runs `rg` can run ffs
instead, such as a coding agent's shell commands. A link named `rg` ahead of
the real one on `PATH` does it:

```sh
mkdir -p ~/.local/ffs-as-rg
ln -s "$(command -v ffs)" ~/.local/ffs-as-rg/rg
PATH="$HOME/.local/ffs-as-rg:$PATH" codex   # or claude, a shell, a script
```

Error messages still start with `ffs:`. Tools that bundle their own ripgrep,
such as an editor's search box, aren't affected, unless they can be told to
use the `rg` on `PATH`.

For a tool that runs every kind of rg command line, set `FFS_RG` to the real
ripgrep too. ffs runs what it can and hands it the rest, unchanged: `-U`
(multi-line), `--sort`, `-L`, and any flag ffs doesn't know.

### Claude Code

Claude Code's Grep and Glob tools run a ripgrep bundled with it, unless
`USE_BUILTIN_RIPGREP=0`, when they run the `rg` on `PATH`. With the link
above:

```sh
FFS_RG=/usr/bin/rg USE_BUILTIN_RIPGREP=0 PATH="$HOME/.local/ffs-as-rg:$PATH" claude
```

The Grep tool always passes `--hidden`, `--glob '!.git'` (and the other
VCS directories) and `--max-columns 500`, then `-l --null` for file names,
`-c -H --null` for counts, or `--json -n` for matching lines, which it reads
back as JSON. ffs runs all of these itself; `tests/compat.sh` has them.
A multi-line search (`-U --multiline-dotall`), the Glob tool
(`--sort=modified`) and the file index (`--follow`) go to `FFS_RG`.

What agents actually run, and so what ffs was built for, is in
[SEARCH_CMDs.md](https://github.com/felipecruz/ffs/blob/main/SEARCH_CMDs.md): 3,614 shell commands from 141 agent
jobs, a third of them searches.
