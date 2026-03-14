#!/usr/bin/env bash
set -euo pipefail

BLAR="${BLAR:-blar}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create a simple archive
echo "hello world" > "$TMPDIR/hello.txt"
dd if=/dev/urandom bs=64 count=1 of="$TMPDIR/random.bin" 2>/dev/null

$BLAR create "$TMPDIR/test.blar" "$TMPDIR/hello.txt" "$TMPDIR/random.bin"

# Text dump should produce valid output
$BLAR text "$TMPDIR/test.blar" > "$TMPDIR/test.blar.txt"

# Should start with BLAR/1 header
head -1 "$TMPDIR/test.blar.txt" | grep -q "^BLAR/1$" || { echo "FAIL: missing header"; exit 1; }

# Should contain FILE entries
grep -q 'FILE "hello.txt"' "$TMPDIR/test.blar.txt" || { echo "FAIL: missing hello.txt"; exit 1; }
grep -q 'FILE "random.bin"' "$TMPDIR/test.blar.txt" || { echo "FAIL: missing random.bin"; exit 1; }

# Should contain printable-binary payload lines (wrapped in |...|)
grep -q '|.*|' "$TMPDIR/test.blar.txt" || { echo "FAIL: missing payload delimiters"; exit 1; }

# Test -o flag for output to file
$BLAR text "$TMPDIR/test.blar" -o "$TMPDIR/test_out.txt"
diff "$TMPDIR/test.blar.txt" "$TMPDIR/test_out.txt" || { echo "FAIL: -o output differs from stdout"; exit 1; }

# Test with compressed archive
$BLAR create -z "$TMPDIR/test_z.blar" "$TMPDIR/hello.txt"
$BLAR text "$TMPDIR/test_z.blar" > "$TMPDIR/test_z.txt"
head -1 "$TMPDIR/test_z.txt" | grep -q "^BLAR/1$" || { echo "FAIL: compressed header"; exit 1; }

# Test with nested directory
mkdir -p "$TMPDIR/subdir"
echo "nested" > "$TMPDIR/subdir/nested.txt"
$BLAR create "$TMPDIR/nested.blar" "$TMPDIR/subdir"
$BLAR text "$TMPDIR/nested.blar" > "$TMPDIR/nested.txt"
grep -q 'DIR "subdir/"' "$TMPDIR/nested.txt" || { echo "FAIL: missing DIR"; exit 1; }
# Nested file should be indented
grep -q '  FILE "nested.txt"' "$TMPDIR/nested.txt" || { echo "FAIL: missing indented nested file"; exit 1; }

echo "PASS: all blar text tests"
