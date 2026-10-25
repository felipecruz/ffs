#!/bin/sh
# ffs vs ripgrep on the LLVM monorepo (fixtures/llvm): mostly C++, long
# template-heavy lines, huge test directories of .ll/.td/.mlir files.
# Usage: bench/llvm.sh   (clone: git clone --depth 1 https://github.com/llvm/llvm-project fixtures/llvm)
# Writes $OUT/llvm-<slug>.{md,json} and $OUT/llvm-correctness.txt.
set -eu
cd "$(dirname "$0")/.."
. bench/tools.sh

zig build
[ -d fixtures/llvm ] || { echo "bench: fixtures/llvm missing" >&2; exit 1; }

# slug|flags|pattern. Flags apply to both tools; "-uu" is added to both
# unless the slug starts with "default-" (then .gitignore filtering is on).
QUERIES='lit-rare|-F|ZQXJVKWQZ_NOPE
lit-mid|-F|getOperandBundle
lit-common|-F|getOperand
lit-vcommon|-F|return
icase|-i -F|DenseMap
default-lit|-F|getOperandBundle
default-glob|-g "*.cpp" -F|getOperandBundle
default-files-l|-l -F|getOperandBundle
default-count|-c -F|getOperand
word|-w|Value
prefix||Fixup[A-Z][a-z]+
cxx-template||std::unique_ptr<\w+>
cxx-class||class \w+ : public \w+
cxx-ns||llvm::\w+::\w+\(
alt-lit||isa<CallInst>|dyn_cast<LoadInst>|getTerminator
alt-common||getOperand|struct [A-Z]\w+Info
ll-ssa||%[0-9]+ = load
check-line||^\s*// CHECK-NEXT:\s+%\w+
hex16||[0-9a-f]{16}
ident-long||[A-Za-z_]{30,}
digits||[0-9]{5,}'

printf '%s\n' "$QUERIES" | while IFS='|' read -r slug flags pattern; do
  case $slug in default-*) uu= ;; *) uu=-uu ;; esac
  echo "== llvm $slug: $uu $flags $pattern"
  "$H" -N -i --warmup 2 --min-runs 10 \
    --export-markdown "$OUT/llvm-$slug.md" --export-json "$OUT/llvm-$slug.json" \
    -n "ffs" "$FFS $uu -n $flags -e '$pattern' fixtures/llvm" \
    -n "rg"  "$RG $uu -n $flags -e '$pattern' fixtures/llvm" </dev/null
done

echo "== correctness: match counts"
printf '%s\n' "$QUERIES" | while IFS='|' read -r slug flags pattern; do
  case $slug in default-*) uu= ;; *) uu=-uu ;; esac
  a=$(eval "\"$FFS\" $uu -n $flags -e '$pattern' fixtures/llvm" | wc -l)
  b=$(eval "\"$RG\" $uu -n $flags -e '$pattern' fixtures/llvm" | wc -l)
  echo "$slug: ffs=$a rg=$b $([ "$a" = "$b" ] && echo MATCH || echo DIFFER)"
done | tee "$OUT/llvm-correctness.txt"
