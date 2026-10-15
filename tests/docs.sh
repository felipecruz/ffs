#!/usr/bin/env bash
# The docs can't drift from what ffs does:
#
#  1. Every `$ ...` line in a ```console block in docs/*.md is run inside the
#     Redis 8.0.2 source, and its output must be the lines shown below it.
#     Lines may come in another order (file order isn't fixed), and a block
#     that ends in `...` only has to show lines that are in the output.
#  2. Every flag src/main.zig accepts must be in docs/ffs.1 and in --help.
#
# Usage: tests/docs.sh [--update] [path/to/ffs]
#   --update  rewrite the outputs in docs/*.md from real runs, keeping each
#             block's length when it was cut with `...`
# REDIS: the Redis 8.0.2 checkout (default fixtures/redis), as CI fetches it:
#   git clone --depth 1 --branch 8.0.2 https://github.com/redis/redis.git fixtures/redis
set -u
shopt -s nullglob
cd "$(dirname "$0")/.."
UPDATE=0
[ "${1:-}" = --update ] && { UPDATE=1; shift; }
FFS=$(realpath "${1:-zig-out/release/ffs}")
REDIS=$(realpath "${REDIS:-fixtures/redis}")
[ -d "$REDIS/src" ] || { echo "docs.sh: no Redis checkout at $REDIS" >&2; exit 2; }

# A command as the docs show it, with `ffs` meaning the binary under test.
run() {
  (cd "$REDIS" && bash -c "ffs() { \"$FFS\" \"\$@\"; }; $1" </dev/null 2>&1)
}

pass=0
fail=0
# Does `got` show what `want` claims?
matches() {
  local want=$1 got=$2
  [ "$want" = "$got" ] && return 0
  if [ "$(tail -n1 <<<"$want")" = "..." ]; then
    # Every shown line (but the `...`) must be in the output.
    local missing
    missing=$(comm -23 <(sed '$d' <<<"$want" | sort) <(sort <<<"$got"))
    [ -z "$missing" ]
  else
    [ "$(sort <<<"$want")" = "$(sort <<<"$got")" ]
  fi
}

for doc in docs/*.md; do
  out=()        # the rewritten file, with --update
  in_block=0
  cmd=""        # the command whose output is being read
  want=()       # its output as the docs show it
  where=""

  # Called at the end of each command's output.
  finish() {
    [ -n "$cmd" ] || return 0
    local got wanted
    got=$(run "$cmd")
    wanted=$(printf '%s\n' "${want[@]+"${want[@]}"}")
    [ ${#want[@]} -eq 0 ] && wanted=""
    if [ $UPDATE = 1 ]; then
      if [ ${#want[@]} -gt 0 ] && [ "${want[-1]}" = "..." ] && [ "$(wc -l <<<"$got")" -ge ${#want[@]} ]; then
        mapfile -t lines < <(head -n $((${#want[@]} - 1)) <<<"$got")
        out+=("${lines[@]}" "...")
      elif [ -n "$got" ]; then
        mapfile -t lines <<<"$got"
        out+=("${lines[@]}")
      fi
    elif matches "$wanted" "$got"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "FAIL: $where: \$ $cmd"
      diff <(echo "$wanted") <(echo "$got") | sed 's/^/    /'
    fi
    cmd=""
    want=()
  }

  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [ $in_block = 0 ]; then
      [ "$line" = '```console' ] && in_block=1
      out+=("$line")
    elif [ "$line" = '```' ]; then
      finish
      in_block=0
      out+=("$line")
    elif [[ $line == '$ '* ]]; then
      finish
      cmd=${line#'$ '}
      where="$doc:$n"
      out+=("$line")
    else
      want+=("$line")
    fi
  done <"$doc"
  [ $UPDATE = 1 ] && printf '%s\n' "${out[@]}" >"$doc"
done

# Every flag in the docs.
help=$("$FFS" --help 2>&1)
longs=$(sed -n 's/^ *\.{ "\([a-z-]*\)", \.[a-z_]* },$/\1/p' src/main.zig)
shorts=$(sed -n "s/^ *'\\(.\\)' => \\.[a-z_]*,\$/\\1/p" src/main.zig)
[ -n "$longs" ] && [ -n "$shorts" ] || { echo "docs.sh: no flags found in src/main.zig" >&2; exit 2; }
for f in $longs; do
  # --color etc. are accepted and ignored: the man page lists them, --help doesn't.
  grep -q -- "Fl -$f\b" docs/ffs.1 || { fail=$((fail + 1)); echo "FAIL: --$f is not in docs/ffs.1"; }
  case $f in color | colour | heading | no-heading | no-messages | maxdepth) continue ;; esac
  grep -q -- "--$f\b" <<<"$help" || { fail=$((fail + 1)); echo "FAIL: --$f is not in --help"; }
done
for f in $shorts; do
  pat="Fl $f[ ,]|Fl $f\$"
  [ "$f" = . ] && pat='Fl \\&\.'
  grep -Eq -- "$pat" docs/ffs.1 || { fail=$((fail + 1)); echo "FAIL: -$f is not in docs/ffs.1"; }
  grep -Fq -- "-$f," <<<"$help" || grep -Fq -- "  -$f " <<<"$help" || { fail=$((fail + 1)); echo "FAIL: -$f is not in --help"; }
done

[ $UPDATE = 1 ] && { echo "docs: outputs rewritten"; exit 0; }
echo "docs: $pass examples match, $fail failed"
[ "$fail" -eq 0 ]
