#!/bin/sh
# Benchmark several query shapes on one fixture, all text files, nothing ignored.
# Usage: bench/searches.sh [fixture]   (default: fixtures/linux)
# Writes $OUT/<fixture-name>-<query>.{md,json}.
set -eu
cd "$(dirname "$0")/.."
. bench/tools.sh

FIX="${1:-fixtures/linux}"
NAME=$(basename "$FIX")

zig build

# slug|term
QUERIES='rare|PM_RESUME
common|ERR_PTR
none|zqxjvkwqz
long|#include <linux/module.h>'

printf '%s\n' "$QUERIES" | while IFS='|' read -r slug term; do
  echo "== $slug: $term"
  # Fast tools get many runs within hyperfine's default time budget; slow
  # ones (ack, grep) get at least 5. -i: rg, ack and grep exit 1 when nothing
  # matches (the "none" query); correctness is checked separately.
  set -- -n ffs "$FFS -uu -n -F -- '$term' $FIX" -n 'ffs -j1' "$FFS -uu -n -F -j1 -- '$term' $FIX" \
         -n 'rg -uu' "$RG -uu -n -F -- '$term' $FIX"
  if [ -n "$ACK" ]; then
    set -- "$@" -n 'ack --ignore-ack-defaults' "$ACK --ignore-ack-defaults --noenv -Q -- '$term' $FIX"
  fi
  set -- "$@" -n 'grep -rI' "$GREP -rnIF -- '$term' $FIX"
  "$H" -N -i --warmup 3 --min-runs 5 \
    --export-markdown "$OUT/$NAME-$slug.md" --export-json "$OUT/$NAME-$slug.json" \
    "$@" </dev/null
done
