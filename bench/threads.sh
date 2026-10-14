#!/bin/sh
# Sweep ffs thread counts (-j) on each fixture, including -j auto.
# Usage: bench/threads.sh
# Writes $OUT/threads-<fixture>.json and $OUT/threads-topology.txt.
# On another machine: run it and check that `auto` lands on (or near) the best -j.
set -eu
cd "$(dirname "$0")/.."
. bench/tools.sh

zig build

# The CPU topology that -j auto reads.
if [ "$(uname -s)" = Darwin ]; then
  { sysctl -n machdep.cpu.brand_string
    sysctl hw.logicalcpu hw.nperflevels hw.perflevel0.name hw.perflevel0.logicalcpu \
      hw.perflevel1.name hw.perflevel1.logicalcpu 2>/dev/null || true
  } | tee "$OUT/threads-topology.txt"
else
  { uname -srm
    lscpu | grep -E 'Model name|^CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|NUMA node\(s\)|L3 cache'
  } | tee "$OUT/threads-topology.txt"
fi

# The sweep covers up to the logical CPU count, so `auto` can be compared
# against the real optimum on machines wider than 10 threads.
JS=auto,1,2,3,4,5,6,8,10
NCPU=$( (nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null) || echo 10)
for j in 12 16 24 32; do
  if [ "$j" -le "$NCPU" ]; then JS="$JS,$j"; fi
done

"$H" -N --warmup 3 --min-runs 10 \
  --export-json "$OUT/threads-redis.json" \
  -L j "$JS" "$FFS -j {j} fixtures/redis dictFind"

"$H" -N --warmup 3 --min-runs 10 \
  --export-json "$OUT/threads-linux.json" \
  -L j "$JS" "$FFS -j {j} fixtures/linux PM_RESUME"

# Fairness check: ripgrep with the same thread caps.
"$H" -N -i --warmup 3 --min-runs 10 \
  --export-json "$OUT/linux-rg-threads.json" \
  -n ffs          "$FFS fixtures/linux PM_RESUME" \
  -n 'rg -uu -j4' "$RG -uu -j4 -n -F PM_RESUME fixtures/linux" \
  -n 'rg -uu -j2' "$RG -uu -j2 -n -F PM_RESUME fixtures/linux" \
  -n 'rg -uu'     "$RG -uu -n -F PM_RESUME fixtures/linux"

"$H" -N --warmup 3 --min-runs 30 \
  --export-json "$OUT/redis-rg-threads.json" \
  -n ffs          "$FFS fixtures/redis dictFind" \
  -n 'rg -uu -j4' "$RG -uu -j4 -n dictFind fixtures/redis"
