#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Comprehensive integration tests for the tri-representation system
# Tests cross-command interaction: blar text, from-text, explode, implode
# =============================================================================

BLAR="${BLAR:-$PWD/zig-out/bin/blar}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [[ ! -x "$BLAR" ]]; then
  echo "FATAL: blar binary not found at $BLAR"
  exit 1
fi

echo "=== Tri-representation integration tests ==="
echo ""

# ── Setup: create test data ──────────────────────────────────────────────────

mkdir -p "$TMPDIR/src/subdir/deep"
echo "hello world" > "$TMPDIR/src/hello.txt"
echo "nested content" > "$TMPDIR/src/subdir/nested.txt"
echo "deep content" > "$TMPDIR/src/subdir/deep/leaf.txt"
printf '' > "$TMPDIR/src/empty.txt"
dd if=/dev/urandom bs=4096 count=1 of="$TMPDIR/src/big_random.bin" 2>/dev/null

# Create base archives
(cd "$TMPDIR/src" && "$BLAR" create "$TMPDIR/flat.blar" hello.txt big_random.bin empty.txt)
(cd "$TMPDIR/src" && "$BLAR" create "$TMPDIR/nested.blar" hello.txt subdir)

# ── Test 1: Text header starts with BLAR/1 ──────────────────────────────────

"$BLAR" text "$TMPDIR/flat.blar" > "$TMPDIR/flat.txt"
head -1 "$TMPDIR/flat.txt" | grep -q "^BLAR/1$" \
  && pass "text header starts with BLAR/1" \
  || fail "text header starts with BLAR/1"

# ── Test 2: Text contains FILE entries ───────────────────────────────────────

grep -q 'FILE "hello.txt"' "$TMPDIR/flat.txt" \
  && pass "text contains FILE entries" \
  || fail "text contains FILE entries"

# ── Test 3: Text contains DIR entries with nested dirs ───────────────────────

"$BLAR" text "$TMPDIR/nested.blar" > "$TMPDIR/nested.txt"
grep -q 'DIR "subdir/"' "$TMPDIR/nested.txt" \
  && pass "text contains DIR entries" \
  || fail "text contains DIR entries"

# ── Test 4: Text round-trip flat archive ─────────────────────────────────────

"$BLAR" from-text "$TMPDIR/flat.txt" -o "$TMPDIR/rt_flat.blar"
"$BLAR" cat "$TMPDIR/rt_flat.blar" hello.txt > "$TMPDIR/rt_hello.txt"
echo "hello world" | diff - "$TMPDIR/rt_hello.txt" >/dev/null 2>&1 \
  && pass "text round-trip flat: hello.txt content preserved" \
  || fail "text round-trip flat: hello.txt content preserved"

# ── Test 5: Text round-trip nested directory ─────────────────────────────────

"$BLAR" from-text "$TMPDIR/nested.txt" -o "$TMPDIR/rt_nested.blar"
mkdir -p "$TMPDIR/rt_nested_out"
"$BLAR" extract "$TMPDIR/rt_nested.blar" -C "$TMPDIR/rt_nested_out"
diff <(echo "nested content") "$TMPDIR/rt_nested_out/subdir/nested.txt" >/dev/null 2>&1 \
  && pass "text round-trip nested: nested.txt content preserved" \
  || fail "text round-trip nested: nested.txt content preserved"

# ── Test 6: Text round-trip binary data ──────────────────────────────────────

"$BLAR" cat "$TMPDIR/rt_flat.blar" big_random.bin > "$TMPDIR/rt_random.bin"
cmp "$TMPDIR/src/big_random.bin" "$TMPDIR/rt_random.bin" >/dev/null 2>&1 \
  && pass "text round-trip binary: 4KB random data preserved exactly" \
  || fail "text round-trip binary: 4KB random data preserved exactly"

# ── Test 7: Text round-trip with -z (compressed from-text output) ────────────

"$BLAR" from-text "$TMPDIR/flat.txt" -o "$TMPDIR/rt_z.blar" -z
"$BLAR" cat "$TMPDIR/rt_z.blar" hello.txt > "$TMPDIR/rt_z_hello.txt"
echo "hello world" | diff - "$TMPDIR/rt_z_hello.txt" >/dev/null 2>&1 \
  && pass "text round-trip with -z: content preserved" \
  || fail "text round-trip with -z: content preserved"

# ── Test 8: Text stability (text -> binary -> text produces same text) ───────

"$BLAR" text "$TMPDIR/rt_flat.blar" > "$TMPDIR/rt_flat_text2.txt"
diff "$TMPDIR/flat.txt" "$TMPDIR/rt_flat_text2.txt" >/dev/null 2>&1 \
  && pass "text stability: text -> binary -> text is identical" \
  || fail "text stability: text -> binary -> text is identical"

# ── Test 9: Explode creates correct file paths ──────────────────────────────

"$BLAR" explode "$TMPDIR/nested.blar" -C "$TMPDIR/exploded"
test -f "$TMPDIR/exploded/hello.txt" && test -f "$TMPDIR/exploded/subdir/nested.txt" \
  && pass "explode creates correct file paths" \
  || fail "explode creates correct file paths"

# ── Test 10: Explode creates __meta__.json ───────────────────────────────────

test -f "$TMPDIR/exploded/__meta__.json" \
  && pass "explode creates __meta__.json in root" \
  || fail "explode creates __meta__.json in root"

test -f "$TMPDIR/exploded/subdir/__meta__.json" \
  && pass "explode creates __meta__.json in subdirectory" \
  || fail "explode creates __meta__.json in subdirectory"

# ── Test 11: Explode preserves file content ──────────────────────────────────

diff <(echo "hello world") "$TMPDIR/exploded/hello.txt" >/dev/null 2>&1 \
  && pass "explode preserves file content" \
  || fail "explode preserves file content"

diff <(echo "nested content") "$TMPDIR/exploded/subdir/nested.txt" >/dev/null 2>&1 \
  && pass "explode preserves nested file content" \
  || fail "explode preserves nested file content"

# ── Test 12: Explode/implode round-trip ──────────────────────────────────────

"$BLAR" implode "$TMPDIR/exploded" -o "$TMPDIR/reimploded.blar"
mkdir -p "$TMPDIR/reimploded_out" "$TMPDIR/orig_nested_out"
"$BLAR" extract "$TMPDIR/reimploded.blar" -C "$TMPDIR/reimploded_out"
"$BLAR" extract "$TMPDIR/nested.blar" -C "$TMPDIR/orig_nested_out"
diff "$TMPDIR/orig_nested_out/hello.txt" "$TMPDIR/reimploded_out/hello.txt" >/dev/null 2>&1 \
  && diff "$TMPDIR/orig_nested_out/subdir/nested.txt" "$TMPDIR/reimploded_out/subdir/nested.txt" >/dev/null 2>&1 \
  && pass "explode/implode round-trip: content matches" \
  || fail "explode/implode round-trip: content matches"

# ── Test 13: Explode/implode with -z (compressed) ───────────────────────────

"$BLAR" implode "$TMPDIR/exploded" -o "$TMPDIR/reimploded_z.blar" -z
mkdir -p "$TMPDIR/reimploded_z_out"
"$BLAR" extract "$TMPDIR/reimploded_z.blar" -C "$TMPDIR/reimploded_z_out"
diff "$TMPDIR/orig_nested_out/hello.txt" "$TMPDIR/reimploded_z_out/hello.txt" >/dev/null 2>&1 \
  && pass "explode/implode with -z: content preserved" \
  || fail "explode/implode with -z: content preserved"

# ── Test 14: Mixed workflow: text -> from-text -> explode -> implode -> extract -> compare

"$BLAR" text "$TMPDIR/nested.blar" > "$TMPDIR/mix_text.txt"
"$BLAR" from-text "$TMPDIR/mix_text.txt" -o "$TMPDIR/mix_fromtext.blar"
"$BLAR" explode "$TMPDIR/mix_fromtext.blar" -C "$TMPDIR/mix_exploded"
"$BLAR" implode "$TMPDIR/mix_exploded" -o "$TMPDIR/mix_imploded.blar"
mkdir -p "$TMPDIR/mix_final_out"
"$BLAR" extract "$TMPDIR/mix_imploded.blar" -C "$TMPDIR/mix_final_out"
diff <(echo "hello world") "$TMPDIR/mix_final_out/hello.txt" >/dev/null 2>&1 \
  && diff <(echo "nested content") "$TMPDIR/mix_final_out/subdir/nested.txt" >/dev/null 2>&1 \
  && pass "mixed workflow: text -> from-text -> explode -> implode -> extract" \
  || fail "mixed workflow: text -> from-text -> explode -> implode -> extract"

# ── Test 15: Empty file survives round-trip ──────────────────────────────────

"$BLAR" cat "$TMPDIR/rt_flat.blar" empty.txt > "$TMPDIR/rt_empty.txt"
test ! -s "$TMPDIR/rt_empty.txt" \
  && pass "empty file survives text round-trip" \
  || fail "empty file survives text round-trip"

# Also test empty file through explode/implode
(cd "$TMPDIR/src" && "$BLAR" create "$TMPDIR/empty_archive.blar" empty.txt)
"$BLAR" explode "$TMPDIR/empty_archive.blar" -C "$TMPDIR/empty_exploded"
test -f "$TMPDIR/empty_exploded/empty.txt" && test ! -s "$TMPDIR/empty_exploded/empty.txt" \
  && pass "empty file survives explode" \
  || fail "empty file survives explode"

"$BLAR" implode "$TMPDIR/empty_exploded" -o "$TMPDIR/empty_reimploded.blar"
"$BLAR" cat "$TMPDIR/empty_reimploded.blar" empty.txt > "$TMPDIR/empty_reimploded.txt"
test ! -s "$TMPDIR/empty_reimploded.txt" \
  && pass "empty file survives explode/implode round-trip" \
  || fail "empty file survives explode/implode round-trip"

# ── Test 16: Large-ish binary (4KB) survives text round-trip ─────────────────

# Already tested in Test 6, but let's also verify through explode/implode
(cd "$TMPDIR/src" && "$BLAR" create "$TMPDIR/binary.blar" big_random.bin)
"$BLAR" explode "$TMPDIR/binary.blar" -C "$TMPDIR/binary_exploded"
cmp "$TMPDIR/src/big_random.bin" "$TMPDIR/binary_exploded/big_random.bin" >/dev/null 2>&1 \
  && pass "4KB binary data survives explode" \
  || fail "4KB binary data survives explode"

"$BLAR" implode "$TMPDIR/binary_exploded" -o "$TMPDIR/binary_reimploded.blar"
"$BLAR" cat "$TMPDIR/binary_reimploded.blar" big_random.bin > "$TMPDIR/binary_reimploded.bin"
cmp "$TMPDIR/src/big_random.bin" "$TMPDIR/binary_reimploded.bin" >/dev/null 2>&1 \
  && pass "4KB binary data survives explode/implode round-trip" \
  || fail "4KB binary data survives explode/implode round-trip"

# ── Test 17: Special characters in filename (spaces) ────────────────────────

echo "spaced content" > "$TMPDIR/src/file with spaces.txt"
(cd "$TMPDIR/src" && "$BLAR" create "$TMPDIR/spaces.blar" "file with spaces.txt")
"$BLAR" text "$TMPDIR/spaces.blar" > "$TMPDIR/spaces_text.txt"
grep -q 'FILE "file with spaces.txt"' "$TMPDIR/spaces_text.txt" \
  && pass "spaces in filename: text output correct" \
  || fail "spaces in filename: text output correct"

"$BLAR" from-text "$TMPDIR/spaces_text.txt" -o "$TMPDIR/spaces_rt.blar"
"$BLAR" cat "$TMPDIR/spaces_rt.blar" "file with spaces.txt" > "$TMPDIR/spaces_rt_content.txt"
echo "spaced content" | diff - "$TMPDIR/spaces_rt_content.txt" >/dev/null 2>&1 \
  && pass "spaces in filename: text round-trip preserves content" \
  || fail "spaces in filename: text round-trip preserves content"

"$BLAR" explode "$TMPDIR/spaces.blar" -C "$TMPDIR/spaces_exploded"
test -f "$TMPDIR/spaces_exploded/file with spaces.txt" \
  && diff <(echo "spaced content") "$TMPDIR/spaces_exploded/file with spaces.txt" >/dev/null 2>&1 \
  && pass "spaces in filename: explode preserves file" \
  || fail "spaces in filename: explode preserves file"

# ── Test 18: Container archive text (PNG, if available) ─────────────────────

if python3 -c "import struct, zlib" 2>/dev/null; then
  # Create a minimal test PNG using pure Python (no PIL needed)
  python3 -c "
import struct, zlib
width, height = 64, 64
sig = b'\x89PNG\r\n\x1a\n'
ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
ihdr_crc = struct.pack('>I', zlib.crc32(b'IHDR' + ihdr_data) & 0xffffffff)
ihdr = struct.pack('>I', 13) + b'IHDR' + ihdr_data + ihdr_crc
raw = b''
for y in range(height):
    raw += b'\x00'
    for x in range(width):
        raw += bytes([(x*7+y*3) % 256, (x*3+y*7) % 256, (x+y) % 256, 255])
compressed = zlib.compress(raw)
idat_crc = struct.pack('>I', zlib.crc32(b'IDAT' + compressed) & 0xffffffff)
idat = struct.pack('>I', len(compressed)) + b'IDAT' + compressed + idat_crc
iend_crc = struct.pack('>I', zlib.crc32(b'IEND') & 0xffffffff)
iend = struct.pack('>I', 0) + b'IEND' + iend_crc
with open('$TMPDIR/test_container.png', 'wb') as f:
    f.write(sig + ihdr + idat + iend)
"
  "$BLAR" create -z "$TMPDIR/container.blar" "$TMPDIR/test_container.png"
  "$BLAR" text "$TMPDIR/container.blar" > "$TMPDIR/container_text.txt"
  if grep -q 'co=png' "$TMPDIR/container_text.txt"; then
    pass "container archive text: co=png appears in text output"
  else
    # Container expansion may store it differently; check for any container indicator
    if grep -q 'container' "$TMPDIR/container_text.txt" || grep -q 'DIR.*\.png' "$TMPDIR/container_text.txt"; then
      pass "container archive text: container indicator present"
    else
      fail "container archive text: no container indicator in text output"
    fi
  fi
else
  echo "SKIP: container PNG test (python3 with struct/zlib not available)"
fi

# ── Test 19: Imploded archive verifies ───────────────────────────────────────

"$BLAR" verify "$TMPDIR/reimploded.blar" >/dev/null 2>&1 \
  && pass "imploded archive passes verification" \
  || fail "imploded archive passes verification"

# ── Test 20: From-text archive verifies ──────────────────────────────────────

"$BLAR" verify "$TMPDIR/rt_flat.blar" >/dev/null 2>&1 \
  && pass "from-text archive passes verification" \
  || fail "from-text archive passes verification"

# ── Test 21: Text stability through nested round-trip ────────────────────────

"$BLAR" text "$TMPDIR/rt_nested.blar" > "$TMPDIR/nested_text2.txt"
diff "$TMPDIR/nested.txt" "$TMPDIR/nested_text2.txt" >/dev/null 2>&1 \
  && pass "text stability: nested text -> binary -> text is identical" \
  || fail "text stability: nested text -> binary -> text is identical"

# ── Test 22: __meta__.json contains expected fields ──────────────────────────

grep -q '"mode"' "$TMPDIR/exploded/__meta__.json" \
  && grep -q '"mtime"' "$TMPDIR/exploded/__meta__.json" \
  && pass "__meta__.json contains mode and mtime fields" \
  || fail "__meta__.json contains mode and mtime fields"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== Tri-representation tests: $PASS passed, $FAIL failed ==="
test $FAIL -eq 0
