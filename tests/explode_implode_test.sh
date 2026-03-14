#!/usr/bin/env bash
set -euo pipefail

BLAR="${BLAR:-blar}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create test files
mkdir -p "$TMPDIR/src"
echo "hello world" > "$TMPDIR/src/hello.txt"
mkdir -p "$TMPDIR/src/subdir"
echo "nested" > "$TMPDIR/src/subdir/nested.txt"

# Create archive from relative paths by cd'ing into src
(cd "$TMPDIR/src" && $BLAR create "$TMPDIR/test.blar" hello.txt subdir)

# Explode to directory tree
$BLAR explode "$TMPDIR/test.blar" -C "$TMPDIR/tree"

# Should have files
test -f "$TMPDIR/tree/hello.txt" || { echo "FAIL: hello.txt missing"; exit 1; }
test -f "$TMPDIR/tree/subdir/nested.txt" || { echo "FAIL: nested.txt missing"; exit 1; }

# File content should match
diff <(echo "hello world") "$TMPDIR/tree/hello.txt" || { echo "FAIL: hello.txt content"; exit 1; }
diff <(echo "nested") "$TMPDIR/tree/subdir/nested.txt" || { echo "FAIL: nested.txt content"; exit 1; }

# Should have metadata sidecar
test -f "$TMPDIR/tree/__meta__.json" || { echo "FAIL: __meta__.json missing"; exit 1; }

# Metadata should be valid JSON-ish (has opening brace)
head -c 1 "$TMPDIR/tree/__meta__.json" | grep -q '{' || { echo "FAIL: __meta__.json not JSON"; exit 1; }

echo "PASS: blar explode basic"

# Test compressed archive
(cd "$TMPDIR/src" && $BLAR create -z "$TMPDIR/test_z.blar" hello.txt)
$BLAR explode "$TMPDIR/test_z.blar" -C "$TMPDIR/tree_z"
test -f "$TMPDIR/tree_z/hello.txt" || { echo "FAIL: compressed explode"; exit 1; }

echo "PASS: blar explode compressed"

# Test that subdirectory has its own __meta__.json
test -f "$TMPDIR/tree/subdir/__meta__.json" || { echo "FAIL: subdir __meta__.json missing"; exit 1; }
head -c 1 "$TMPDIR/tree/subdir/__meta__.json" | grep -q '{' || { echo "FAIL: subdir __meta__.json not JSON"; exit 1; }

echo "PASS: blar explode nested metadata"

# Test mode is preserved in metadata JSON
grep -q '"mode"' "$TMPDIR/tree/__meta__.json" || { echo "FAIL: mode not in __meta__.json"; exit 1; }
grep -q '"mtime"' "$TMPDIR/tree/__meta__.json" || { echo "FAIL: mtime not in __meta__.json"; exit 1; }

echo "PASS: blar explode metadata fields"

echo ""
echo "All explode tests passed."
