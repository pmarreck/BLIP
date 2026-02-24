#!/usr/bin/env bash
set -euo pipefail

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

# FILE sentinel (0x81 0x05) should be present (FILE is now ARRAY-based)
if [[ "$RAW_HEX" == *"8105"* ]]; then
  pass "miniblar single file: FILE sentinel (0x81 0x05) present"
else
  fail "miniblar single file: FILE sentinel not found"
fi

# DATA sentinel (0x81 0x08) should be present (content container)
if [[ "$RAW_HEX" == *"8108"* ]]; then
  pass "miniblar single file: DATA sentinel (0x81 0x08) present"
else
  fail "miniblar single file: DATA sentinel not found"
fi

# Verify roundtrip works
"$MINIBLAR" verify "$BFT/single.blip" >/dev/null 2>&1 \
  && pass "miniblar single file: verify passes" \
  || fail "miniblar single file: verify failed"

# --------------- Test 2: Two file archive with path sorting ---------------
cleanup && mkdir -p "$BFT"
echo -n "hello" > "$BFT/a.txt"
echo -n "world" > "$BFT/b.txt"
# Pass files in reverse alphabetical order — archive should sort them
"$MINIBLAR" create -o "$BFT/two.blip" "$BFT/b.txt" "$BFT/a.txt" 2>/dev/null

# Verify path sorting: a.txt should appear before b.txt in list output
LIST_OUT=$("$MINIBLAR" list "$BFT/two.blip" 2>/dev/null)
FIRST_FILE=$(echo "$LIST_OUT" | head -1)
if echo "$FIRST_FILE" | grep -q "a.txt"; then
  pass "miniblar two files: paths sorted (a.txt before b.txt)"
else
  fail "miniblar two files: paths not sorted, first file: $FIRST_FILE"
fi

"$MINIBLAR" verify "$BFT/two.blip" >/dev/null 2>&1 \
  && pass "miniblar two files: verify passes" \
  || fail "miniblar two files: verify failed"

# --------------- Test 3: Empty content file structural checks ---------------
cleanup && mkdir -p "$BFT"
touch "$BFT/empty.txt"
"$MINIBLAR" create -o "$BFT/empty.blip" "$BFT/empty.txt" 2>/dev/null

# DATA sentinel should be present even for empty content
RAW_HEX=$(xxd -p "$BFT/empty.blip" | tr -d '\n')
if [[ "$RAW_HEX" == *"8108"* ]]; then
  pass "miniblar empty file: DATA sentinel present for empty content"
else
  fail "miniblar empty file: DATA sentinel not found"
fi

"$MINIBLAR" verify "$BFT/empty.blip" >/dev/null 2>&1 \
  && pass "miniblar empty file: verify passes" \
  || fail "miniblar empty file: verify failed"

# --------------- Test 4: Magic bytes check (structural) ---------------
# Every archive starts with outer ARRAY sentinel 0x81 0x01
# and contains the magic RAW("BLIP\x01") somewhere early
cleanup && mkdir -p "$BFT"
echo -n "hello" > "$BFT/a.txt"
"$MINIBLAR" create -o "$BFT/magic.blip" "$BFT/a.txt" 2>/dev/null

# Check first 2 bytes are ARRAY sentinel
FIRST_TWO=$(xxd -l 2 -p "$BFT/magic.blip")
if [[ "$FIRST_TWO" == "8101" ]]; then
  pass "miniblar magic: outer ARRAY sentinel 0x81 0x01"
else
  fail "miniblar magic: expected ARRAY sentinel 0x8101, got 0x$FIRST_TWO"
fi

# Check that BLIP\x01 magic appears in the archive
PB_OUT="$($PB "$BFT/magic.blip" 2>/dev/null)"
if [[ "$PB_OUT" == *"BLIP¯"* ]]; then
  pass "miniblar magic: BLIP magic bytes present"
else
  fail "miniblar magic: BLIP magic bytes not found in archive"
fi

# =============================================================================
# BLAR FORMAT TESTS (structural — metadata varies by environment)
# =============================================================================

# --------------- Test 5: Archive header structure ---------------
cleanup && mkdir -p "$BFT/mydir"
echo -n "test" > "$BFT/mydir/file.txt"
"$BLAR" create -o "$BFT/blar.blar" "$BFT/mydir" 2>/dev/null

FIRST_TWO=$(xxd -l 2 -p "$BFT/blar.blar")
if [[ "$FIRST_TWO" == "8101" ]]; then
  pass "blar header: outer ARRAY sentinel 0x81 0x01"
else
  fail "blar header: expected ARRAY sentinel 0x8101, got 0x$FIRST_TWO"
fi

PB_OUT="$($PB "$BFT/blar.blar" 2>/dev/null)"
if [[ "$PB_OUT" == *"BLIP¯"* ]]; then
  pass "blar header: BLIP magic bytes present"
else
  fail "blar header: BLIP magic bytes not found"
fi

# --------------- Test 6: DIR entry sentinel present ---------------
# DIR sentinel in printable-binary is "Ăª" (0x81 0x07)
if [[ "$PB_OUT" == *"Ăª"* ]]; then
  pass "blar structure: DIR sentinel (0x81 0x07) present"
else
  fail "blar structure: DIR sentinel not found"
fi

# --------------- Test 7: FILE entry sentinel present ---------------
# FILE sentinel in printable-binary is "Ă¿" (0x81 0x05)
if [[ "$PB_OUT" == *"Ă¿"* ]]; then
  pass "blar structure: FILE sentinel (0x81 0x05) present"
else
  fail "blar structure: FILE sentinel not found"
fi

# --------------- Test 8: 2-char key names and DATA sentinel ---------------
# DIR entries use 2-char keys: md, mt, pa, un, xh
# FILE entries are ARRAY-based with metadata DICT + DATA container

RAW_BLAR_HEX=$(xxd -p "$BFT/blar.blar" | tr -d '\n')

# Check for DATA sentinel (0x81 0x08) in FILE entries
if [[ "$RAW_BLAR_HEX" == *"8108"* ]]; then
  pass "blar structure: DATA sentinel (0x81 0x08) present in FILE"
else
  fail "blar structure: DATA sentinel not found"
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
