#!/usr/bin/env bash
# ffs as a drop-in for ripgrep: runs the same command lines through both on
# a small tree and compares stdout and the exit status. Covers the searches
# agents actually run (SEARCH_CMDs.md). Output order isn't deterministic in
# either tool when several files match, so those outputs are sorted first.
#
# Usage: tests/compat.sh [path/to/ffs]    (needs rg on PATH)
set -u
FFS=$(realpath "${1:-zig-out/release/ffs}")
command -v rg >/dev/null || { echo "compat.sh: rg not found" >&2; exit 2; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q
mkdir -p a/b a/build .hid build Sources/App Tests docs
printf 'one foo\ntwo\nfoo three foo\n' > a/x.txt
cp a/x.txt a/b/y.md
cp a/x.txt .hid/z.txt
cp a/x.txt build/w.txt
cp a/x.txt a/build/q.txt
cp a/x.txt top.txt
printf '1\nm\n3\n4\n5\n6\nm\n8\n' > c.txt
printf 'struct JobStore {\n  func cancel() {}\n  func launch() {}\n}\nlet autoPilot = 1\nlet AutoPilot = 2\n' > Sources/App/Job.swift
printf 'import XCTest\nfunc testCancel() {}\n' > Tests/JobTests.swift
printf '# Roadmap\n## v1\n- [x] **F101 — first\n- [ ] **F102 — second\n## v2\n- [ ] **F239 — later\n' > ROADMAP.md
printf 'Executed 13 tests, with 0 failures\nerror: boom\nTest Case x failed\n' > test.log
printf 'build\n/top-ignored.txt\n*.log\n!keep.log\n' > .gitignore
echo foo > top-ignored.txt
echo foo > keep.log
printf 'secret\n' > docs/.ignore
printf 'foo secret\n' > docs/secret
printf 'foo public\n' > docs/public
printf 'bin\0ary foo\n' > binary.dat
printf 'esc foo\t\x01"q"\\b\x1b\r end\n' > esc.txt
# A '!' line beats the hidden check, as in the Linux kernel's .gitignore.
mkdir -p k/sub
printf '.*\n!.gitignore\n' > k/.gitignore
printf 'x\n' > k/sub/.gitignore
printf 'foo\n' > k/sub/.hidden

pass=0
fail=0
RG=$(command -v rg)
# Output filters: NUL bytes as newlines (the shell drops NULs), and --json
# with its timings taken out, the one part that can't be the same.
nul() { tr '\0' '\n'; }
# ripgrep before 15 also counts files without a match in the summary's
# searches and bytes_searched; ffs counts as 15 does.
rg_major=$("$RG" --version | sed -nE '1s/^ripgrep ([0-9]+).*/\1/p')
if [ "${rg_major:-15}" -ge 15 ]; then old_stats=; else old_stats='s/"(bytes_searched|searches)":[0-9]+/"\1":0/g;'; fi
json() { sed -E "$old_stats"'s/"elapsed(_total)?":\{[^}]*\}/"elapsed\1":{}/g'; }
# check [sort|raw] [--stdin TEXT] [--cd DIR] [--filter nul|json] [--fallback] ARGS...
# --fallback runs ffs with FFS_RG set, for command lines it hands to rg.
check() {
  local mode=$1; shift
  local input="" dir=. filter=cat rgvar=
  while :; do
    case $1 in
      --stdin) input=$2; shift 2 ;;
      --cd) dir=$2; shift 2 ;;
      --filter) filter=$2; shift 2 ;;
      --fallback) rgvar=$RG; shift ;;
      *) break ;;
    esac
  done
  local want got want_rc got_rc
  if [ -n "$input" ]; then
    want=$(cd "$dir" && printf '%b' "$input" | rg "$@" 2>/dev/null | $filter; exit "${PIPESTATUS[1]}"); want_rc=$?
    got=$(cd "$dir" && printf '%b' "$input" | FFS_RG=$rgvar "$FFS" "$@" 2>/dev/null | $filter; exit "${PIPESTATUS[1]}"); got_rc=$?
  else
    want=$(cd "$dir" && rg "$@" </dev/null 2>/dev/null | $filter; exit "${PIPESTATUS[0]}"); want_rc=$?
    got=$(cd "$dir" && FFS_RG=$rgvar "$FFS" "$@" </dev/null 2>/dev/null | $filter; exit "${PIPESTATUS[0]}"); got_rc=$?
  fi
  if [ "$mode" = sort ]; then
    want=$(sort <<<"$want")
    got=$(sort <<<"$got")
  fi
  if [ "$want" = "$got" ] && [ "$want_rc" = "$got_rc" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: ($dir) rg $*"
    diff <(echo "$want"; echo "exit $want_rc") <(echo "$got"; echo "exit $got_rc") | sed 's/^/    /'
  fi
}

# Paths and output format
check sort foo
check sort -n foo
check sort foo .
check sort foo ./
check sort foo a/
check sort foo a
check sort -l foo ./a//
check raw -n foo a/x.txt
check sort -n foo a/x.txt top.txt
check sort -H foo a/x.txt
check sort -I -n foo a
check sort -N foo
check sort foo nope a/x.txt
check raw foo nope
check sort foo top-ignored.txt
# Patterns
check sort 'foo|two'
check sort -e foo -e two
check sort -i FOO
check sort -S Foo
check sort -S foo
check sort -w fo
check sort -w foo
check sort -x two
check sort -F 'a.b'
check sort -F '**F'
check sort 'F[0-9]+ —'
check sort '\*\*F[0-9]+' ROADMAP.md
check sort -o '\*\*F[0-9]+' ROADMAP.md
check sort '^##' ROADMAP.md
check sort '^- \[[ x]\] \*\*F' ROADMAP.md
check sort 'func cancel|func launch|struct JobStore' Sources
check sort -n 'class JobStore|struct JobStore' Sources Tests
check sort 'autoPilot|AutoPilot'
check sort -n 'error:|failed|Executed .* tests' test.log
check sort 'Executed [0-9]+ tests?, with' test.log
check sort -n 'func\s+\w+\(\)' Sources
check sort '(?i)autopilot'
check sort ''
check sort -c ''
# Output modes
check sort -c foo
check raw -c foo a/x.txt
check raw -c zzz a/x.txt
check sort -l foo
check sort -o 'f[a-z]+'
check raw -on foo a/x.txt
check sort -vn foo a/x.txt
check sort -v foo
check sort -c -v foo
check raw -m1 foo a/x.txt
check sort -m1 foo
check raw -q foo
check raw -q zzz
# Context
check raw -n -C1 two a/x.txt
check raw -n -A1 m c.txt
check raw -B1 m c.txt
check raw -n -C5 m c.txt
check raw -n -A1 -B3 '^6$' c.txt
check raw -nC1 -v '^[0-9]$' c.txt
check sort -n -A1 m c.txt top.txt
check raw -n -A2 'struct JobStore' Sources/App/Job.swift
# Files, globs, ignore files, hidden
check sort --files
check sort --files a
check sort --cd a --files
check sort --cd a/b --files ..
check sort --files -g '*.md' -g 'top*'
check sort --files -g '!a'
check sort --files -g 'a/**'
check sort --files -g 'b/*'
check sort --files -g '/top.txt'
check sort --files -g '*.{swift,md}'
check sort --files -g '*Test*'
check sort --files --hidden
check sort --files --hidden -g '!.git'
check sort --files -g 'z.txt'
check sort --files -g 'w.txt'
check sort --files --no-ignore
check sort --files --no-ignore-vcs
check sort --files -u
check sort --files -uu -g '!.git'
check sort --files k
check sort --files -g 'b/*' a
check sort --files -g 'a/b/*' a
check sort --files -g 'a/b/*' ./a/
check sort --files -g '/a/x.txt' a
check sort --files -g '!a/b/**' -g '*.md' .
check sort --cd a --files -g 'a/b/*' ../a
check sort --files --max-depth 1
check sort --files -d 2
check sort --files Sources README.md ROADMAP.md
check sort -n foo -g '*.txt'
check sort foo -g '!a/**'
check sort foo docs
check sort -a foo binary.dat
# Standard input
check raw --stdin 'foo\nbar\nfoo2\n' -n foo
check raw --stdin 'foo\nbar\n' -c foo
check raw --stdin 'a\nb\n' foo
check raw --stdin 'foo\nbar\n' -n foo -

# Claude Code's Grep tool (2.1.296), as it calls rg: always --hidden, the
# VCS directories left out and --max-columns 500; then -l and --null for
# file names, -c -H --null for counts, or --json -n for lines.
G=(--hidden --glob '!.git' --glob '!.svn' --glob '!.hg' --glob '!.bzr' --glob '!.jj' --glob '!.sl' --max-columns 500)
check sort --filter nul "${G[@]}" -l --null foo .
check sort --filter nul "${G[@]}" -l --null -i FOO .
check sort --filter nul "${G[@]}" -c -H --null foo .
check sort --filter json "${G[@]}" --json -n foo .
check sort --filter json "${G[@]}" --json -n 'func (cancel|launch)' .
check sort --filter json "${G[@]}" -i --json -n autopilot .
check sort --filter json "${G[@]}" --json -n -o 'F[0-9]+' .
check sort --filter json "${G[@]}" --json -n -C 1 m c.txt
check sort --filter json "${G[@]}" --json -n -B 1 -A 2 m c.txt
check sort --filter json "${G[@]}" --json -n -e -bar --glob '*.txt' .
check sort --filter json "${G[@]}" --json -n foo --type swift .
check sort --filter json "${G[@]}" --json -n func --glob '*.swift' --glob '!Tests/**' .
check sort --filter json "${G[@]}" --json -n foo a/x.txt
check sort --filter nul "${G[@]}" -l --null foo --type md .
check sort --filter nul "${G[@]}" -l --null foo --iglob '*.TXT' .
# Lines past --max-columns, and the rest of the new flags.
check sort -n --max-columns 5 'foo|1' c.txt a/x.txt
check sort --filter json --json --max-columns 5 foo .
check raw --filter json --json foo esc.txt
check sort -l foo -t md
check sort -l foo -T md
check sort --files -t swift
check sort --files -t swift -g '*.txt'
check sort --files --iglob '*.SWIFT'
check raw --filter nul --files --null Sources
check raw -t nosuchtype foo
# Multiline and --sort aren't ffs's: with FFS_RG, ripgrep runs them, as
# Claude Code's Grep tool (multiline: true) and Glob tool would call it.
check raw --fallback --filter json "${G[@]}" -U --multiline-dotall --json -n 'cancel.*launch' Sources
check raw --fallback --filter nul --files --null --glob '*.swift' --sort=modified --no-ignore --hidden

echo "compat: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
