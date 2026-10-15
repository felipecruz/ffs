#!/bin/sh
# Records docs/demo.gif from docs/demo.tape, in the Linux kernel source
# (cloned into fixtures/linux if missing, as in EXPERIMENTS.md). Needs vhs,
# which needs ttyd and ffmpeg, and rg for the comparison.
set -eu
cd "$(dirname "$0")/.."
if [ ! -d fixtures/linux ]; then
  git clone --depth 1 --branch v6.19 https://github.com/torvalds/linux.git fixtures/linux
fi
zig build
vhs docs/demo.tape
