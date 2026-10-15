#!/bin/bash
# An agent's search session, replayed: the kinds of calls coding agents make
# (SEARCH_CMDs.md), run from inside the Redis checkout the way an agent
# runs them from its repository. Every call is timed with ffs and with
# ripgrep, and the two outputs must be identical (sorted, since neither
# tool's order is deterministic).
# Usage: bench/agent.sh
# Writes $OUT/agent.md (the table in the README) and $OUT/agent-*.json.
set -eu
cd "$(dirname "$0")/.."
. bench/tools.sh
zig build
FFS=$(realpath "$FFS")
OUT=$(realpath "$OUT")
cd fixtures/redis

# A test log to search, the way agents grep saved test output.
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
awk 'BEGIN { srand(7); for (i = 1; i <= 200000; i++) {
  r = rand()
  if (r < 0.001)      printf "[err]: Test %d in tests/unit/type/list.tcl failed\n", i
  else if (r < 0.002) printf "[exception]: Executing test client: ERR unknown command\n"
  else                printf "[ok]: Test %d passed (%d ms)\n", i, int(rand() * 900) }
  print "Executed 200000 tests, with 0 failures" }' > "$LOG"

TABLE="$OUT/agent.md"
{
  echo "| # | What the agent wants | Call | ffs | ripgrep | |"
  echo "|---:|:---|:---|---:|---:|:---|"
} > "$TABLE"

n=0
# call "description" ARGS...   (standard input: the test log when ARGS has no path)
call() {
  local what=$1; shift
  n=$((n + 1))
  local cmd="$*" input=/dev/null
  [ "${STDIN:-}" = 1 ] && input=$LOG
  local a b
  a=$(eval "$FFS $cmd" < "$input" | sort) || true
  b=$(eval "$RG $cmd" < "$input" | sort) || true
  [ "$a" = "$b" ] || { echo "agent.sh: ffs and rg differ on: $cmd" >&2; exit 1; }

  echo "== $n. $what: $cmd"
  "$H" -N -i --warmup 3 --min-runs 20 --input "$input" \
    --export-json "$OUT/agent-$n.json" \
    -n ffs "$FFS $cmd" -n rg "$RG $cmd" >/dev/null
  local means f r
  means=$(sed -n 's/.*"mean": *\([0-9.e-]*\).*/\1/p' "$OUT/agent-$n.json")
  f=$(echo "$means" | sed -n 1p)
  r=$(echo "$means" | sed -n 2p)
  CMD=$cmd awk -v n="$n" -v what="$what" -v f="$f" -v r="$r" 'BEGIN {
    cmd = ENVIRON["CMD"]
    fs = sprintf("%.1f ms", f * 1000); rs = sprintf("%.1f ms", r * 1000)
    if (f * 1.05 > r && r * 1.05 > f) note = "about the same"
    else if (f < r) { fs = "**" fs "**"; note = sprintf("%.1fx faster", r / f) }
    else            { rs = "**" rs "**"; note = sprintf("%.1fx slower", f / r) }
    gsub(/\|/, "\\|", cmd)
    printf "| %d | %s | `rg %s` | %s | %s | %s |\n", n, what, cmd, fs, rs, note }' >> "$TABLE"
}

call "Find the build files and docs" "--files -g '*README*' -g Makefile -g '*.sh' -g AGENTS.md"
call "Look for agent instructions" "--files --hidden -g '*instructions*' -g CLAUDE.md -g AGENTS.md"
call "Guess a symbol's name" "-n 'dictFind|dictAdd|dictDelete' src"
call "Jump to a declaration" "-n 'struct redisServer \{|struct client \{' src/server.h"
call "Read a function body" "-n -A40 '^dictEntry \*dictFind\(' src/dict.c"
call "Spell out case variants" "-n 'lazyfree|lazyFree|LazyFree' src"
call "Search the whole repo" "-n serverAssert"
call "Count uses per file" "-c 'serverLog\(LL_WARNING' src"
call "Which files call it" "-l aeCreateFileEvent src"
call "Whole word only" "-w -n dictSize src"
call "Pull out IDs" "-o -n 'REDIS_VERSION \"[0-9.]+\"|RDB_VERSION [0-9]+' src"
call "Tests that mention it" "-n -g '*.tcl' 'lazyfree' tests"
STDIN=1 call "Read a saved test log" "-n 'err\]|exception\]|Executed [0-9]+ tests'"
STDIN=
call "Regex with no literal" "-n '[0-9a-f]{16}' src"
call "Alternation with a common word" "-n 'dictFind|struct [a-z]+ \{' src"

# The session as a whole: the sum of the means.
for k in $(seq 1 "$n"); do sed -n 's/.*"mean": *\([0-9.e-]*\).*/\1/p' "$OUT/agent-$k.json"; done |
  awk 'NR % 2 { f += $1 } !(NR % 2) { r += $1 }
    END { printf "\nThe whole session: ffs %.1f ms, ripgrep %.1f ms.\n", f * 1000, r * 1000 }' >> "$TABLE"
cat "$TABLE"
