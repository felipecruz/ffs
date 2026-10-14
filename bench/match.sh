#!/bin/sh
# Benchmark the matcher alone (match.findLines) on an in-memory corpus.
# The corpus is the first 512 MB of the Linux kernel's .c/.h files,
# concatenated (built once into fixtures/linux-src.txt).
set -eu
cd "$(dirname "$0")/.."
CORPUS=fixtures/linux-src.txt
if [ ! -f "$CORPUS" ]; then
  find fixtures/linux -type f \( -name '*.c' -o -name '*.h' \) -print0 | sort -z \
    | xargs -0 cat | head -c 512000000 > "$CORPUS"
fi
zig build bench-match -- "$CORPUS" "${1:-7}"
