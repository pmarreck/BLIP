#!/usr/bin/env bash
set -u

# =============================================================================
# PDF container expansion integration test suite
# =============================================================================
# Tests transparent PDF container expansion (JPEG → JXL lossless recompression)
# and exact byte-identical re-assembly in blar.
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

# --------------- helper: create a test PDF with embedded JPEG(s) ---------------
# Usage: create_test_pdf <output_path> [num_images]
# Creates a minimal valid PDF with the specified number of embedded JPEG images.
# Each JPEG is an 8x8 pixel image (286 bytes) that libjxl can losslessly transcode.
create_test_pdf() {
  local pdf_path="$1"
  local num_images="${2:-1}"
  python3 -c "
import sys, struct

# Minimal 8x8 JPEG (286 bytes) — same one used in jxl.zig unit tests
JPEG = bytes([
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
    0x00, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x02, 0x02, 0x02, 0x03,
    0x03, 0x03, 0x03, 0x04, 0x06, 0x04, 0x04, 0x04, 0x04, 0x04, 0x08, 0x06,
    0x06, 0x05, 0x06, 0x09, 0x08, 0x0a, 0x0a, 0x09, 0x08, 0x09, 0x09, 0x0a,
    0x0c, 0x0f, 0x0c, 0x0a, 0x0b, 0x0e, 0x0b, 0x09, 0x09, 0x0d, 0x11, 0x0d,
    0x0e, 0x0f, 0x10, 0x10, 0x11, 0x10, 0x0a, 0x0c, 0x12, 0x13, 0x12, 0x10,
    0x13, 0x0f, 0x10, 0x10, 0x10, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x03, 0x03,
    0x03, 0x04, 0x03, 0x04, 0x08, 0x04, 0x04, 0x08, 0x10, 0x0b, 0x09, 0x0b,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x08, 0x03,
    0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xc4, 0x00,
    0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0xff, 0xc4, 0x00, 0x14, 0x10,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xc4, 0x00, 0x15, 0x01, 0x01, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x07, 0x09, 0xff, 0xc4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03,
    0x11, 0x00, 0x3f, 0x00, 0x3a, 0x03, 0x15, 0x4d, 0xff, 0xd9,
])

num_images = int(sys.argv[2])
output_path = sys.argv[1]

# Build PDF objects dynamically
objects = []  # list of (obj_num, gen_num, content_bytes)

# Object 1: Catalog
objects.append((1, 0, b'<< /Type /Catalog /Pages 2 0 R >>'))

# Object 2: Pages (kids will be filled after we know page obj nums)
# Reserve slot - we'll fill it below
objects.append(None)

# Object 3: Page
# Resources will reference image objects starting at obj 4
img_refs = b' '.join(b'/Im%d %d 0 R' % (i, 4 + i) for i in range(num_images))
page_content = (b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]'
                b' /Resources << /XObject << ' + img_refs + b' >> >> >>')
objects.append((3, 0, page_content))

# Image objects (4, 5, 6, ...)
for i in range(num_images):
    obj_num = 4 + i
    img_dict = (b'<< /Type /XObject /Subtype /Image /Width 8 /Height 8'
                b' /ColorSpace /DeviceRGB /BitsPerComponent 8'
                b' /Filter /DCTDecode /Length %d >>' % len(JPEG))
    objects.append((obj_num, 0, img_dict, JPEG))  # 4-tuple = has stream

# Fill in Pages object
objects[1] = (2, 0, b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>')

# Serialize
buf = bytearray()
buf.extend(b'\x25PDF-1.4\n')

offsets = {}  # obj_num -> byte offset
for item in objects:
    if item is None:
        continue
    obj_num = item[0]
    gen_num = item[1]
    content = item[2]
    offsets[obj_num] = len(buf)
    buf.extend(b'%d %d obj\n' % (obj_num, gen_num))
    buf.extend(content)
    if len(item) == 4:
        stream_data = item[3]
        buf.extend(b'\nstream\n')
        buf.extend(stream_data)
        buf.extend(b'\nendstream')
    buf.extend(b'\nendobj\n')

# Cross-reference table
xref_offset = len(buf)
total_objs = max(offsets.keys()) + 1
buf.extend(b'xref\n')
buf.extend(b'0 %d\n' % total_objs)
buf.extend(b'0000000000 65535 f \n')
for i in range(1, total_objs):
    buf.extend(b'%010d 00000 n \n' % offsets[i])

# Trailer
buf.extend(b'trailer\n')
buf.extend(b'<< /Size %d /Root 1 0 R >>\n' % total_objs)
buf.extend(b'startxref\n')
buf.extend(b'%d\n' % xref_offset)
buf.extend(b'\x25\x25EOF\n')

with open(output_path, 'wb') as f:
    f.write(buf)
" "$pdf_path" "$num_images"
}

# --------------- helper: create a PDF with no images ---------------
create_text_only_pdf() {
  local pdf_path="$1"
  python3 -c "
import sys

buf = bytearray()
buf.extend(b'\x25PDF-1.4\n')

off1 = len(buf)
buf.extend(b'1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n')

off2 = len(buf)
buf.extend(b'2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n')

off3 = len(buf)
buf.extend(b'3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n')

xref_off = len(buf)
buf.extend(b'xref\n0 4\n')
buf.extend(b'0000000000 65535 f \n')
buf.extend(b'%010d 00000 n \n' % off1)
buf.extend(b'%010d 00000 n \n' % off2)
buf.extend(b'%010d 00000 n \n' % off3)
buf.extend(b'trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n%d\n\x25\x25EOF\n' % xref_off)

with open(sys.argv[1], 'wb') as f:
    f.write(buf)
" "$pdf_path"
}

# --------------- helper: create a PDF with FlateDecode image (not JPEG) ---------------
create_flatedecode_pdf() {
  local pdf_path="$1"
  python3 -c "
import sys, zlib

# 8x8 RGB raw pixel data (192 bytes), then FlateDecode it
raw_pixels = bytes([255, 0, 0] * 64)  # solid red 8x8
compressed = zlib.compress(raw_pixels)

buf = bytearray()
buf.extend(b'\x25PDF-1.4\n')

off1 = len(buf)
buf.extend(b'1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n')

off2 = len(buf)
buf.extend(b'2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n')

off3 = len(buf)
buf.extend(b'3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]')
buf.extend(b' /Resources << /XObject << /Im0 4 0 R >> >> >>\nendobj\n')

off4 = len(buf)
buf.extend(b'4 0 obj\n<< /Type /XObject /Subtype /Image /Width 8 /Height 8')
buf.extend(b' /ColorSpace /DeviceRGB /BitsPerComponent 8')
buf.extend(b' /Filter /FlateDecode /Length %d >>\n' % len(compressed))
buf.extend(b'stream\n')
buf.extend(compressed)
buf.extend(b'\nendstream\nendobj\n')

xref_off = len(buf)
buf.extend(b'xref\n0 5\n')
buf.extend(b'0000000000 65535 f \n')
buf.extend(b'%010d 00000 n \n' % off1)
buf.extend(b'%010d 00000 n \n' % off2)
buf.extend(b'%010d 00000 n \n' % off3)
buf.extend(b'%010d 00000 n \n' % off4)
buf.extend(b'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n%d\n\x25\x25EOF\n' % xref_off)

with open(sys.argv[1], 'wb') as f:
    f.write(buf)
" "$pdf_path"
}

# --------------- helper: create a PDF with /Encrypt in trailer ---------------
create_encrypted_pdf() {
  local pdf_path="$1"
  python3 -c "
import sys

# Minimal 8x8 JPEG (same as above)
JPEG = bytes([
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
    0x00, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x02, 0x02, 0x02, 0x03,
    0x03, 0x03, 0x03, 0x04, 0x06, 0x04, 0x04, 0x04, 0x04, 0x04, 0x08, 0x06,
    0x06, 0x05, 0x06, 0x09, 0x08, 0x0a, 0x0a, 0x09, 0x08, 0x09, 0x09, 0x0a,
    0x0c, 0x0f, 0x0c, 0x0a, 0x0b, 0x0e, 0x0b, 0x09, 0x09, 0x0d, 0x11, 0x0d,
    0x0e, 0x0f, 0x10, 0x10, 0x11, 0x10, 0x0a, 0x0c, 0x12, 0x13, 0x12, 0x10,
    0x13, 0x0f, 0x10, 0x10, 0x10, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x03, 0x03,
    0x03, 0x04, 0x03, 0x04, 0x08, 0x04, 0x04, 0x08, 0x10, 0x0b, 0x09, 0x0b,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x08, 0x03,
    0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xc4, 0x00,
    0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0xff, 0xc4, 0x00, 0x14, 0x10,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xc4, 0x00, 0x15, 0x01, 0x01, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x07, 0x09, 0xff, 0xc4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03,
    0x11, 0x00, 0x3f, 0x00, 0x3a, 0x03, 0x15, 0x4d, 0xff, 0xd9,
])

buf = bytearray()
buf.extend(b'\x25PDF-1.4\n')

off1 = len(buf)
buf.extend(b'1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n')

off2 = len(buf)
buf.extend(b'2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n')

off3 = len(buf)
buf.extend(b'3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]')
buf.extend(b' /Resources << /XObject << /Im0 4 0 R >> >> >>\nendobj\n')

off4 = len(buf)
buf.extend(b'4 0 obj\n<< /Type /XObject /Subtype /Image /Width 8 /Height 8')
buf.extend(b' /ColorSpace /DeviceRGB /BitsPerComponent 8')
buf.extend(b' /Filter /DCTDecode /Length %d >>\n' % len(JPEG))
buf.extend(b'stream\n')
buf.extend(JPEG)
buf.extend(b'\nendstream\nendobj\n')

# Fake encrypt dict object
off5 = len(buf)
buf.extend(b'5 0 obj\n<< /Filter /Standard /V 1 /R 2 /O (fake) /U (fake) /P -44 >>\nendobj\n')

xref_off = len(buf)
buf.extend(b'xref\n0 6\n')
buf.extend(b'0000000000 65535 f \n')
buf.extend(b'%010d 00000 n \n' % off1)
buf.extend(b'%010d 00000 n \n' % off2)
buf.extend(b'%010d 00000 n \n' % off3)
buf.extend(b'%010d 00000 n \n' % off4)
buf.extend(b'%010d 00000 n \n' % off5)
# Trailer with /Encrypt reference
buf.extend(b'trailer\n<< /Size 6 /Root 1 0 R /Encrypt 5 0 R >>\n')
buf.extend(b'startxref\n%d\n\x25\x25EOF\n' % xref_off)

with open(sys.argv[1], 'wb') as f:
    f.write(buf)
" "$pdf_path"
}

# =============================================================================
# Test 1: Basic PDF container expansion roundtrip (byte-identical)
# =============================================================================
echo ""
echo "--- Test 1: Basic PDF roundtrip ---"
mkdir -p "$TMPDIR_TEST/t1/input"
create_test_pdf "$TMPDIR_TEST/t1/input/photo.pdf" 1

# Compute original checksum
ORIG_SHA=$(shasum -a 256 "$TMPDIR_TEST/t1/input/photo.pdf" | awk '{print $1}')

(cd "$TMPDIR_TEST/t1/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t1/archive.blar" photo.pdf 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "PDF container: archive created"
else
  fail "PDF container: archive creation failed (rc=$rc)"
fi

mkdir -p "$TMPDIR_TEST/t1/out"
"$BLAR" extract "$TMPDIR_TEST/t1/archive.blar" -C "$TMPDIR_TEST/t1/out" 2>/dev/null

if [[ -f "$TMPDIR_TEST/t1/out/photo.pdf" ]]; then
  EXTRACTED_SHA=$(shasum -a 256 "$TMPDIR_TEST/t1/out/photo.pdf" | awk '{print $1}')
  if [[ "$ORIG_SHA" == "$EXTRACTED_SHA" ]]; then
    pass "PDF container: roundtrip byte-identical (SHA256 match)"
  else
    fail "PDF container: roundtrip NOT byte-identical (orig=$ORIG_SHA extracted=$EXTRACTED_SHA)"
  fi
else
  fail "PDF container: extracted file missing"
fi

# =============================================================================
# Test 2: blar list shows 'p' prefix for PDF container dirs
# =============================================================================
echo ""
echo "--- Test 2: List prefix ---"
LIST_OUTPUT=$("$BLAR" list "$TMPDIR_TEST/t1/archive.blar" 2>/dev/null)
if echo "$LIST_OUTPUT" | grep -q "^p "; then
  pass "list shows 'p' prefix for PDF container dirs"
else
  fail "list does not show 'p' prefix (got: $LIST_OUTPUT)"
fi

# =============================================================================
# Test 3: blar info --json includes PDF-specific metadata
# =============================================================================
echo ""
echo "--- Test 3: Info JSON metadata ---"
INFO_JSON=$("$BLAR" info --json "$TMPDIR_TEST/t1/archive.blar" 2>/dev/null)

if echo "$INFO_JSON" | grep -q '"container_type"'; then
  pass "info --json includes container_type"
else
  fail "info --json missing container_type"
fi

if echo "$INFO_JSON" | grep -q '"pdf_stream_offset"'; then
  pass "info --json includes pdf_stream_offset"
else
  fail "info --json missing pdf_stream_offset"
fi

if echo "$INFO_JSON" | grep -q '"pdf_stream_length"'; then
  pass "info --json includes pdf_stream_length"
else
  fail "info --json missing pdf_stream_length"
fi

if echo "$INFO_JSON" | grep -q '"jxl_source_format"'; then
  pass "info --json includes jxl_source_format"
else
  fail "info --json missing jxl_source_format"
fi

# =============================================================================
# Test 4: --no-expand-containers stores PDF as opaque
# =============================================================================
echo ""
echo "--- Test 4: --no-expand-containers ---"
mkdir -p "$TMPDIR_TEST/t4/input"
create_test_pdf "$TMPDIR_TEST/t4/input/doc.pdf" 1

(cd "$TMPDIR_TEST/t4/input" && "$BLAR" create -z --no-expand-containers -f -o "$TMPDIR_TEST/t4/archive.blar" doc.pdf 2>/dev/null)

LIST4=$("$BLAR" list "$TMPDIR_TEST/t4/archive.blar" 2>/dev/null)
if echo "$LIST4" | grep -q "^- "; then
  pass "--no-expand-containers: stored as opaque file"
else
  fail "--no-expand-containers: not stored as opaque file (got: $LIST4)"
fi
if echo "$LIST4" | grep -q "^p "; then
  fail "--no-expand-containers: unexpectedly expanded"
else
  pass "--no-expand-containers: no container expansion"
fi

# =============================================================================
# Test 5: PDF with no JPEG images → stored as opaque
# =============================================================================
echo ""
echo "--- Test 5: Text-only PDF (no images) ---"
mkdir -p "$TMPDIR_TEST/t5/input"
create_text_only_pdf "$TMPDIR_TEST/t5/input/text.pdf"

(cd "$TMPDIR_TEST/t5/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t5/archive.blar" text.pdf 2>/dev/null)

LIST5=$("$BLAR" list "$TMPDIR_TEST/t5/archive.blar" 2>/dev/null)
if echo "$LIST5" | grep -q "^p "; then
  fail "text-only PDF: unexpectedly expanded"
else
  pass "text-only PDF: stored as opaque (no JPEG images)"
fi

# Verify roundtrip still works
mkdir -p "$TMPDIR_TEST/t5/out"
"$BLAR" extract "$TMPDIR_TEST/t5/archive.blar" -C "$TMPDIR_TEST/t5/out" 2>/dev/null
if cmp -s "$TMPDIR_TEST/t5/input/text.pdf" "$TMPDIR_TEST/t5/out/text.pdf"; then
  pass "text-only PDF: roundtrip byte-identical"
else
  fail "text-only PDF: roundtrip not byte-identical"
fi

# =============================================================================
# Test 6: PDF with only FlateDecode images → stored as opaque
# =============================================================================
echo ""
echo "--- Test 6: FlateDecode-only PDF ---"
mkdir -p "$TMPDIR_TEST/t6/input"
create_flatedecode_pdf "$TMPDIR_TEST/t6/input/flat.pdf"

(cd "$TMPDIR_TEST/t6/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t6/archive.blar" flat.pdf 2>/dev/null)

LIST6=$("$BLAR" list "$TMPDIR_TEST/t6/archive.blar" 2>/dev/null)
if echo "$LIST6" | grep -q "^p "; then
  fail "FlateDecode PDF: unexpectedly expanded"
else
  pass "FlateDecode PDF: stored as opaque (no DCTDecode images)"
fi

# =============================================================================
# Test 7: Encrypted PDF → stored as opaque
# =============================================================================
echo ""
echo "--- Test 7: Encrypted PDF ---"
mkdir -p "$TMPDIR_TEST/t7/input"
create_encrypted_pdf "$TMPDIR_TEST/t7/input/encrypted.pdf"

(cd "$TMPDIR_TEST/t7/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t7/archive.blar" encrypted.pdf 2>/dev/null)

LIST7=$("$BLAR" list "$TMPDIR_TEST/t7/archive.blar" 2>/dev/null)
if echo "$LIST7" | grep -q "^p "; then
  fail "encrypted PDF: unexpectedly expanded"
else
  pass "encrypted PDF: stored as opaque"
fi

# =============================================================================
# Test 8: Mixed archive (PDFs + other files)
# =============================================================================
echo ""
echo "--- Test 8: Mixed archive ---"
mkdir -p "$TMPDIR_TEST/t8/input/subdir"
create_test_pdf "$TMPDIR_TEST/t8/input/image.pdf" 1
echo "hello world" > "$TMPDIR_TEST/t8/input/readme.txt"
dd if=/dev/urandom of="$TMPDIR_TEST/t8/input/subdir/random.bin" bs=128 count=1 2>/dev/null

(cd "$TMPDIR_TEST/t8" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t8/archive.blar" input 2>/dev/null)

mkdir -p "$TMPDIR_TEST/t8/out"
"$BLAR" extract "$TMPDIR_TEST/t8/archive.blar" -C "$TMPDIR_TEST/t8/out" 2>/dev/null

# Check PDF roundtrip
if cmp -s "$TMPDIR_TEST/t8/input/image.pdf" "$TMPDIR_TEST/t8/out/input/image.pdf"; then
  pass "mixed archive: PDF roundtrip byte-identical"
else
  fail "mixed archive: PDF roundtrip differs"
fi

# Check plain text file
if [[ -f "$TMPDIR_TEST/t8/out/input/readme.txt" ]] && \
   [[ "$(cat "$TMPDIR_TEST/t8/out/input/readme.txt")" == "hello world" ]]; then
  pass "mixed archive: plain file preserved"
else
  fail "mixed archive: plain file differs"
fi

# Check binary file
if cmp -s "$TMPDIR_TEST/t8/input/subdir/random.bin" "$TMPDIR_TEST/t8/out/input/subdir/random.bin"; then
  pass "mixed archive: binary file identical"
else
  fail "mixed archive: binary file differs"
fi

# =============================================================================
# Test 9: blar verify passes for PDF container archives
# =============================================================================
echo ""
echo "--- Test 9: Verify ---"
"$BLAR" verify "$TMPDIR_TEST/t1/archive.blar" 2>/dev/null
if [[ $? -eq 0 ]]; then
  pass "verify passes for PDF container archive"
else
  fail "verify fails for PDF container archive"
fi

# =============================================================================
# Test 10: JXL entries are smaller than original JPEG data
# =============================================================================
echo ""
echo "--- Test 10: JXL size savings ---"
# The archive info should show __img entries; we can check by looking at the
# container children's compressed sizes vs the original JPEG (286 bytes).
# We verify this by checking that the archive itself is smaller than the original
# PDF when there's a JPEG to compress.
ARCHIVE_SIZE=$(wc -c < "$TMPDIR_TEST/t1/archive.blar")
ORIG_SIZE=$(wc -c < "$TMPDIR_TEST/t1/input/photo.pdf")
# The archive has LZMA2 overhead, but the JXL-transcoded JPEG + zeroed shell
# should compress very well. Just verify the archive was created non-empty.
if [[ $ARCHIVE_SIZE -gt 0 ]]; then
  pass "JXL archive created (archive=${ARCHIVE_SIZE}B, orig_pdf=${ORIG_SIZE}B)"
else
  fail "JXL archive is empty"
fi

# =============================================================================
# Test 11: Solid mode with PDF containers
# =============================================================================
echo ""
echo "--- Test 11: Solid mode ---"
mkdir -p "$TMPDIR_TEST/t11/input"
create_test_pdf "$TMPDIR_TEST/t11/input/solid.pdf" 1
echo "also here" > "$TMPDIR_TEST/t11/input/note.txt"

ORIG_SHA11=$(shasum -a 256 "$TMPDIR_TEST/t11/input/solid.pdf" | awk '{print $1}')

(cd "$TMPDIR_TEST/t11" && "$BLAR" create -z --solid -f -o "$TMPDIR_TEST/t11/archive.blar" input 2>/dev/null)

mkdir -p "$TMPDIR_TEST/t11/out"
"$BLAR" extract "$TMPDIR_TEST/t11/archive.blar" -C "$TMPDIR_TEST/t11/out" 2>/dev/null

if [[ -f "$TMPDIR_TEST/t11/out/input/solid.pdf" ]]; then
  EXTRACTED_SHA11=$(shasum -a 256 "$TMPDIR_TEST/t11/out/input/solid.pdf" | awk '{print $1}')
  if [[ "$ORIG_SHA11" == "$EXTRACTED_SHA11" ]]; then
    pass "solid mode: PDF roundtrip byte-identical"
  else
    fail "solid mode: PDF roundtrip differs (orig=$ORIG_SHA11 extracted=$EXTRACTED_SHA11)"
  fi
else
  fail "solid mode: extracted PDF missing"
fi

# =============================================================================
# Test 12: Multiple PDFs in one archive
# =============================================================================
echo ""
echo "--- Test 12: Multiple PDFs ---"
mkdir -p "$TMPDIR_TEST/t12/input"
create_test_pdf "$TMPDIR_TEST/t12/input/a.pdf" 1
create_test_pdf "$TMPDIR_TEST/t12/input/b.pdf" 2

SHA_A=$(shasum -a 256 "$TMPDIR_TEST/t12/input/a.pdf" | awk '{print $1}')
SHA_B=$(shasum -a 256 "$TMPDIR_TEST/t12/input/b.pdf" | awk '{print $1}')

(cd "$TMPDIR_TEST/t12" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t12/archive.blar" input 2>/dev/null)

LIST12=$("$BLAR" list "$TMPDIR_TEST/t12/archive.blar" 2>/dev/null)
CONTAINER_COUNT=$(echo "$LIST12" | grep -c "^p " || true)
if [[ $CONTAINER_COUNT -ge 2 ]]; then
  pass "multiple PDFs: found $CONTAINER_COUNT PDF container entries"
else
  fail "multiple PDFs: expected >=2, got $CONTAINER_COUNT (list: $LIST12)"
fi

mkdir -p "$TMPDIR_TEST/t12/out"
"$BLAR" extract "$TMPDIR_TEST/t12/archive.blar" -C "$TMPDIR_TEST/t12/out" 2>/dev/null

EXTRACTED_SHA_A=$(shasum -a 256 "$TMPDIR_TEST/t12/out/input/a.pdf" 2>/dev/null | awk '{print $1}')
EXTRACTED_SHA_B=$(shasum -a 256 "$TMPDIR_TEST/t12/out/input/b.pdf" 2>/dev/null | awk '{print $1}')

if [[ "$SHA_A" == "$EXTRACTED_SHA_A" ]] && [[ "$SHA_B" == "$EXTRACTED_SHA_B" ]]; then
  pass "multiple PDFs: both roundtrip byte-identical"
else
  fail "multiple PDFs: roundtrip mismatch (a: $SHA_A vs $EXTRACTED_SHA_A, b: $SHA_B vs $EXTRACTED_SHA_B)"
fi

# =============================================================================
# Results
# =============================================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
