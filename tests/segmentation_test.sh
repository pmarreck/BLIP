#!/usr/bin/env bash
set -u

# =============================================================================
# blar segmentation CLI test suite (Layer 5a)
# =============================================================================
# Exercises:
#   blar segment / blar split   — chunk an arbitrary file into .seg pieces
#   blar join    / blar reassemble — glue .seg pieces back into the original
#
# Naming convention being verified:
#   <stem>.<M>-of-<N>.seg          numeric N, minimum-width zero-padding,
#                                  M is 1-based
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"

echo "Building blar..."
(cd "$PROJECT_DIR" && nix develop -c zig build -Doptimize=ReleaseFast) \
  || { echo "FATAL: build failed"; exit 1; }

if [[ ! -x "$BLAR" ]]; then
  echo "FATAL: blar binary not found at $BLAR"
  exit 1
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}

# Compute xxh64 of a file using whatever tool is available, fall back to sha256
file_hash() {
  if command -v xxhsum >/dev/null 2>&1; then
    xxhsum -H64 "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ----- 1. segment a known-size file into N pieces and verify naming -----
dd if=/dev/urandom of="$TMPDIR_TEST/blob_500.bin" bs=500 count=1 2>/dev/null
SEG_DIR_1="$TMPDIR_TEST/seg1"
mkdir -p "$SEG_DIR_1"
cp "$TMPDIR_TEST/blob_500.bin" "$SEG_DIR_1/blob.bin"

if "$BLAR" segment "$SEG_DIR_1/blob.bin" --segment-size=128 >/dev/null 2>&1; then
  pass "blar segment exits 0 with --segment-size"
else
  fail "blar segment did not exit 0 with --segment-size"
fi

# 500/128 = 4 segments (3*128 + 116). Files should be:
#   blob.bin.1-of-4.seg ... blob.bin.4-of-4.seg
expected_files=(
  "$SEG_DIR_1/blob.bin.1-of-4.seg"
  "$SEG_DIR_1/blob.bin.2-of-4.seg"
  "$SEG_DIR_1/blob.bin.3-of-4.seg"
  "$SEG_DIR_1/blob.bin.4-of-4.seg"
)
all_present=1
for f in "${expected_files[@]}"; do
  if [[ ! -f "$f" ]]; then
    all_present=0
    echo "  missing: $f"
  fi
done
if [[ $all_present -eq 1 ]]; then
  pass "all 4 expected segment files exist with 1-based naming"
else
  fail "expected segment files missing"
fi

# ----- 2. join the segments back; result is byte-identical -----
JOINED_1="$SEG_DIR_1/blob.rejoined.bin"
if "$BLAR" join "$SEG_DIR_1/blob.bin.1-of-4.seg" -o "$JOINED_1" >/dev/null 2>&1; then
  pass "blar join exits 0 from the first segment"
else
  fail "blar join did not exit 0"
fi

if [[ -f "$JOINED_1" ]] && cmp -s "$SEG_DIR_1/blob.bin" "$JOINED_1"; then
  pass "joined output is byte-identical to original blob"
else
  fail "joined output differs from original"
fi

# ----- 3. join from a non-first segment also works -----
JOINED_1B="$SEG_DIR_1/blob.rejoined2.bin"
if "$BLAR" join "$SEG_DIR_1/blob.bin.3-of-4.seg" -o "$JOINED_1B" >/dev/null 2>&1; then
  pass "blar join exits 0 from a middle segment"
else
  fail "blar join did not accept middle segment"
fi

if [[ -f "$JOINED_1B" ]] && cmp -s "$SEG_DIR_1/blob.bin" "$JOINED_1B"; then
  pass "joining from middle segment yields identical result"
else
  fail "join-from-middle output differs"
fi

# ----- 4. split / reassemble are synonyms -----
SEG_DIR_2="$TMPDIR_TEST/seg2"
mkdir -p "$SEG_DIR_2"
cp "$TMPDIR_TEST/blob_500.bin" "$SEG_DIR_2/blob.bin"

if "$BLAR" split "$SEG_DIR_2/blob.bin" --segment-size=128 >/dev/null 2>&1; then
  pass "'blar split' is accepted as synonym for 'segment'"
else
  fail "'blar split' rejected"
fi

JOINED_2="$SEG_DIR_2/blob.rejoined.bin"
if "$BLAR" reassemble "$SEG_DIR_2/blob.bin.1-of-4.seg" -o "$JOINED_2" >/dev/null 2>&1; then
  pass "'blar reassemble' is accepted as synonym for 'join'"
else
  fail "'blar reassemble' rejected"
fi

# ----- 5. --segment-count instead of --segment-size -----
SEG_DIR_3="$TMPDIR_TEST/seg3"
mkdir -p "$SEG_DIR_3"
cp "$TMPDIR_TEST/blob_500.bin" "$SEG_DIR_3/blob.bin"

if "$BLAR" segment "$SEG_DIR_3/blob.bin" --segment-count=5 >/dev/null 2>&1; then
  pass "blar segment accepts --segment-count"
else
  fail "blar segment rejected --segment-count"
fi

if [[ -f "$SEG_DIR_3/blob.bin.1-of-5.seg" && -f "$SEG_DIR_3/blob.bin.5-of-5.seg" ]]; then
  pass "--segment-count produces 5 segments with correct names"
else
  fail "--segment-count did not produce 5 expected segments"
fi

JOINED_3="$SEG_DIR_3/blob.rejoined.bin"
"$BLAR" join "$SEG_DIR_3/blob.bin.1-of-5.seg" -o "$JOINED_3" >/dev/null 2>&1
if cmp -s "$SEG_DIR_3/blob.bin" "$JOINED_3"; then
  pass "--segment-count roundtrip is byte-identical"
else
  fail "--segment-count roundtrip differs from original"
fi

# ----- 6. minimum-width padding for N >= 10 -----
SEG_DIR_4="$TMPDIR_TEST/seg4"
mkdir -p "$SEG_DIR_4"
dd if=/dev/urandom of="$SEG_DIR_4/big.bin" bs=2500 count=1 2>/dev/null
"$BLAR" segment "$SEG_DIR_4/big.bin" --segment-count=12 >/dev/null 2>&1

# With N=12, width should be 2.  First segment = big.bin.01-of-12.seg
if [[ -f "$SEG_DIR_4/big.bin.01-of-12.seg" && -f "$SEG_DIR_4/big.bin.12-of-12.seg" ]]; then
  pass "N=12 uses width-2 zero padding"
else
  fail "N=12 did not produce width-2 names"
fi

# Also: lexicographic sort matches numeric sort
sorted_first=$(ls "$SEG_DIR_4"/big.bin.*.seg | head -1)
if [[ "$sorted_first" == "$SEG_DIR_4/big.bin.01-of-12.seg" ]]; then
  pass "lexicographic sort matches numeric order at N=12"
else
  fail "lexicographic sort drift at N=12 (first=$sorted_first)"
fi

# ----- 7. exact-multiple does not produce empty trailer -----
SEG_DIR_5="$TMPDIR_TEST/seg5"
mkdir -p "$SEG_DIR_5"
dd if=/dev/urandom of="$SEG_DIR_5/exact.bin" bs=300 count=1 2>/dev/null
"$BLAR" segment "$SEG_DIR_5/exact.bin" --segment-size=100 >/dev/null 2>&1
seg_count=$(ls "$SEG_DIR_5"/exact.bin.*.seg 2>/dev/null | wc -l | tr -d ' ')
if [[ "$seg_count" == "3" ]]; then
  pass "exact multiple produces exactly 3 segments (no empty trailer)"
else
  fail "exact multiple produced $seg_count segments (expected 3)"
fi

# ----- 8. mutually exclusive flags -----
SEG_DIR_6="$TMPDIR_TEST/seg6"
mkdir -p "$SEG_DIR_6"
cp "$TMPDIR_TEST/blob_500.bin" "$SEG_DIR_6/blob.bin"
if "$BLAR" segment "$SEG_DIR_6/blob.bin" --segment-size=128 --segment-count=4 >/dev/null 2>&1; then
  fail "segment accepted both --segment-size AND --segment-count (should be mutex)"
else
  pass "segment rejects --segment-size combined with --segment-count"
fi

# ----- 9. requires at least one chunking flag -----
SEG_DIR_7="$TMPDIR_TEST/seg7"
mkdir -p "$SEG_DIR_7"
cp "$TMPDIR_TEST/blob_500.bin" "$SEG_DIR_7/blob.bin"
if "$BLAR" segment "$SEG_DIR_7/blob.bin" >/dev/null 2>&1; then
  fail "segment accepted invocation with no --segment-size/--segment-count"
else
  pass "segment requires --segment-size or --segment-count"
fi

# ----- 10. join with a missing segment errors -----
SEG_DIR_8="$TMPDIR_TEST/seg8"
mkdir -p "$SEG_DIR_8"
cp "$TMPDIR_TEST/blob_500.bin" "$SEG_DIR_8/blob.bin"
"$BLAR" segment "$SEG_DIR_8/blob.bin" --segment-count=4 >/dev/null 2>&1
rm -f "$SEG_DIR_8/blob.bin.2-of-4.seg"
if "$BLAR" join "$SEG_DIR_8/blob.bin.1-of-4.seg" -o "$SEG_DIR_8/joined.bin" 2>/dev/null; then
  fail "join silently succeeded with a missing segment"
else
  pass "join errors out when a segment is missing"
fi

# ----- 11. larger file roundtrip with hash equality -----
SEG_DIR_9="$TMPDIR_TEST/seg9"
mkdir -p "$SEG_DIR_9"
dd if=/dev/urandom of="$SEG_DIR_9/big.bin" bs=4096 count=10 2>/dev/null
orig_hash=$(file_hash "$SEG_DIR_9/big.bin")
"$BLAR" segment "$SEG_DIR_9/big.bin" --segment-size=4096 >/dev/null 2>&1
"$BLAR" join "$SEG_DIR_9/big.bin.01-of-10.seg" -o "$SEG_DIR_9/big.rejoined.bin" >/dev/null 2>&1
joined_hash=$(file_hash "$SEG_DIR_9/big.rejoined.bin")
if [[ "$orig_hash" == "$joined_hash" ]]; then
  pass "40KB roundtrip preserves hash ($orig_hash)"
else
  fail "40KB roundtrip hash mismatch (orig=$orig_hash joined=$joined_hash)"
fi

# ----- 12. header-scan fallback (renamed segment files still reassemble) -----
SEG_DIR_10="$TMPDIR_TEST/seg10"
mkdir -p "$SEG_DIR_10"
cp "$TMPDIR_TEST/blob_500.bin" "$SEG_DIR_10/blob.bin"
"$BLAR" segment "$SEG_DIR_10/blob.bin" --segment-count=3 >/dev/null 2>&1
mv "$SEG_DIR_10/blob.bin.1-of-3.seg" "$SEG_DIR_10/garbage_a"
mv "$SEG_DIR_10/blob.bin.2-of-3.seg" "$SEG_DIR_10/garbage_b"
mv "$SEG_DIR_10/blob.bin.3-of-3.seg" "$SEG_DIR_10/garbage_c"
if "$BLAR" join "$SEG_DIR_10/garbage_a" -o "$SEG_DIR_10/blob.rejoined.bin" 2>/dev/null; then
  if cmp -s "$SEG_DIR_10/blob.bin" "$SEG_DIR_10/blob.rejoined.bin"; then
    pass "header-scan fallback reassembles renamed segments correctly"
  else
    fail "header-scan fallback reassembled, but bytes differ"
  fi
else
  fail "header-scan fallback failed (renamed segments not detected)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Segmentation tests: $PASS passed, $FAIL failed"
exit $FAIL
