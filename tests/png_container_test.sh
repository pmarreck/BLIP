#!/usr/bin/env bash
set -u

# =============================================================================
# PNG container expansion integration test suite
# =============================================================================
# Tests transparent PNG container expansion (PNG → JXL lossless pixel encoding)
# and pixel-identical re-assembly in blar.
# =============================================================================

# --------------- paths ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"

# --------------- build ---------------
echo "Building blar..."
(cd "$PROJECT_DIR" && nix develop -c zig build -Doptimize=ReleaseFast) \
  || { echo "FATAL: build failed"; exit 1; }

if [[ ! -x "$BLAR" ]]; then
  echo "FATAL: blar binary not found at $BLAR"
  exit 1
fi

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

# --------------- helper: create test PNGs ---------------
create_test_png_rgba() {
  local png_path="$1"
  local width="${2:-128}"
  local height="${3:-128}"
  python3 -c "
import struct, zlib
width, height = $width, $height
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
with open('$png_path', 'wb') as f:
    f.write(sig + ihdr + idat + iend)
"
}

create_test_png_rgb() {
  local png_path="$1"
  python3 -c "
import struct, zlib
width, height = 64, 64
sig = b'\x89PNG\r\n\x1a\n'
ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
ihdr_crc = struct.pack('>I', zlib.crc32(b'IHDR' + ihdr_data) & 0xffffffff)
ihdr = struct.pack('>I', 13) + b'IHDR' + ihdr_data + ihdr_crc
raw = b''
for y in range(height):
    raw += b'\x00'
    for x in range(width):
        raw += bytes([(x*5) % 256, (y*5) % 256, 128])
compressed = zlib.compress(raw)
idat_crc = struct.pack('>I', zlib.crc32(b'IDAT' + compressed) & 0xffffffff)
idat = struct.pack('>I', len(compressed)) + b'IDAT' + compressed + idat_crc
iend_crc = struct.pack('>I', zlib.crc32(b'IEND') & 0xffffffff)
iend = struct.pack('>I', 0) + b'IEND' + iend_crc
with open('$png_path', 'wb') as f:
    f.write(sig + ihdr + idat + iend)
"
}

create_test_png_gray() {
  local png_path="$1"
  python3 -c "
import struct, zlib
width, height = 64, 64
sig = b'\x89PNG\r\n\x1a\n'
ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0)
ihdr_crc = struct.pack('>I', zlib.crc32(b'IHDR' + ihdr_data) & 0xffffffff)
ihdr = struct.pack('>I', 13) + b'IHDR' + ihdr_data + ihdr_crc
raw = b''
for y in range(height):
    raw += b'\x00'
    for x in range(width):
        raw += bytes([(x*4+y*4) % 256])
compressed = zlib.compress(raw)
idat_crc = struct.pack('>I', zlib.crc32(b'IDAT' + compressed) & 0xffffffff)
idat = struct.pack('>I', len(compressed)) + b'IDAT' + compressed + idat_crc
iend_crc = struct.pack('>I', zlib.crc32(b'IEND') & 0xffffffff)
iend = struct.pack('>I', 0) + b'IEND' + iend_crc
with open('$png_path', 'wb') as f:
    f.write(sig + ihdr + idat + iend)
"
}

create_test_png_with_text() {
  local png_path="$1"
  python3 -c "
import struct, zlib
width, height = 64, 64
sig = b'\x89PNG\r\n\x1a\n'
ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
ihdr_crc = struct.pack('>I', zlib.crc32(b'IHDR' + ihdr_data) & 0xffffffff)
ihdr = struct.pack('>I', 13) + b'IHDR' + ihdr_data + ihdr_crc
text_data = b'Author\x00BlarTestSuite'
text_crc = struct.pack('>I', zlib.crc32(b'tEXt' + text_data) & 0xffffffff)
text = struct.pack('>I', len(text_data)) + b'tEXt' + text_data + text_crc
raw = b''
for y in range(height):
    raw += b'\x00'
    for x in range(width):
        raw += bytes([x*4, y*4, 128, 200])
compressed = zlib.compress(raw)
idat_crc = struct.pack('>I', zlib.crc32(b'IDAT' + compressed) & 0xffffffff)
idat = struct.pack('>I', len(compressed)) + b'IDAT' + compressed + idat_crc
iend_crc = struct.pack('>I', zlib.crc32(b'IEND') & 0xffffffff)
iend = struct.pack('>I', 0) + b'IEND' + iend_crc
with open('$png_path', 'wb') as f:
    f.write(sig + ihdr + text + idat + iend)
"
}

# Helper: compare pixel data between two PNGs
pixels_identical() {
  python3 -c "
import struct, zlib, sys

def parse_pixels(path):
    with open(path, 'rb') as f:
        data = f.read()
    pos = 8
    width = height = bit_depth = color_type = 0
    idat = b''
    while pos + 12 <= len(data):
        clen = struct.unpack('>I', data[pos:pos+4])[0]
        ctype = data[pos+4:pos+8]
        cdata = data[pos+8:pos+8+clen]
        if ctype == b'IHDR':
            width, height, bit_depth, color_type = struct.unpack('>IIBB', cdata[:10])
        elif ctype == b'IDAT':
            idat += cdata
        elif ctype == b'IEND':
            break
        pos += 12 + clen
    raw = zlib.decompress(idat)
    ch = {0:1, 2:3, 3:1, 4:2, 6:4}[color_type]
    bps = 2 if bit_depth == 16 else 1
    row_bytes = width * ch * bps
    pixels = b''
    for y in range(height):
        pixels += raw[y*(1+row_bytes)+1:y*(1+row_bytes)+1+row_bytes]
    return pixels

try:
    p1 = parse_pixels('$1')
    p2 = parse_pixels('$2')
    sys.exit(0 if p1 == p2 else 1)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# =============================================================================
echo ""
echo "--- Test 1: Basic RGBA PNG roundtrip ---"
create_test_png_rgba "$TMPDIR_TEST/test1.png"
"$BLAR" create -z -o "$TMPDIR_TEST/test1.blar" "$TMPDIR_TEST/test1.png" 2>/dev/null
"$BLAR" extract "$TMPDIR_TEST/test1.blar" -C "$TMPDIR_TEST/test1_out" 2>/dev/null
EXTRACTED=$(find "$TMPDIR_TEST/test1_out" -name "test1.png" 2>/dev/null)
if [[ -n "$EXTRACTED" ]] && pixels_identical "$TMPDIR_TEST/test1.png" "$EXTRACTED"; then
  pass "RGBA PNG roundtrip pixel-identical"
else
  fail "RGBA PNG roundtrip pixel-identical"
fi

# =============================================================================
echo ""
echo "--- Test 2: Grayscale PNG roundtrip ---"
create_test_png_gray "$TMPDIR_TEST/test2_gray.png"
"$BLAR" create -z -o "$TMPDIR_TEST/test2.blar" "$TMPDIR_TEST/test2_gray.png" 2>/dev/null
"$BLAR" extract "$TMPDIR_TEST/test2.blar" -C "$TMPDIR_TEST/test2_out" 2>/dev/null
EXTRACTED=$(find "$TMPDIR_TEST/test2_out" -name "test2_gray.png" 2>/dev/null)
if [[ -n "$EXTRACTED" ]] && pixels_identical "$TMPDIR_TEST/test2_gray.png" "$EXTRACTED"; then
  pass "grayscale PNG roundtrip pixel-identical"
else
  fail "grayscale PNG roundtrip pixel-identical"
fi

# =============================================================================
echo ""
echo "--- Test 3: RGB PNG roundtrip ---"
create_test_png_rgb "$TMPDIR_TEST/test3_rgb.png"
"$BLAR" create -z -o "$TMPDIR_TEST/test3.blar" "$TMPDIR_TEST/test3_rgb.png" 2>/dev/null
"$BLAR" extract "$TMPDIR_TEST/test3.blar" -C "$TMPDIR_TEST/test3_out" 2>/dev/null
EXTRACTED=$(find "$TMPDIR_TEST/test3_out" -name "test3_rgb.png" 2>/dev/null)
if [[ -n "$EXTRACTED" ]] && pixels_identical "$TMPDIR_TEST/test3_rgb.png" "$EXTRACTED"; then
  pass "RGB PNG roundtrip pixel-identical"
else
  fail "RGB PNG roundtrip pixel-identical"
fi

# =============================================================================
echo ""
echo "--- Test 4: PNG with tEXt metadata ---"
create_test_png_with_text "$TMPDIR_TEST/test4_text.png"
"$BLAR" create -z -o "$TMPDIR_TEST/test4.blar" "$TMPDIR_TEST/test4_text.png" 2>/dev/null
"$BLAR" extract "$TMPDIR_TEST/test4.blar" -C "$TMPDIR_TEST/test4_out" 2>/dev/null
EXTRACTED=$(find "$TMPDIR_TEST/test4_out" -name "test4_text.png" 2>/dev/null)
if [[ -n "$EXTRACTED" ]]; then
  if pixels_identical "$TMPDIR_TEST/test4_text.png" "$EXTRACTED"; then
    pass "PNG with tEXt metadata: pixels identical"
  else
    fail "PNG with tEXt metadata: pixels identical"
  fi
  if grep -q "BlarTestSuite" "$EXTRACTED" 2>/dev/null; then
    pass "PNG with tEXt metadata: chunk preserved"
  else
    fail "PNG with tEXt metadata: chunk preserved"
  fi
else
  fail "PNG with tEXt metadata: file not extracted"
fi

# =============================================================================
echo ""
echo "--- Test 5: blar list shows 'n' prefix ---"
LIST_OUT=$("$BLAR" list "$TMPDIR_TEST/test1.blar" 2>/dev/null)
if echo "$LIST_OUT" | grep -q "^n "; then
  pass "blar list shows 'n' prefix for PNG container dirs"
else
  fail "blar list shows 'n' prefix for PNG container dirs"
fi

# =============================================================================
echo ""
echo "--- Test 6: blar info --json ---"
INFO_OUT=$("$BLAR" info --json "$TMPDIR_TEST/test1.blar" 2>/dev/null)
if echo "$INFO_OUT" | grep -q '"container_type".*"png"'; then
  pass "info --json includes container_type: png"
else
  fail "info --json includes container_type: png"
fi
if echo "$INFO_OUT" | grep -q '"jxl_source_format".*"png"'; then
  pass "info --json includes jxl_source_format: png"
else
  fail "info --json includes jxl_source_format: png"
fi

# =============================================================================
echo ""
echo "--- Test 7: --no-expand-containers stores PNG as opaque ---"
"$BLAR" create --no-expand-containers -z -o "$TMPDIR_TEST/test7.blar" "$TMPDIR_TEST/test1.png" 2>/dev/null
LIST_OUT=$("$BLAR" list "$TMPDIR_TEST/test7.blar" 2>/dev/null)
if echo "$LIST_OUT" | grep -q "^- "; then
  pass "--no-expand-containers: stored as opaque file"
else
  fail "--no-expand-containers: stored as opaque file"
fi
if ! echo "$LIST_OUT" | grep -q "^n "; then
  pass "--no-expand-containers: no container expansion"
else
  fail "--no-expand-containers: no container expansion"
fi

# =============================================================================
echo ""
echo "--- Test 8: Tiny PNG (<1KB) stored as opaque ---"
create_test_png_rgba "$TMPDIR_TEST/tiny.png" 4 4
TINY_SIZE=$(wc -c < "$TMPDIR_TEST/tiny.png")
"$BLAR" create -z -o "$TMPDIR_TEST/test8.blar" "$TMPDIR_TEST/tiny.png" 2>/dev/null
LIST_OUT=$("$BLAR" list "$TMPDIR_TEST/test8.blar" 2>/dev/null)
if echo "$LIST_OUT" | grep -q "^- "; then
  pass "tiny PNG stored as opaque (size=$TINY_SIZE)"
else
  fail "tiny PNG stored as opaque (size=$TINY_SIZE)"
fi

# =============================================================================
echo ""
echo "--- Test 9: Mixed archive: PNG + regular file ---"
echo "Hello world" > "$TMPDIR_TEST/plain.txt"
"$BLAR" create -z -o "$TMPDIR_TEST/test9.blar" \
    "$TMPDIR_TEST/test1.png" "$TMPDIR_TEST/plain.txt" 2>/dev/null
"$BLAR" extract "$TMPDIR_TEST/test9.blar" -C "$TMPDIR_TEST/test9_out" 2>/dev/null
EXTRACTED_TXT=$(find "$TMPDIR_TEST/test9_out" -name "plain.txt" 2>/dev/null)
if [[ -n "$EXTRACTED_TXT" ]] && diff -q "$TMPDIR_TEST/plain.txt" "$EXTRACTED_TXT" >/dev/null 2>&1; then
  pass "mixed archive: plain file preserved"
else
  fail "mixed archive: plain file preserved"
fi
EXTRACTED_PNG=$(find "$TMPDIR_TEST/test9_out" -name "test1.png" 2>/dev/null)
if [[ -n "$EXTRACTED_PNG" ]] && pixels_identical "$TMPDIR_TEST/test1.png" "$EXTRACTED_PNG"; then
  pass "mixed archive: PNG roundtrip pixel-identical"
else
  fail "mixed archive: PNG roundtrip pixel-identical"
fi

# =============================================================================
echo ""
echo "--- Test 10: Verify ---"
"$BLAR" verify "$TMPDIR_TEST/test1.blar" 2>/dev/null
if [[ $? -eq 0 ]]; then
  pass "verify passes for PNG container archive"
else
  fail "verify passes for PNG container archive"
fi

# =============================================================================
echo ""
echo "--- Test 11: Solid mode ---"
"$BLAR" create -z --solid -o "$TMPDIR_TEST/test11.blar" "$TMPDIR_TEST/test1.png" 2>/dev/null
"$BLAR" extract "$TMPDIR_TEST/test11.blar" -C "$TMPDIR_TEST/test11_out" 2>/dev/null
EXTRACTED=$(find "$TMPDIR_TEST/test11_out" -name "test1.png" 2>/dev/null)
if [[ -n "$EXTRACTED" ]] && pixels_identical "$TMPDIR_TEST/test1.png" "$EXTRACTED"; then
  pass "solid mode: PNG roundtrip pixel-identical"
else
  fail "solid mode: PNG roundtrip pixel-identical"
fi

# =============================================================================
echo ""
echo "--- Test 12: Multiple PNGs ---"
create_test_png_rgba "$TMPDIR_TEST/multi1.png" 64 64
create_test_png_rgba "$TMPDIR_TEST/multi2.png" 32 32
"$BLAR" create -z -o "$TMPDIR_TEST/test12.blar" \
    "$TMPDIR_TEST/multi1.png" "$TMPDIR_TEST/multi2.png" 2>/dev/null
LIST_OUT=$("$BLAR" list "$TMPDIR_TEST/test12.blar" 2>/dev/null)
PNG_CONTAINERS=$(echo "$LIST_OUT" | grep -c "^n ")
if [[ "$PNG_CONTAINERS" -eq 2 ]]; then
  pass "multiple PNGs: found 2 PNG container entries"
else
  fail "multiple PNGs: found $PNG_CONTAINERS PNG container entries, expected 2"
fi
"$BLAR" extract "$TMPDIR_TEST/test12.blar" -C "$TMPDIR_TEST/test12_out" 2>/dev/null
E1=$(find "$TMPDIR_TEST/test12_out" -name "multi1.png" 2>/dev/null)
E2=$(find "$TMPDIR_TEST/test12_out" -name "multi2.png" 2>/dev/null)
if [[ -n "$E1" ]] && pixels_identical "$TMPDIR_TEST/multi1.png" "$E1" && \
   [[ -n "$E2" ]] && pixels_identical "$TMPDIR_TEST/multi2.png" "$E2"; then
  pass "multiple PNGs: both roundtrip pixel-identical"
else
  fail "multiple PNGs: both roundtrip pixel-identical"
fi

# =============================================================================
echo ""
echo "--- Test 13: JXL size savings ---"
ORIG_SIZE=$(wc -c < "$TMPDIR_TEST/test1.png")
BLAR_SIZE=$(wc -c < "$TMPDIR_TEST/test1.blar")
echo "  Original PNG: ${ORIG_SIZE}B, Archive: ${BLAR_SIZE}B"
if [[ "$BLAR_SIZE" -lt "$ORIG_SIZE" ]]; then
  pass "JXL archive smaller than original PNG"
else
  fail "JXL archive not smaller than original PNG (archive=$BLAR_SIZE, original=$ORIG_SIZE)"
fi

# =============================================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

exit $FAIL
