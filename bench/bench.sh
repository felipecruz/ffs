#!/bin/sh
# Benchmark ffs against rg, ack and grep with hyperfine.
# Usage: bench/bench.sh [term] [fixture]
# Tools are called by absolute path so shell functions/aliases can't interfere.
set -eu
cd "$(dirname "$0")/.."

TERM_="${1:-dictFind}"
FIX="${2:-fixtures/redis}"
RG=/opt/homebrew/bin/rg
ACK=/opt/homebrew/bin/ack
GREP=/usr/bin/grep
FFS=zig-out/release/ffs
OUT=results

zig build

# 1) Each tool with its default behavior (rg and ack skip .git, grep and ffs don't)
/opt/homebrew/bin/hyperfine -N --warmup 5 --min-runs 30 \
  --export-markdown "$OUT/defaults.md" --export-json "$OUT/defaults.json" \
  -n ffs  "$FFS $FIX $TERM_" \
  -n rg   "$RG -n $TERM_ $FIX" \
  -n ack  "$ACK $TERM_ $FIX" \
  -n grep "$GREP -rn $TERM_ $FIX"

# 2) Same work: all text files, nothing ignored (.git, hidden, .gitignore'd
#    files are searched); binary files (containing NUL) are skipped.
/opt/homebrew/bin/hyperfine -N --warmup 5 --min-runs 30 \
  --export-markdown "$OUT/all-text.md" --export-json "$OUT/all-text.json" \
  -n ffs      "$FFS $FIX $TERM_" \
  -n 'ffs -j1' "$FFS -j1 $FIX $TERM_" \
  -n 'rg -uu' "$RG -uu -n $TERM_ $FIX" \
  -n 'ack --ignore-ack-defaults' "$ACK --ignore-ack-defaults --noenv $TERM_ $FIX" \
  -n 'grep -rI' "$GREP -rnI $TERM_ $FIX"
