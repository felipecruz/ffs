#!/bin/sh
# Benchmark ffs against rg, ack and grep with hyperfine.
# Usage: bench/bench.sh [term] [fixture]
# Tool paths come from bench/tools.sh; ack is skipped when not installed.
set -eu
cd "$(dirname "$0")/.."
. bench/tools.sh

TERM_="${1:-dictFind}"
FIX="${2:-fixtures/redis}"

zig build

# 1) Each tool with its default behavior (ffs, rg and ack skip hidden and ignored files; grep doesn't)
set -- -n ffs "$FFS -n $TERM_ $FIX" -n rg "$RG -n $TERM_ $FIX"
if [ -n "$ACK" ]; then set -- "$@" -n ack "$ACK $TERM_ $FIX"; fi
set -- "$@" -n grep "$GREP -rn $TERM_ $FIX"
"$H" -N --warmup 5 --min-runs 30 \
  --export-markdown "$OUT/defaults.md" --export-json "$OUT/defaults.json" \
  "$@"

# 2) Same work: all text files, nothing ignored (.git, hidden, .gitignore'd
#    files are searched); binary files (containing NUL) are skipped.
set -- -n ffs "$FFS -uu -n $TERM_ $FIX" -n 'ffs -j1' "$FFS -uu -n -j1 $TERM_ $FIX" \
       -n 'rg -uu' "$RG -uu -n $TERM_ $FIX"
if [ -n "$ACK" ]; then
  set -- "$@" -n 'ack --ignore-ack-defaults' "$ACK --ignore-ack-defaults --noenv $TERM_ $FIX"
fi
set -- "$@" -n 'grep -rI' "$GREP -rnI $TERM_ $FIX"
"$H" -N --warmup 5 --min-runs 30 \
  --export-markdown "$OUT/all-text.md" --export-json "$OUT/all-text.json" \
  "$@"
