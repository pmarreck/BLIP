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

# ── from-text round-trip tests ─────────────────────────────────────────

echo ""
echo "=== from-text round-trip tests ==="

# Round-trip: flat archive → text → from-text → extract → compare
# Note: text form uses basenames, so the round-tripped archive has short paths.
# We compare using cat instead of extracting to filesystem.
$BLAR from-text "$TMPDIR/test.blar.txt" -o "$TMPDIR/roundtrip.blar"

# Verify the round-tripped archive lists same basenames
$BLAR list "$TMPDIR/roundtrip.blar" > "$TMPDIR/rt_list.txt"
grep -q 'hello.txt' "$TMPDIR/rt_list.txt" || { echo "FAIL: roundtrip missing hello.txt"; exit 1; }
grep -q 'random.bin' "$TMPDIR/rt_list.txt" || { echo "FAIL: roundtrip missing random.bin"; exit 1; }

# Compare file contents via cat
$BLAR cat "$TMPDIR/roundtrip.blar" hello.txt > "$TMPDIR/rt_hello.txt"
echo "hello world" | diff - "$TMPDIR/rt_hello.txt" || { echo "FAIL: hello.txt content differs"; exit 1; }

# Compare binary file via cat
$BLAR cat "$TMPDIR/test.blar" "$($BLAR list "$TMPDIR/test.blar" | grep random.bin | sed 's/^- //')" > "$TMPDIR/orig_random.bin"
$BLAR cat "$TMPDIR/roundtrip.blar" random.bin > "$TMPDIR/rt_random.bin"
cmp "$TMPDIR/orig_random.bin" "$TMPDIR/rt_random.bin" || { echo "FAIL: random.bin content differs"; exit 1; }

echo "PASS: flat archive round-trip"

# Round-trip: nested directory archive → text → from-text → extract → compare
$BLAR from-text "$TMPDIR/nested.txt" -o "$TMPDIR/nested_rt.blar"

mkdir -p "$TMPDIR/nested_rt"
$BLAR extract "$TMPDIR/nested_rt.blar" -C "$TMPDIR/nested_rt"

diff <(echo "nested") "$TMPDIR/nested_rt/subdir/nested.txt" || { echo "FAIL: nested.txt differs"; exit 1; }

echo "PASS: nested directory round-trip"

# Round-trip: deeply nested directory
mkdir -p "$TMPDIR/deep/a/b/c"
echo "deep content" > "$TMPDIR/deep/a/b/c/leaf.txt"
echo "mid content" > "$TMPDIR/deep/a/mid.txt"
$BLAR create "$TMPDIR/deep.blar" "$TMPDIR/deep"
$BLAR text "$TMPDIR/deep.blar" > "$TMPDIR/deep.txt"
$BLAR from-text "$TMPDIR/deep.txt" -o "$TMPDIR/deep_rt.blar"

mkdir -p "$TMPDIR/deep_rt"
$BLAR extract "$TMPDIR/deep_rt.blar" -C "$TMPDIR/deep_rt"

diff <(echo "deep content") "$TMPDIR/deep_rt/deep/a/b/c/leaf.txt" || { echo "FAIL: deep leaf.txt differs"; exit 1; }
diff <(echo "mid content") "$TMPDIR/deep_rt/deep/a/mid.txt" || { echo "FAIL: mid.txt differs"; exit 1; }

echo "PASS: deeply nested directory round-trip"

# Round-trip with compression (-z)
$BLAR from-text "$TMPDIR/test.blar.txt" -o "$TMPDIR/roundtrip_z.blar" -z

$BLAR cat "$TMPDIR/roundtrip_z.blar" hello.txt > "$TMPDIR/rt_z_hello.txt"
echo "hello world" | diff - "$TMPDIR/rt_z_hello.txt" || { echo "FAIL: hello.txt differs (compressed)"; exit 1; }

echo "PASS: compressed from-text round-trip"

# Double round-trip: archive → text → from-text → text → compare texts
$BLAR text "$TMPDIR/roundtrip.blar" > "$TMPDIR/roundtrip_text2.txt"
diff "$TMPDIR/test.blar.txt" "$TMPDIR/roundtrip_text2.txt" || { echo "FAIL: double text round-trip differs"; exit 1; }

echo "PASS: double text round-trip (text->binary->text is stable)"

echo ""
echo "PASS: all blar from-text round-trip tests"
