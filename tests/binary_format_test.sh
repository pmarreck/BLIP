#!/usr/bin/env bash
set -u

# =============================================================================
# Binary format assertion tests for blar/miniblar
# =============================================================================
# These tests verify structural properties of the binary format:
# sentinel bytes (ARRAY, FILE, DIR, DATA), 2-char key names, content integrity.
# Since archives now include environment-specific metadata (mtime, uid, etc.),
# exact byte comparison is limited to structural invariants.
# =============================================================================

# --------------- paths ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MINIBLAR="$PROJECT_DIR/zig-out/bin/miniblar"
BLAR="$PROJECT_DIR/zig-out/bin/blar"

# --------------- paths: printable-binary (vendored, built by zig build) ---------------
PB="$PROJECT_DIR/zig-out/bin/printable-binary"

# --------------- build ---------------
echo "Building blar, miniblar, and printable-binary..."
(cd "$PROJECT_DIR" && nix develop -c zig build -Doptimize=ReleaseFast) \
  || { echo "FATAL: build failed"; exit 1; }

if [[ ! -x "$MINIBLAR" ]]; then
  echo "FATAL: miniblar binary not found at $MINIBLAR"
  exit 1
fi

if [[ ! -x "$BLAR" ]]; then
  echo "FATAL: blar binary not found at $BLAR"
  exit 1
fi

if [[ ! -x "$PB" ]]; then
  echo "FATAL: printable-binary not found at $PB"
  exit 1
fi

# --------------- temp dir + cleanup ---------------
# We use a FIXED path /tmp/bft/ so that archived paths are deterministic.
# Paths are normalized (leading / stripped), so stored as "tmp/bft/...".
BFT="/tmp/bft"
cleanup() {
  rm -rf "$BFT"
}
trap cleanup EXIT
cleanup  # start clean

# --------------- counters ---------------
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

# =============================================================================
# MINIBLAR FORMAT TESTS (structural — metadata varies by environment)
# =============================================================================
# Since miniblar now includes file metadata (mode, mtime, uid, gid, username),
# exact byte comparison is not deterministic across environments. Instead we
# check structural properties: sentinels, key names, content integrity.

# --------------- Test 1: Single file archive structural checks ---------------
mkdir -p "$BFT"
echo -n "hello" > "$BFT/a.txt"
"$MINIBLAR" create -o "$BFT/single.blip" "$BFT/a.txt" 2>/dev/null

RAW_HEX=$(xxd -p "$BFT/single.blip" | tr -d '\n')

# In v2 LP format, containers use TYPE attribute (0x81 0x01) followed by type ID.
# FILE type ID = 5, so look for TYPE attr + file ID: 81 01 05
if [[ "$RAW_HEX" == *"810105"* ]]; then
  pass "miniblar single file: FILE type (TYPE attr 0x81 0x01 + ID 0x05) present"
else
  fail "miniblar single file: FILE type not found"
fi

# DATA type ID = 4, so look for TYPE attr + data ID: 81 01 04
if [[ "$RAW_HEX" == *"810104"* ]]; then
  pass "miniblar single file: DATA type (TYPE attr 0x81 0x01 + ID 0x04) present"
else
  fail "miniblar single file: DATA type not found"
fi

# Verify roundtrip works
"$MINIBLAR" verify "$BFT/single.blip" >/dev/null 2>&1 \
  && pass "miniblar single file: verify passes" \
  || fail "miniblar single file: verify failed"

# --------------- Test 2: Two file archive preserves caller order ---------------
cleanup && mkdir -p "$BFT"
echo -n "hello" > "$BFT/a.txt"
echo -n "world" > "$BFT/b.txt"
# Pass files in reverse alphabetical order — archive should preserve that order
"$MINIBLAR" create -o "$BFT/two.blip" "$BFT/b.txt" "$BFT/a.txt" 2>/dev/null

# Verify caller order preserved: b.txt should appear before a.txt
LIST_OUT=$("$MINIBLAR" list "$BFT/two.blip" 2>/dev/null)
FIRST_FILE=$(echo "$LIST_OUT" | head -1)
if echo "$FIRST_FILE" | grep -q "b.txt"; then
  pass "miniblar two files: caller order preserved (b.txt before a.txt)"
else
  fail "miniblar two files: caller order not preserved, first file: $FIRST_FILE"
fi

"$MINIBLAR" verify "$BFT/two.blip" >/dev/null 2>&1 \
  && pass "miniblar two files: verify passes" \
  || fail "miniblar two files: verify failed"

# --------------- Test 3: Empty content file structural checks ---------------
cleanup && mkdir -p "$BFT"
touch "$BFT/empty.txt"
"$MINIBLAR" create -o "$BFT/empty.blip" "$BFT/empty.txt" 2>/dev/null

# DATA type (TYPE attr 0x81 0x01 + ID 0x04) should be present even for empty content
RAW_HEX=$(xxd -p "$BFT/empty.blip" | tr -d '\n')
if [[ "$RAW_HEX" == *"810104"* ]]; then
  pass "miniblar empty file: DATA type present for empty content"
else
  fail "miniblar empty file: DATA type not found"
fi

"$MINIBLAR" verify "$BFT/empty.blip" >/dev/null 2>&1 \
  && pass "miniblar empty file: verify passes" \
  || fail "miniblar empty file: verify failed"

# --------------- Test 4: Magic bytes check (structural) ---------------
# In v2 LP format, archives start with BLIP(total_length), then have
# TYPE attribute (0x81 0x01) followed by array type ID (0x01).
# Magic "MBAR\x02" appears inside a DATA container element.
cleanup && mkdir -p "$BFT"
echo -n "hello" > "$BFT/a.txt"
"$MINIBLAR" create -o "$BFT/magic.blip" "$BFT/a.txt" 2>/dev/null

# Check that TYPE attr + array type ID (810101) appears in first ~10 bytes
FIRST_TEN=$(xxd -l 10 -p "$BFT/magic.blip")
if [[ "$FIRST_TEN" == *"810101"* ]]; then
  pass "miniblar magic: outer ARRAY type (0x81 0x01 0x01) in header"
else
  fail "miniblar magic: expected ARRAY type 810101 in header, got $FIRST_TEN"
fi

# Check that MBAR\x02 magic appears in the archive (hex: 4d42415202)
RAW_HEX=$(xxd -p "$BFT/magic.blip" | tr -d '\n')
if [[ "$RAW_HEX" == *"4d42415202"* ]]; then
  pass "miniblar magic: MBAR\\x02 magic bytes present"
else
  fail "miniblar magic: MBAR\\x02 magic bytes not found in archive"
fi

# =============================================================================
# BLAR FORMAT TESTS (structural — metadata varies by environment)
# =============================================================================

# --------------- Test 5: Archive header structure ---------------
cleanup && mkdir -p "$BFT/mydir"
echo -n "test" > "$BFT/mydir/file.txt"
"$BLAR" create -o "$BFT/blar.blar" "$BFT/mydir" 2>/dev/null

# Check that TYPE attr + array type ID (810101) appears in first ~10 bytes
FIRST_TEN=$(xxd -l 10 -p "$BFT/blar.blar")
if [[ "$FIRST_TEN" == *"810101"* ]]; then
  pass "blar header: outer ARRAY type (0x81 0x01 0x01) in header"
else
  fail "blar header: expected ARRAY type 810101 in header, got $FIRST_TEN"
fi

# Check that BLAR\x02 magic appears in the archive (hex: 424c415202)
RAW_BLAR_HEX_FULL=$(xxd -p "$BFT/blar.blar" | tr -d '\n')
PB_OUT="$($PB "$BFT/blar.blar" 2>/dev/null)"
if [[ "$RAW_BLAR_HEX_FULL" == *"424c415202"* ]]; then
  pass "blar header: BLAR\\x02 magic bytes present"
else
  fail "blar header: BLAR\\x02 magic bytes not found"
fi

# --------------- Test 6: DIR entry type present ---------------
# In v2 LP format, DIR type = TYPE attr (0x81 0x01) + dir ID (0x07) = 810107
RAW_BLAR_HEX=$(xxd -p "$BFT/blar.blar" | tr -d '\n')
if [[ "$RAW_BLAR_HEX" == *"810107"* ]]; then
  pass "blar structure: DIR type (0x81 0x01 0x07) present"
else
  fail "blar structure: DIR type not found"
fi

# --------------- Test 7: FILE entry type present ---------------
# In v2 LP format, FILE type = TYPE attr (0x81 0x01) + file ID (0x05) = 810105
if [[ "$RAW_BLAR_HEX" == *"810105"* ]]; then
  pass "blar structure: FILE type (0x81 0x01 0x05) present"
else
  fail "blar structure: FILE type not found"
fi

# --------------- Test 8: 2-char key names and DATA sentinel ---------------
# DIR entries use 2-char keys: md, mt, pa, un, xh
# FILE entries are ARRAY-based with metadata DICT + DATA container

# Check for DATA type (TYPE attr 0x81 0x01 + data ID 0x04) in FILE entries
if [[ "$RAW_BLAR_HEX" == *"810104"* ]]; then
  pass "blar structure: DATA type (0x81 0x01 0x04) present in FILE"
else
  fail "blar structure: DATA type not found"
fi

# Check that 2-char key "pa" is present (path key in both FILE metadata and DIR)
# "pa" = 0x70 0x61 (will appear as UTF8 container value)
if [[ "$PB_OUT" == *"pa"* ]]; then
  pass "blar keys: 2-char key 'pa' (path) present"
else
  fail "blar keys: missing 2-char key 'pa'"
fi

# Check that 2-char key "xh" is present (Merkle hash in DIR)
if [[ "$PB_OUT" == *"xh"* ]]; then
  pass "blar keys: 2-char key 'xh' (Merkle hash) present"
else
  fail "blar keys: missing 2-char key 'xh'"
fi

# Check that old key names are NOT present (regression check)
OLD_KEYS_ABSENT=true
for key in bina path xh64 mode mtime owner; do
  if [[ "$PB_OUT" == *"$key"* ]]; then
    OLD_KEYS_ABSENT=false
    fail "blar keys: old key '$key' still present (should use 2-char names)"
    break
  fi
done
if $OLD_KEYS_ABSENT; then
  pass "blar keys: no old-style key names present"
fi

# =============================================================================
# CROSS-TOOL COMPATIBILITY TESTS
# =============================================================================

# --------------- Test 9: miniblar archive readable by blar ---------------
cleanup && mkdir -p "$BFT"
echo -n "cross-tool test" > "$BFT/cross.txt"
"$MINIBLAR" create -o "$BFT/cross.blip" "$BFT/cross.txt" 2>/dev/null

if "$BLAR" verify "$BFT/cross.blip" >/dev/null 2>&1; then
  pass "cross-tool: miniblar archive verifiable by blar"
else
  fail "cross-tool: blar cannot verify miniblar archive"
fi

BLAR_LIST=$("$BLAR" list "$BFT/cross.blip" 2>/dev/null)
if echo "$BLAR_LIST" | grep -q "cross.txt"; then
  pass "cross-tool: miniblar archive listable by blar"
else
  fail "cross-tool: blar cannot list miniblar archive"
fi

# --------------- Test 10: blar file-only archive readable by miniblar ---------------
cleanup && mkdir -p "$BFT"
echo -n "blar-to-mini test" > "$BFT/compat.txt"
# blar with a single file (no directories) should produce a miniblar-compatible archive
"$BLAR" create -o "$BFT/compat.blar" "$BFT/compat.txt" 2>/dev/null

if "$MINIBLAR" verify "$BFT/compat.blar" >/dev/null 2>&1; then
  pass "cross-tool: blar file-only archive verifiable by miniblar"
else
  fail "cross-tool: miniblar cannot verify blar file-only archive"
fi

MINI_LIST=$("$MINIBLAR" list "$BFT/compat.blar" 2>/dev/null)
if echo "$MINI_LIST" | grep -q "compat.txt"; then
  pass "cross-tool: blar file-only archive listable by miniblar"
else
  fail "cross-tool: miniblar cannot list blar file-only archive"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
