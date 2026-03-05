#!/usr/bin/env bash
set -u

# =============================================================================
# Container expansion integration test suite
# =============================================================================
# Tests transparent zip container expansion/re-assembly in blar.
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

# --------------- helper: create a test zip ---------------
create_test_zip() {
  local zip_path="$1"
  shift
  python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED)
args = sys.argv[2:]
i = 0
while i < len(args):
    path = args[i]
    content = args[i+1] if i+1 < len(args) else ''
    if path.endswith('/'):
        import zipfile as z
        zi = z.ZipInfo(path)
        zi.external_attr = 0o755 << 16 | 0x10
        zf.writestr(zi, '')
    else:
        zf.writestr(path, content)
    i += 2
zf.close()
" "$zip_path" "$@"
}

# =============================================================================
# Test 1: Basic container expansion roundtrip
# =============================================================================
mkdir -p "$TMPDIR_TEST/t1/input"
create_test_zip "$TMPDIR_TEST/t1/input/document.docx" \
  "[Content_Types].xml" '<?xml version="1.0"?><Types></Types>' \
  "word/document.xml" '<w:document>Hello World</w:document>'

(cd "$TMPDIR_TEST/t1/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t1/archive.blar" document.docx 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "container expansion: archive created"
else
  fail "container expansion: archive creation failed (rc=$rc)"
fi

# Extract and verify content
mkdir -p "$TMPDIR_TEST/t1/out"
"$BLAR" extract "$TMPDIR_TEST/t1/archive.blar" -C "$TMPDIR_TEST/t1/out" 2>/dev/null

if [[ -f "$TMPDIR_TEST/t1/out/document.docx" ]]; then
  python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'r')
names = zf.namelist()
zf.close()
if '[Content_Types].xml' in names and 'word/document.xml' in names:
    sys.exit(0)
else:
    print('Missing entries:', names, file=sys.stderr)
    sys.exit(1)
" "$TMPDIR_TEST/t1/out/document.docx"
  if [[ $? -eq 0 ]]; then
    pass "container expansion: roundtrip content preserved"
  else
    fail "container expansion: roundtrip content not preserved"
  fi
else
  fail "container expansion: extracted file missing"
fi

# Verify extracted zip content matches original
ORIG_CONTENT=$(python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'r')
print(zf.read('word/document.xml').decode(), end='')
zf.close()
" "$TMPDIR_TEST/t1/input/document.docx")
EXTRACTED_CONTENT=$(python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'r')
print(zf.read('word/document.xml').decode(), end='')
zf.close()
" "$TMPDIR_TEST/t1/out/document.docx" 2>/dev/null)
if [[ "$ORIG_CONTENT" == "$EXTRACTED_CONTENT" ]]; then
  pass "container expansion: inner file content matches"
else
  fail "container expansion: inner file content differs"
fi

# =============================================================================
# Test 2: blar list shows 'z' prefix for container dirs
# =============================================================================
LIST_OUTPUT=$("$BLAR" list "$TMPDIR_TEST/t1/archive.blar" 2>/dev/null)
if echo "$LIST_OUTPUT" | grep -q "^z "; then
  pass "list shows 'z' prefix for container dirs"
else
  fail "list does not show 'z' prefix (got: $LIST_OUTPUT)"
fi

# =============================================================================
# Test 3: blar info --json includes container metadata
# =============================================================================
INFO_JSON=$("$BLAR" info --json "$TMPDIR_TEST/t1/archive.blar" 2>/dev/null)
if echo "$INFO_JSON" | grep -q '"container_type"'; then
  pass "info --json includes container_type"
else
  fail "info --json missing container_type"
fi

if echo "$INFO_JSON" | grep -q '"zip_compression_method"'; then
  pass "info --json includes zip_compression_method"
else
  fail "info --json missing zip_compression_method"
fi

# =============================================================================
# Test 4: --no-expand-containers stores zip as opaque
# =============================================================================
mkdir -p "$TMPDIR_TEST/t4/input"
create_test_zip "$TMPDIR_TEST/t4/input/data.xlsx" \
  "sheet1.xml" '<worksheet>data</worksheet>'

(cd "$TMPDIR_TEST/t4/input" && "$BLAR" create -z --no-expand-containers -f -o "$TMPDIR_TEST/t4/archive.blar" data.xlsx 2>/dev/null)

LIST4=$("$BLAR" list "$TMPDIR_TEST/t4/archive.blar" 2>/dev/null)
if echo "$LIST4" | grep -q "^- "; then
  pass "--no-expand-containers: stored as opaque file"
else
  fail "--no-expand-containers: not stored as opaque file"
fi
if echo "$LIST4" | grep -q "^z "; then
  fail "--no-expand-containers: unexpectedly expanded"
else
  pass "--no-expand-containers: no container expansion"
fi

# =============================================================================
# Test 5: .zip extension NOT expanded by default
# =============================================================================
mkdir -p "$TMPDIR_TEST/t5/input"
create_test_zip "$TMPDIR_TEST/t5/input/archive_data.zip" \
  "file1.txt" "hello" \
  "file2.txt" "world"

(cd "$TMPDIR_TEST/t5/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t5/archive.blar" archive_data.zip 2>/dev/null)

LIST5=$("$BLAR" list "$TMPDIR_TEST/t5/archive.blar" 2>/dev/null)
if echo "$LIST5" | grep -q "^z "; then
  fail ".zip extension expanded by default (should not)"
else
  pass ".zip extension NOT expanded by default"
fi

# =============================================================================
# Test 6: --expand-all-zips DOES expand .zip files
# =============================================================================
mkdir -p "$TMPDIR_TEST/t6/input"
create_test_zip "$TMPDIR_TEST/t6/input/data.zip" \
  "inner.txt" "expanded content"

(cd "$TMPDIR_TEST/t6/input" && "$BLAR" create -z --expand-all-zips -f -o "$TMPDIR_TEST/t6/archive.blar" data.zip 2>/dev/null)

LIST6=$("$BLAR" list "$TMPDIR_TEST/t6/archive.blar" 2>/dev/null)
if echo "$LIST6" | grep -q "^z "; then
  pass "--expand-all-zips: .zip file expanded"
else
  fail "--expand-all-zips: .zip file not expanded (got: $LIST6)"
fi

# Roundtrip
mkdir -p "$TMPDIR_TEST/t6/out"
"$BLAR" extract "$TMPDIR_TEST/t6/archive.blar" -C "$TMPDIR_TEST/t6/out" 2>/dev/null
INNER=$(python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'r')
print(zf.read('inner.txt').decode(), end='')
zf.close()
" "$TMPDIR_TEST/t6/out/data.zip" 2>/dev/null)
if [[ "$INNER" == "expanded content" ]]; then
  pass "--expand-all-zips: roundtrip preserves content"
else
  fail "--expand-all-zips: roundtrip content differs (got: $INNER)"
fi

# =============================================================================
# Test 7: Multiple containers in one archive
# =============================================================================
mkdir -p "$TMPDIR_TEST/t7/input"
create_test_zip "$TMPDIR_TEST/t7/input/doc1.docx" \
  "content.xml" '<doc>Document 1</doc>'
create_test_zip "$TMPDIR_TEST/t7/input/doc2.epub" \
  "mimetype" "application/epub+zip" \
  "content.opf" '<package>Book</package>'

(cd "$TMPDIR_TEST/t7" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t7/archive.blar" input 2>/dev/null)

LIST7=$("$BLAR" list "$TMPDIR_TEST/t7/archive.blar" 2>/dev/null)
CONTAINER_COUNT=$(echo "$LIST7" | grep -c "^z " || true)
if [[ $CONTAINER_COUNT -ge 2 ]]; then
  pass "multiple containers: found $CONTAINER_COUNT container entries"
else
  fail "multiple containers: expected >=2, got $CONTAINER_COUNT (list: $LIST7)"
fi

# =============================================================================
# Test 8: Nested dirs within zip container
# =============================================================================
mkdir -p "$TMPDIR_TEST/t8/input"
create_test_zip "$TMPDIR_TEST/t8/input/nested.docx" \
  "top.xml" '<top/>' \
  "sub/" "" \
  "sub/deep.xml" '<deep/>'

(cd "$TMPDIR_TEST/t8/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t8/archive.blar" nested.docx 2>/dev/null)

mkdir -p "$TMPDIR_TEST/t8/out"
"$BLAR" extract "$TMPDIR_TEST/t8/archive.blar" -C "$TMPDIR_TEST/t8/out" 2>/dev/null

DEEP=$(python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'r')
print(zf.read('sub/deep.xml').decode(), end='')
zf.close()
" "$TMPDIR_TEST/t8/out/nested.docx" 2>/dev/null)
if [[ "$DEEP" == "<deep/>" ]]; then
  pass "nested dirs in container: content preserved"
else
  fail "nested dirs in container: content differs (got: $DEEP)"
fi

# =============================================================================
# Test 9: Empty zip roundtrip
# =============================================================================
mkdir -p "$TMPDIR_TEST/t9/input"
python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'w')
zf.close()
" "$TMPDIR_TEST/t9/input/empty.docx"

(cd "$TMPDIR_TEST/t9/input" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t9/archive.blar" empty.docx 2>/dev/null)

# Check if expansion happened (empty zip with 0 entries may or may not expand)
LIST9=$("$BLAR" list "$TMPDIR_TEST/t9/archive.blar" 2>/dev/null)
mkdir -p "$TMPDIR_TEST/t9/out"
"$BLAR" extract "$TMPDIR_TEST/t9/archive.blar" -C "$TMPDIR_TEST/t9/out" 2>/dev/null
if [[ -f "$TMPDIR_TEST/t9/out/empty.docx" ]]; then
  pass "empty zip: roundtrip produces file"
else
  fail "empty zip: extracted file missing"
fi

# =============================================================================
# Test 10: Mixed content (containers + regular files)
# =============================================================================
mkdir -p "$TMPDIR_TEST/t10/input/subdir"
echo "plain text file" > "$TMPDIR_TEST/t10/input/readme.txt"
create_test_zip "$TMPDIR_TEST/t10/input/subdir/report.docx" \
  "document.xml" '<report>Q4 Results</report>'
dd if=/dev/urandom of="$TMPDIR_TEST/t10/input/binary.dat" bs=128 count=1 2>/dev/null

(cd "$TMPDIR_TEST/t10" && "$BLAR" create -z -f -o "$TMPDIR_TEST/t10/archive.blar" input 2>/dev/null)

mkdir -p "$TMPDIR_TEST/t10/out"
"$BLAR" extract "$TMPDIR_TEST/t10/archive.blar" -C "$TMPDIR_TEST/t10/out" 2>/dev/null

# Check plain file
if [[ -f "$TMPDIR_TEST/t10/out/input/readme.txt" ]] && \
   [[ "$(cat "$TMPDIR_TEST/t10/out/input/readme.txt")" == "plain text file" ]]; then
  pass "mixed content: plain file preserved"
else
  fail "mixed content: plain file differs"
fi

# Check container
REPORT=$(python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'r')
print(zf.read('document.xml').decode(), end='')
zf.close()
" "$TMPDIR_TEST/t10/out/input/subdir/report.docx" 2>/dev/null)
if [[ "$REPORT" == "<report>Q4 Results</report>" ]]; then
  pass "mixed content: container roundtrip preserved"
else
  fail "mixed content: container differs (got: $REPORT)"
fi

# Check binary file
if cmp -s "$TMPDIR_TEST/t10/input/binary.dat" "$TMPDIR_TEST/t10/out/input/binary.dat"; then
  pass "mixed content: binary file identical"
else
  fail "mixed content: binary file differs"
fi

# =============================================================================
# Test 11: blar verify passes for container archives
# =============================================================================
"$BLAR" verify "$TMPDIR_TEST/t1/archive.blar" 2>/dev/null
if [[ $? -eq 0 ]]; then
  pass "verify passes for container archive"
else
  fail "verify fails for container archive"
fi

# =============================================================================
# Test 12: Solid mode with containers
# =============================================================================
mkdir -p "$TMPDIR_TEST/t12/input"
create_test_zip "$TMPDIR_TEST/t12/input/file.docx" \
  "content.xml" '<solid>test</solid>'
echo "also here" > "$TMPDIR_TEST/t12/input/note.txt"

(cd "$TMPDIR_TEST/t12" && "$BLAR" create -z --solid -f -o "$TMPDIR_TEST/t12/archive.blar" input 2>/dev/null)

mkdir -p "$TMPDIR_TEST/t12/out"
"$BLAR" extract "$TMPDIR_TEST/t12/archive.blar" -C "$TMPDIR_TEST/t12/out" 2>/dev/null

SOLID_CONTENT=$(python3 -c "
import zipfile, sys
zf = zipfile.ZipFile(sys.argv[1], 'r')
print(zf.read('content.xml').decode(), end='')
zf.close()
" "$TMPDIR_TEST/t12/out/input/file.docx" 2>/dev/null)
if [[ "$SOLID_CONTENT" == "<solid>test</solid>" ]]; then
  pass "solid mode: container roundtrip works"
else
  fail "solid mode: container roundtrip differs (got: $SOLID_CONTENT)"
fi

# =============================================================================
# Results
# =============================================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
