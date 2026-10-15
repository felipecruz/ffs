#!/bin/sh
# ffs vs ripgrep at MATCHED thread counts, on one machine (EXPERIMENTS.md,
# Experiment 15). The suite's other scripts compare the two tools as each is
# normally run; this one separates the algorithm from the thread count, which
# is what made the Linux numbers confusing: `-j auto` used to pin ffs to 4
# threads while ripgrep used every core.
# Usage: bench/h2h.sh [thread-counts]   (default: 1,2,4,8,12,16)
# Writes $OUT/h2h-*.{md,json} and $OUT/h2h-correctness.txt.
set -eu
cd "$(dirname "$0")/.."
. bench/tools.sh

JS="${1:-1,2,4,8,12,16}"

zig build

echo "== ffs thread sweep, linux literal"
"$H" -N --warmup 3 --min-runs 10 \
  --export-json "$OUT/h2h-ffs-threads-linux.json" \
  -L j "$JS" "$FFS -uu -n -F -j {j} PM_RESUME fixtures/linux"

echo "== rg thread sweep, same counts, same query"
"$H" -N --warmup 3 --min-runs 10 \
  --export-json "$OUT/h2h-rg-threads-linux.json" \
  -L j "$JS" "$RG -uu -n -F -j {j} PM_RESUME fixtures/linux"

echo "== ffs thread sweep, redis literal"
"$H" -N --warmup 5 --min-runs 30 \
  --export-json "$OUT/h2h-ffs-threads-redis.json" \
  -L j "$JS" "$FFS -uu -n -F -j {j} dictFind fixtures/redis"

# Full width: both tools with every thread they want, plus `-j4` for each to
# show what the old default was costing.
echo "== full-width literal queries, linux"
for spec in 'rare|PM_RESUME' 'common|ERR_PTR' 'none|zqxjvkwqz' 'long|#include <linux/module.h>'; do
  slug=${spec%%|*}; term=${spec#*|}
  echo "== $slug"
  "$H" -N -i --warmup 3 --min-runs 10 \
    --export-markdown "$OUT/h2h-linux-$slug.md" --export-json "$OUT/h2h-linux-$slug.json" \
    -n 'ffs'        "$FFS -uu -n -F -- '$term' fixtures/linux" \
    -n 'ffs -j4'    "$FFS -uu -n -F -j4 -- '$term' fixtures/linux" \
    -n 'rg -uu'     "$RG -uu -n -F -- '$term' fixtures/linux" \
    -n 'rg -uu -j4' "$RG -uu -n -F -j4 -- '$term' fixtures/linux" </dev/null
done

echo "== full-width regex queries, linux (rg -P is PCRE2, for reference)"
for spec in 'prefix|PM_[A-Z_]+' 'hex16|[0-9a-f]{16}' 'define|^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+' 'word-lock|\w+_lock_irqsave\('; do
  slug=${spec%%|*}; pat=${spec#*|}
  echo "== regex $slug"
  "$H" -N -i --warmup 2 --min-runs 10 \
    --export-markdown "$OUT/h2h-regex-$slug.md" --export-json "$OUT/h2h-regex-$slug.json" \
    -n 'ffs -uu'     "$FFS -uu -n -e '$pat' fixtures/linux" \
    -n 'ffs -uu -j4' "$FFS -uu -n -j4 -e '$pat' fixtures/linux" \
    -n 'rg -uu'     "$RG -uu -n -e '$pat' fixtures/linux" \
    -n 'rg -uu -P'  "$RG -uu -n -P -e '$pat' fixtures/linux" </dev/null
done

echo "== case-insensitive, linux"
"$H" -N -i --warmup 2 --min-runs 10 \
  --export-markdown "$OUT/h2h-linux-icase.md" --export-json "$OUT/h2h-linux-icase.json" \
  -n 'ffs -i'    "$FFS -uu -n -i -F PM_RESUME fixtures/linux" \
  -n 'rg -uu -i' "$RG -uu -n -i -F PM_RESUME fixtures/linux" </dev/null

echo "== redis fixture, full width"
"$H" -N -i --warmup 5 --min-runs 30 \
  --export-markdown "$OUT/h2h-redis.md" --export-json "$OUT/h2h-redis.json" \
  -n 'ffs'     "$FFS -uu -n -F dictFind fixtures/redis" \
  -n 'ffs -j8' "$FFS -uu -n -F -j8 dictFind fixtures/redis" \
  -n 'rg -uu'  "$RG -uu -n -F dictFind fixtures/redis" </dev/null

# A speed number means nothing if the two tools disagree on what they found.
echo "== correctness: ffs and rg must agree on match counts"
{ for q in PM_RESUME ERR_PTR zqxjvkwqz; do
    a=$("$FFS" -uu -n -F -- "$q" fixtures/linux | wc -l); b=$("$RG" -uu -n -F -- "$q" fixtures/linux | wc -l)
    echo "literal $q: ffs=$a rg=$b $([ "$a" = "$b" ] && echo MATCH || echo DIFFER)"
  done
  for p in 'PM_[A-Z_]+' '[0-9a-f]{16}' '\w+_lock_irqsave\('; do
    a=$("$FFS" -uu -n -e "$p" fixtures/linux | wc -l); b=$("$RG" -uu -n -e "$p" fixtures/linux | wc -l)
    echo "regex $p: ffs=$a rg=$b $([ "$a" = "$b" ] && echo MATCH || echo DIFFER)"
  done
} | tee "$OUT/h2h-correctness.txt"
