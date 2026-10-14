#!/bin/sh
# Sweep ffs thread counts (-j) on each fixture, including -j auto.
# Usage: bench/threads.sh
# Writes results/threads-<fixture>.json and results/threads-topology.txt.
# On another Mac: run it and check that `auto` lands on (or near) the best -j.
set -eu
cd "$(dirname "$0")/.."

FFS=zig-out/release/ffs
zig build

# The CPU topology that -j auto reads.
{ sysctl -n machdep.cpu.brand_string
  sysctl hw.logicalcpu hw.nperflevels hw.perflevel0.name hw.perflevel0.logicalcpu \
    hw.perflevel1.name hw.perflevel1.logicalcpu 2>/dev/null || true
} | tee results/threads-topology.txt

/opt/homebrew/bin/hyperfine -N --warmup 3 --min-runs 10 \
  --export-json results/threads-redis.json \
  -L j auto,1,2,3,4,5,6,8,10 "$FFS -j {j} fixtures/redis dictFind"

/opt/homebrew/bin/hyperfine -N --warmup 3 --min-runs 10 \
  --export-json results/threads-linux.json \
  -L j auto,1,2,3,4,5,6,8,10 "$FFS -j {j} fixtures/linux PM_RESUME"

# Fairness check: ripgrep with the same thread caps.
RG=/opt/homebrew/bin/rg
/opt/homebrew/bin/hyperfine -N -i --warmup 3 --min-runs 10 \
  --export-json results/linux-rg-threads.json \
  -n ffs          "$FFS fixtures/linux PM_RESUME" \
  -n 'rg -uu -j4' "$RG -uu -j4 -n -F PM_RESUME fixtures/linux" \
  -n 'rg -uu -j2' "$RG -uu -j2 -n -F PM_RESUME fixtures/linux" \
  -n 'rg -uu'     "$RG -uu -n -F PM_RESUME fixtures/linux"

/opt/homebrew/bin/hyperfine -N --warmup 3 --min-runs 30 \
  --export-json results/redis-rg-threads.json \
  -n ffs          "$FFS fixtures/redis dictFind" \
  -n 'rg -uu -j4' "$RG -uu -j4 -n dictFind fixtures/redis"
