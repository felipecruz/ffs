# ffs and ripgrep

ffs takes ripgrep's command line for the options it has, and prints the same
thing: the same lines, paths, separators and exit status.
`tests/compat.sh` checks this by running 97 command lines through both tools
and comparing their output; CI runs it on Linux and macOS.

## Options

| | Options |
|:---|:---|
| **Same as ripgrep** | `-e` `-F` `-i` `-S` `-s` `-w` `-x` `-v` · `-n` `-N` `-H` `-I` `-o` `-c` `-l` `-q` `-m` `-A` `-B` `-C` · `--files` `-g` `--hidden` `--no-hidden` `--no-ignore` `--no-ignore-vcs` `-u` `-a` `-d` · `-j` `-h` `-V` |
| **Accepted, no effect** | `--color`, `--heading`, `--no-heading`, `--no-messages` |
| **Not there** | `-t`/`--type`, `--sort`, `--json`, `-r` (replace), `-U` (multi-line), `-L` (follow links), `-P`, `--iglob`, `-z`, `--stats`, `--column`, `-b`, `--vimgrep`, … |

An option ffs doesn't have is an error (exit status 2), never silently
ignored, so a script can't get wrong results from it.

## Where results can differ

- **Case and Unicode.** `-i` and `\w` are ASCII-only in ffs; ripgrep's are
  Unicode-aware, so `rg -i 'é'` also finds `É` and ffs doesn't.
- **Binary files.** ffs skips a file as soon as it sees a NUL byte; ripgrep
  prints the matches it found before the NUL, then a warning.
- **A terminal.** On a terminal ripgrep groups matches under file headings,
  in color; ffs prints the same `path:line:text` lines as in a pipe.
- **The global git ignore file** (`core.excludesFile`) is not read.

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
such as an editor's search box, aren't affected.

What agents actually run, and so what ffs was built for, is in
[SEARCH_CMDs.md](https://github.com/felipecruz/ffs/blob/main/SEARCH_CMDs.md): 3,614 shell commands from 141 agent
jobs, a third of them searches.
