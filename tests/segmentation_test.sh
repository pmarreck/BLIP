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

# ----- 13. blar create --segment-size produces .seg files (Layer 5b) -----
SEG_DIR_11="$TMPDIR_TEST/seg11"
mkdir -p "$SEG_DIR_11/src"
echo "alpha file" > "$SEG_DIR_11/src/a.txt"
echo "beta file"  > "$SEG_DIR_11/src/b.txt"
dd if=/dev/urandom of="$SEG_DIR_11/src/big.bin" bs=4096 count=4 2>/dev/null

if "$BLAR" create "$SEG_DIR_11/src" -o "$SEG_DIR_11/out.blar" --segment-size=2048 >/dev/null 2>&1; then
  pass "blar create --segment-size exits 0"
else
  fail "blar create --segment-size did not exit 0"
fi

# Bare archive should NOT exist (only segments)
if [[ ! -f "$SEG_DIR_11/out.blar" ]]; then
  pass "create --segment-size does not write the bare archive file"
else
  fail "create --segment-size also wrote the bare archive (should write only .seg)"
fi

# At least one .seg file should exist
seg_files=$(ls "$SEG_DIR_11"/out.blar.*.seg 2>/dev/null | wc -l | tr -d ' ')
if [[ "$seg_files" -ge 1 ]]; then
  pass "create --segment-size wrote $seg_files .seg files"
else
  fail "create --segment-size produced no .seg files"
fi

# Joining the segments and listing the result should yield a working archive
"$BLAR" join "$SEG_DIR_11"/out.blar.*-of-*.seg -o "$SEG_DIR_11/rejoined.blar" >/dev/null 2>&1 || \
  "$BLAR" join $(ls "$SEG_DIR_11"/out.blar.*-of-*.seg | head -1) -o "$SEG_DIR_11/rejoined.blar" >/dev/null 2>&1
if [[ -f "$SEG_DIR_11/rejoined.blar" ]] && "$BLAR" list "$SEG_DIR_11/rejoined.blar" >/dev/null 2>&1; then
  pass "rejoined archive is listable"
else
  fail "rejoined archive could not be listed"
fi

# Extract the rejoined archive and verify a known file matches.
# (Archive paths reflect the absolute input path; locate by basename.)
EXTRACT_DIR_11="$SEG_DIR_11/extracted"
mkdir -p "$EXTRACT_DIR_11"
"$BLAR" extract "$SEG_DIR_11/rejoined.blar" -C "$EXTRACT_DIR_11" >/dev/null 2>&1
extracted_a=$(find "$EXTRACT_DIR_11" -type f -name a.txt | head -1)
if [[ -n "$extracted_a" ]] && cmp -s "$SEG_DIR_11/src/a.txt" "$extracted_a"; then
  pass "extracted file from rejoined archive matches original"
else
  fail "extracted file from rejoined archive does not match"
fi

# ----- 14. blar create --segment-count produces exactly N .seg files -----
SEG_DIR_12="$TMPDIR_TEST/seg12"
mkdir -p "$SEG_DIR_12/src"
dd if=/dev/urandom of="$SEG_DIR_12/src/data.bin" bs=2048 count=5 2>/dev/null

"$BLAR" create "$SEG_DIR_12/src" -o "$SEG_DIR_12/out.blar" --segment-count=3 >/dev/null 2>&1
seg_count_actual=$(ls "$SEG_DIR_12"/out.blar.*-of-3.seg 2>/dev/null | wc -l | tr -d ' ')
if [[ "$seg_count_actual" == "3" ]]; then
  pass "create --segment-count=3 produces exactly 3 segments"
else
  fail "create --segment-count=3 produced $seg_count_actual segments"
fi

# ----- 15. create rejects --segment-size combined with --segment-count -----
SEG_DIR_13="$TMPDIR_TEST/seg13"
mkdir -p "$SEG_DIR_13/src"
echo "x" > "$SEG_DIR_13/src/a.txt"
if "$BLAR" create "$SEG_DIR_13/src" -o "$SEG_DIR_13/out.blar" --segment-size=128 --segment-count=4 >/dev/null 2>&1; then
  fail "create accepted both --segment-size AND --segment-count"
else
  pass "create rejects --segment-size combined with --segment-count"
fi

# ----- 16. Layer 5c: list/extract/verify/info on a segment file -----
SEG_DIR_14="$TMPDIR_TEST/seg14"
mkdir -p "$SEG_DIR_14/src"
echo "alpha file" > "$SEG_DIR_14/src/a.txt"
echo "beta file"  > "$SEG_DIR_14/src/b.txt"
dd if=/dev/urandom of="$SEG_DIR_14/src/big.bin" bs=4096 count=2 2>/dev/null
"$BLAR" create "$SEG_DIR_14/src" -o "$SEG_DIR_14/out.blar" --segment-count=4 >/dev/null 2>&1
seg_first=$(ls "$SEG_DIR_14"/out.blar.*-of-4.seg | head -1)

if "$BLAR" list "$seg_first" >/dev/null 2>&1; then
  pass "blar list works directly on a segment file"
else
  fail "blar list rejected a segment file"
fi

if "$BLAR" verify "$seg_first" >/dev/null 2>&1; then
  pass "blar verify works directly on a segment file"
else
  fail "blar verify rejected a segment file"
fi

if "$BLAR" info "$seg_first" >/dev/null 2>&1; then
  pass "blar info works directly on a segment file"
else
  fail "blar info rejected a segment file"
fi

EXTRACT_DIR_14="$SEG_DIR_14/extracted"
mkdir -p "$EXTRACT_DIR_14"
"$BLAR" extract "$seg_first" -C "$EXTRACT_DIR_14" >/dev/null 2>&1
extracted_a14=$(find "$EXTRACT_DIR_14" -type f -name a.txt | head -1)
if [[ -n "$extracted_a14" ]] && cmp -s "$SEG_DIR_14/src/a.txt" "$extracted_a14"; then
  pass "blar extract works directly on a segment file"
else
  fail "blar extract from segment file did not produce expected content"
fi

# Also confirm a *middle* segment opens the archive (not just the first)
seg_middle=$(ls "$SEG_DIR_14"/out.blar.*-of-4.seg | sed -n '3p')
if [[ -n "$seg_middle" ]] && "$BLAR" list "$seg_middle" >/dev/null 2>&1; then
  pass "blar list works on a non-first segment file (open-any-segment-opens-archive)"
else
  fail "blar list rejected a non-first segment file"
fi
# Summary
# =============================================================================
echo ""
echo "Segmentation tests: $PASS passed, $FAIL failed"
exit $FAIL
