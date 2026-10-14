# Resolve the benchmark tools, sourced by the bench/*.sh scripts.
# Every tool is an absolute path so shell functions/aliases can't interfere.
# Override any of these in the environment:
#   FFS RG ACK GREP HYPERFINE OUT
# Homebrew paths are tried first, so macOS runs keep using the same binaries.
pick() {
  for c in "$@"; do
    case $c in
      /*) [ -x "$c" ] && { printf '%s\n' "$c"; return 0; } ;;
      *)  p=$(command -v "$c" 2>/dev/null) && { printf '%s\n' "$p"; return 0; } ;;
    esac
  done
  return 1
}

FFS=${FFS:-zig-out/release/ffs}
RG=${RG:-$(pick /opt/homebrew/bin/rg rg || true)}
ACK=${ACK:-$(pick /opt/homebrew/bin/ack ack || true)}
GREP=${GREP:-$(pick /usr/bin/grep grep || true)}
H=${HYPERFINE:-$(pick /opt/homebrew/bin/hyperfine hyperfine || true)}
OUT=${OUT:-results}

[ -n "$H" ]    || { echo "bench: hyperfine not found; install it or set HYPERFINE=/path" >&2; exit 1; }
[ -n "$RG" ]   || { echo "bench: rg not found; install it or set RG=/path" >&2; exit 1; }
[ -n "$GREP" ] || { echo "bench: grep not found; set GREP=/path" >&2; exit 1; }
[ -n "$ACK" ]  || echo "bench: ack not found, skipping its entries (set ACK=/path to include it)" >&2
mkdir -p "$OUT"
