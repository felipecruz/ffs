#!/bin/sh
# Benchmark regex search (-E) against ripgrep (and grep on two queries).
# All text files, nothing ignored. Usage: bench/regex.sh
# Writes $OUT/regex-<fixture>-<slug>.{md,json}.
set -eu
cd "$(dirname "$0")/.."
. bench/tools.sh

zig build

# fixture|slug|flags|pattern (literal in the pattern = the SIMD prefilter)
QUERIES='linux|prefix||PM_[A-Z_]+
linux|errptr||\bERR_PTR\(-E[A-Z]+\)
linux|word-lock||\w+_lock_irqsave\(
linux|define||^\s*#\s*define\s+[A-Z_]+\s+0x[0-9a-fA-F]+
linux|alt-lock||(spin|mutex)_lock\(
linux|hex16||[0-9a-f]{16}
linux|todo-i|-i|todo|fixme
redis|dict-alt||dict(Find|Delete)\(
redis|digits||[0-9]{3,}'

printf '%s\n' "$QUERIES" | while IFS='|' read -r fix slug flags pattern; do
  echo "== $fix $slug: $flags $pattern"
  # -i: rg exits 1 when nothing matches; correctness is checked separately.
  "$H" -N -i --warmup 3 --min-runs 10 \
    --export-markdown "$OUT/regex-$fix-$slug.md" --export-json "$OUT/regex-$fix-$slug.json" \
    -n "ffs -E" "$FFS -E $flags fixtures/$fix '$pattern'" \
    -n "rg -uu -j4" "$RG -uu -n -j4 $flags -e '$pattern' fixtures/$fix" \
    -n "rg -uu" "$RG -uu -n $flags -e '$pattern' fixtures/$fix" </dev/null
done

# grep is ~15x slower on Linux: two queries, 3 runs.
for spec in 'prefix|PM_[A-Z_]+' 'hex16|[0-9a-f]{16}'; do
  slug=${spec%%|*}; pattern=${spec#*|}
  echo "== grep linux $slug"
  "$H" -N -i --warmup 1 --runs 3 \
    --export-markdown "$OUT/regex-linux-$slug-grep.md" --export-json "$OUT/regex-linux-$slug-grep.json" \
    -n "ffs -E" "$FFS -E fixtures/linux '$pattern'" \
    -n "grep -rIE" "$GREP -rIEn '$pattern' fixtures/linux"
done
