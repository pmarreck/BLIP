#!/usr/bin/env bash
set -u

# =============================================================================
# poke integration test suite
# =============================================================================
# Exercises the poke command in both blar and miniblar CLIs: content replacement,
# metadata modification, output options, backup, error handling, and integrity.
# =============================================================================

# --------------- paths ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"
MINIBLAR="$PROJECT_DIR/zig-out/bin/miniblar"

# --------------- build ---------------
echo "Building blar + miniblar..."
(cd "$PROJECT_DIR" && nix develop -c zig build -Doptimize=ReleaseFast) \
  || { echo "FATAL: build failed"; exit 1; }

for bin in "$BLAR" "$MINIBLAR"; do
  if [[ ! -x "$bin" ]]; then
    echo "FATAL: binary not found at $bin"
    exit 1
  fi
done

# --------------- temp dir + cleanup ---------------
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

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

# --------------- create test fixtures ---------------
echo -n "hello" > "$TMPDIR_TEST/a.txt"
echo -n "world" > "$TMPDIR_TEST/b.txt"
echo -n "third" > "$TMPDIR_TEST/c.txt"

# Single-file archive
"$BLAR" create -o "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/a.txt" 2>/dev/null

# Multi-file archive
"$BLAR" create -o "$TMPDIR_TEST/multi.blar" \
  "$TMPDIR_TEST/a.txt" "$TMPDIR_TEST/b.txt" "$TMPDIR_TEST/c.txt" 2>/dev/null

# =============================================================================
# 1. Basic content poke via stdin
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke1.blar"
echo -n "world" | "$BLAR" poke "$TMPDIR_TEST/poke1.blar" "[1][0][1]"
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke1.blar" "[1][0][1]" --raw)
[[ "$OUT" == "world" ]] && pass "poke content via stdin" || fail "poke stdin: got '$OUT'"

# =============================================================================
# 2. Verify content changed via peek
# =============================================================================

# Already verified above -- check path is still intact
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke1.blar" "[1][0][0][pa]")
[[ "$OUT" == *"a.txt"* ]] && pass "path preserved after poke" || fail "path after poke: got '$OUT'"

# =============================================================================
# 3. Verify archive integrity after poke
# =============================================================================

"$BLAR" verify "$TMPDIR_TEST/poke1.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "integrity OK after content poke" || fail "integrity failed after poke"

# =============================================================================
# 4. --value flag
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke4.blar"
"$BLAR" poke "$TMPDIR_TEST/poke4.blar" "[1][0][1]" --value "goodbye"
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke4.blar" "[1][0][1]" --raw)
[[ "$OUT" == "goodbye" ]] && pass "--value flag" || fail "--value: got '$OUT'"

# =============================================================================
# 5. Metadata poke: rename file path
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke5.blar"
"$BLAR" poke "$TMPDIR_TEST/poke5.blar" "[1][0][0][pa]" --value "renamed.txt"
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke5.blar" "[1][0][0][pa]")
[[ "$OUT" == "renamed.txt" ]] && pass "metadata poke: rename path" || fail "rename path: got '$OUT'"

# Integrity should still be OK
"$BLAR" verify "$TMPDIR_TEST/poke5.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "integrity OK after path rename" || fail "integrity failed after rename"

# =============================================================================
# 6. -i flag (value from file)
# =============================================================================

echo -n "from-file-content" > "$TMPDIR_TEST/newval.bin"
cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke6.blar"
"$BLAR" poke "$TMPDIR_TEST/poke6.blar" "[1][0][1]" -i "$TMPDIR_TEST/newval.bin"
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke6.blar" "[1][0][1]" --raw)
[[ "$OUT" == "from-file-content" ]] && pass "-i flag (value from file)" || fail "-i flag: got '$OUT'"

# =============================================================================
# 7. -o flag (output to different file)
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke7.blar"
"$BLAR" poke "$TMPDIR_TEST/poke7.blar" "[1][0][1]" --value "changed" -o "$TMPDIR_TEST/poke7_out.blar"

# Original should be unchanged
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke7.blar" "[1][0][1]" --raw)
[[ "$OUT" == "hello" ]] && pass "-o: original unchanged" || fail "-o original: got '$OUT'"

# Output should have new value
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke7_out.blar" "[1][0][1]" --raw)
[[ "$OUT" == "changed" ]] && pass "-o: output has new value" || fail "-o output: got '$OUT'"

# =============================================================================
# 8. Empty value is allowed
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke8.blar"
"$BLAR" poke "$TMPDIR_TEST/poke8.blar" "[1][0][1]" --value ""
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke8.blar" "[1][0][1]" --raw)
[[ "$OUT" == "" ]] && pass "empty value poke" || fail "empty value: got '$OUT'"

"$BLAR" verify "$TMPDIR_TEST/poke8.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "integrity OK after empty poke" || fail "integrity failed after empty poke"

# =============================================================================
# 9. Error: poke on non-leaf container [1][0]
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke9.blar"
if "$BLAR" poke "$TMPDIR_TEST/poke9.blar" "[1][0]" --value "x" 2>/dev/null; then
  fail "poke on non-leaf should fail"
else
  pass "poke on non-leaf [1][0] returns error"
fi

# =============================================================================
# 10. Error: poke on magic bytes [0]
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke10.blar"
if "$BLAR" poke "$TMPDIR_TEST/poke10.blar" "[0]" --value "x" 2>/dev/null; then
  fail "poke on magic should fail"
else
  pass "poke on magic [0] returns error"
fi

# =============================================================================
# 11. Error: invalid/OOB path [99]
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke11.blar"
if "$BLAR" poke "$TMPDIR_TEST/poke11.blar" "[99]" --value "x" 2>/dev/null; then
  fail "poke on OOB path should fail"
else
  pass "poke on OOB path [99] returns error"
fi

# =============================================================================
# 12. Multi-file: poke one file, verify others unchanged, verify integrity
# =============================================================================

cp "$TMPDIR_TEST/multi.blar" "$TMPDIR_TEST/poke12.blar"

# Get original content of files 0 and 2 (sorted order)
ORIG0=$("$BLAR" peek "$TMPDIR_TEST/poke12.blar" "[1][0][1]" --raw)
ORIG2=$("$BLAR" peek "$TMPDIR_TEST/poke12.blar" "[1][2][1]" --raw)

# Poke file 1
"$BLAR" poke "$TMPDIR_TEST/poke12.blar" "[1][1][1]" --value "MODIFIED"
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke12.blar" "[1][1][1]" --raw)
[[ "$OUT" == "MODIFIED" ]] && pass "multi-file: poked file changed" || fail "multi-file poke: got '$OUT'"

# Other files should be unchanged
OUT0=$("$BLAR" peek "$TMPDIR_TEST/poke12.blar" "[1][0][1]" --raw)
OUT2=$("$BLAR" peek "$TMPDIR_TEST/poke12.blar" "[1][2][1]" --raw)
[[ "$OUT0" == "$ORIG0" && "$OUT2" == "$ORIG2" ]] \
  && pass "multi-file: other files unchanged" || fail "multi-file others: '$OUT0' '$OUT2'"

# Integrity
"$BLAR" verify "$TMPDIR_TEST/poke12.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "multi-file: integrity OK after poke" || fail "multi-file integrity failed"

# =============================================================================
# 13. --help shows usage
# =============================================================================

OUT=$("$BLAR" poke --help 2>&1)
[[ "$OUT" == *"poke"* && "$OUT" == *"Usage"* ]] && pass "poke --help" || fail "poke --help: got '$OUT'"

# =============================================================================
# 14. miniblar poke works too
# =============================================================================

# Create a miniblar-style archive (single file, flat)
"$MINIBLAR" create -o "$TMPDIR_TEST/mini.blar" "$TMPDIR_TEST/a.txt" 2>/dev/null
cp "$TMPDIR_TEST/mini.blar" "$TMPDIR_TEST/poke14.blar"
"$MINIBLAR" poke "$TMPDIR_TEST/poke14.blar" "[1][0][1]" --value "poked-mini"
OUT=$("$MINIBLAR" peek "$TMPDIR_TEST/poke14.blar" "[1][0][1]" --raw)
[[ "$OUT" == "poked-mini" ]] && pass "miniblar poke works" || fail "miniblar poke: got '$OUT'"

"$MINIBLAR" verify "$TMPDIR_TEST/poke14.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "miniblar poke: integrity OK" || fail "miniblar poke integrity failed"

# =============================================================================
# 15. --backup creates .bak before overwriting
# =============================================================================

cp "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/poke15.blar"
ORIG_MD5=$(md5sum "$TMPDIR_TEST/poke15.blar" 2>/dev/null | cut -d' ' -f1 || md5 -q "$TMPDIR_TEST/poke15.blar")
"$BLAR" poke "$TMPDIR_TEST/poke15.blar" "[1][0][1]" --value "backup-test" --backup

if [[ -f "$TMPDIR_TEST/poke15.blar.bak" ]]; then
  BAK_MD5=$(md5sum "$TMPDIR_TEST/poke15.blar.bak" 2>/dev/null | cut -d' ' -f1 || md5 -q "$TMPDIR_TEST/poke15.blar.bak")
  [[ "$ORIG_MD5" == "$BAK_MD5" ]] && pass "--backup creates .bak" || fail "--backup: .bak content differs"
else
  fail "--backup: .bak file not created"
fi

# New file should have the poked value
OUT=$("$BLAR" peek "$TMPDIR_TEST/poke15.blar" "[1][0][1]" --raw)
[[ "$OUT" == "backup-test" ]] && pass "--backup: new value in place" || fail "--backup new value: got '$OUT'"

# =============================================================================
# Results
# =============================================================================

echo
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ "$FAIL" -eq 0 ]] || exit 1
