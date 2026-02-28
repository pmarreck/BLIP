#!/usr/bin/env bash
set -u

# =============================================================================
# JSON serialization/deserialization integration test suite
# =============================================================================
# Exercises to-json and from-json commands in both blar and miniblar CLIs:
# round-trip, jq manipulation, content/metadata changes, error handling.
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

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "FATAL: jq not found (required for JSON manipulation tests)"
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

# --------------- create test fixtures ---------------
echo -n "hello world" > "$TMPDIR_TEST/hello.txt"
echo -n "second file" > "$TMPDIR_TEST/second.txt"
echo -n "third file" > "$TMPDIR_TEST/third.txt"
echo -n "" > "$TMPDIR_TEST/empty.txt"

# Create binary file with all 256 byte values
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)))" > "$TMPDIR_TEST/binary.bin"

# Create archives from within the temp directory so paths are basenames
pushd "$TMPDIR_TEST" > /dev/null

# Multi-file archive
"$BLAR" create -o multi.blar hello.txt second.txt third.txt 2>/dev/null

# Single-file archive
"$BLAR" create -o single.blar hello.txt 2>/dev/null

# Archive with empty file
"$BLAR" create -o empty.blar empty.txt 2>/dev/null

# Archive with binary content
"$BLAR" create -o binary.blar binary.bin 2>/dev/null

# Archive with directory structure
mkdir -p mydir/sub
echo -n "dir file" > mydir/file.txt
echo -n "sub file" > mydir/sub/deep.txt
"$BLAR" create -o dirs.blar mydir 2>/dev/null

# Miniblar archive (flat, no dirs)
"$MINIBLAR" create -o mini.mblar hello.txt second.txt 2>/dev/null

popd > /dev/null

# =============================================================================
# 1. Basic round-trip: create → to-json → from-json → verify → content identical
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/multi.blar" > "$TMPDIR_TEST/multi.json"
"$BLAR" from-json "$TMPDIR_TEST/multi.json" -o "$TMPDIR_TEST/multi_rt.blar"
"$BLAR" verify "$TMPDIR_TEST/multi_rt.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "1. basic round-trip verify" || fail "1. basic round-trip verify failed"

# Verify content matches
for path in hello.txt second.txt third.txt; do
  ORIG=$("$BLAR" cat "$TMPDIR_TEST/multi.blar" "$path" 2>/dev/null)
  RT=$("$BLAR" cat "$TMPDIR_TEST/multi_rt.blar" "$path" 2>/dev/null)
  if [[ "$ORIG" != "$RT" ]]; then
    fail "1. round-trip content mismatch for $path"
  fi
done
pass "1. round-trip content identical"

# =============================================================================
# 2. Valid JSON: to-json output parses with jq
# =============================================================================

COUNT=$("$BLAR" to-json "$TMPDIR_TEST/multi.blar" | jq '.entries | length')
[[ "$COUNT" == "3" ]] && pass "2. valid JSON, entry count = 3" || fail "2. jq entry count: got '$COUNT'"

# =============================================================================
# 3. Content manipulation: change file content via jq
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | jq '(.entries[] | select(.path=="hello.txt")).content = "new content"' \
  > "$TMPDIR_TEST/modified.json"
"$BLAR" from-json "$TMPDIR_TEST/modified.json" -o "$TMPDIR_TEST/modified.blar"
OUT=$("$BLAR" cat "$TMPDIR_TEST/modified.blar" "hello.txt")
[[ "$OUT" == "new content" ]] && pass "3. content manipulation via jq" || fail "3. content via jq: got '$OUT'"

"$BLAR" verify "$TMPDIR_TEST/modified.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "3. verify after content change" || fail "3. verify after content change failed"

# =============================================================================
# 4. Path rename: rename file via jq
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | jq '(.entries[] | select(.path=="hello.txt")).path = "renamed.txt"' \
  > "$TMPDIR_TEST/renamed.json"
"$BLAR" from-json "$TMPDIR_TEST/renamed.json" -o "$TMPDIR_TEST/renamed.blar"
LIST=$("$BLAR" list "$TMPDIR_TEST/renamed.blar")
[[ "$LIST" == *"renamed.txt"* ]] && pass "4. path rename via jq" || fail "4. path rename: got '$LIST'"

# =============================================================================
# 5. Mode change: change permissions via jq
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | jq '(.entries[] | select(.path=="hello.txt")).mode = "0755"' \
  > "$TMPDIR_TEST/modechange.json"
"$BLAR" from-json "$TMPDIR_TEST/modechange.json" -o "$TMPDIR_TEST/modechange.blar"
MODE=$("$BLAR" peek "$TMPDIR_TEST/modechange.blar" "[1][0][0][md]" --hex)
# Mode 0755 = 0x01ED in LE = ed01 hex
[[ "$MODE" == *"ed01"* || "$MODE" == *"ED01"* ]] \
  && pass "5. mode change via jq" || fail "5. mode change: got '$MODE'"

# =============================================================================
# 6. Timestamp change: modify mtime via jq
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | jq '(.entries[] | select(.path=="hello.txt")).mtime = "2026-01-01T00:00:00.000000000Z"' \
  > "$TMPDIR_TEST/timechange.json"
"$BLAR" from-json "$TMPDIR_TEST/timechange.json" -o "$TMPDIR_TEST/timechange.blar"
"$BLAR" verify "$TMPDIR_TEST/timechange.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "6. timestamp change + verify" || fail "6. timestamp change verify failed"

# =============================================================================
# 7. Add new entry: append file entry via jq
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | jq '.entries += [{"type":"file","path":"new.txt","content":"added"}]' \
  > "$TMPDIR_TEST/added.json"
"$BLAR" from-json "$TMPDIR_TEST/added.json" -o "$TMPDIR_TEST/added.blar"

COUNT=$("$BLAR" to-json "$TMPDIR_TEST/added.blar" | jq '.entries | length')
[[ "$COUNT" == "2" ]] && pass "7. add entry: count = 2" || fail "7. add entry count: got '$COUNT'"

OUT=$("$BLAR" cat "$TMPDIR_TEST/added.blar" "new.txt")
[[ "$OUT" == "added" ]] && pass "7. added file content correct" || fail "7. added file content: got '$OUT'"

# =============================================================================
# 8. Remove entry: filter out an entry via jq
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | jq '.entries = [.entries[] | select(.path != "second.txt")]' \
  > "$TMPDIR_TEST/removed.json"
"$BLAR" from-json "$TMPDIR_TEST/removed.json" -o "$TMPDIR_TEST/removed.blar"

COUNT=$("$BLAR" to-json "$TMPDIR_TEST/removed.blar" | jq '.entries | length')
[[ "$COUNT" == "2" ]] && pass "8. remove entry: count = 2" || fail "8. remove entry count: got '$COUNT'"

"$BLAR" verify "$TMPDIR_TEST/removed.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "8. verify after remove" || fail "8. verify after remove failed"

# =============================================================================
# 9. Reorder entries: reverse entry order via jq, verify deterministic output
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | jq '.entries |= reverse' \
  > "$TMPDIR_TEST/reversed.json"
"$BLAR" from-json "$TMPDIR_TEST/reversed.json" -o "$TMPDIR_TEST/reversed.blar"

# Archives should produce same listing (sorted by path)
LIST_ORIG=$("$BLAR" list "$TMPDIR_TEST/multi.blar" | sort)
LIST_REV=$("$BLAR" list "$TMPDIR_TEST/reversed.blar" | sort)
[[ "$LIST_ORIG" == "$LIST_REV" ]] && pass "9. reorder: same entries after sort" || fail "9. reorder mismatch"

# =============================================================================
# 10. Binary content: round-trip preserves bytes exactly
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/binary.blar" > "$TMPDIR_TEST/binary.json"
"$BLAR" from-json "$TMPDIR_TEST/binary.json" -o "$TMPDIR_TEST/binary_rt.blar"

# Extract content and compare byte-for-byte
"$BLAR" cat "$TMPDIR_TEST/binary.blar" "binary.bin" > "$TMPDIR_TEST/orig_content"
"$BLAR" cat "$TMPDIR_TEST/binary_rt.blar" "binary.bin" > "$TMPDIR_TEST/rt_content"
if cmp -s "$TMPDIR_TEST/orig_content" "$TMPDIR_TEST/rt_content"; then
  pass "10. binary content round-trip exact"
else
  fail "10. binary content round-trip differs"
fi

# =============================================================================
# 11. Multi-file integrity: modify one file, verify others unchanged
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | jq '(.entries[] | select(.path=="second.txt")).content = "CHANGED"' \
  > "$TMPDIR_TEST/onemod.json"
"$BLAR" from-json "$TMPDIR_TEST/onemod.json" -o "$TMPDIR_TEST/onemod.blar"

OUT1=$("$BLAR" cat "$TMPDIR_TEST/onemod.blar" "hello.txt")
OUT2=$("$BLAR" cat "$TMPDIR_TEST/onemod.blar" "second.txt")
OUT3=$("$BLAR" cat "$TMPDIR_TEST/onemod.blar" "third.txt")
[[ "$OUT1" == "hello world" && "$OUT2" == "CHANGED" && "$OUT3" == "third file" ]] \
  && pass "11. multi-file: others unchanged" || fail "11. multi-file integrity: '$OUT1' '$OUT2' '$OUT3'"

# =============================================================================
# 12. Directory entries: blar archive with dirs round-trips correctly
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/dirs.blar" > "$TMPDIR_TEST/dirs.json"
"$BLAR" from-json "$TMPDIR_TEST/dirs.json" -o "$TMPDIR_TEST/dirs_rt.blar"
"$BLAR" verify "$TMPDIR_TEST/dirs_rt.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "12. directory entries round-trip verify" || fail "12. dir round-trip verify failed"

# Check dir entries exist
DIR_TYPES=$("$BLAR" to-json "$TMPDIR_TEST/dirs_rt.blar" | jq '[.entries[] | .type] | sort | unique')
[[ "$DIR_TYPES" == *'"dir"'* && "$DIR_TYPES" == *'"file"'* ]] \
  && pass "12. dir and file types present" || fail "12. entry types: got '$DIR_TYPES'"

# =============================================================================
# 13. Minimal JSON input: only required fields creates valid archive
# =============================================================================

cat > "$TMPDIR_TEST/minimal.json" << 'EOF'
{
  "version": 1,
  "entries": [
    {"type": "file", "path": "minimal.txt", "content": "minimal content"}
  ]
}
EOF
"$BLAR" from-json "$TMPDIR_TEST/minimal.json" -o "$TMPDIR_TEST/minimal.blar"
"$BLAR" verify "$TMPDIR_TEST/minimal.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "13. minimal JSON input creates valid archive" || fail "13. minimal JSON verify failed"

OUT=$("$BLAR" cat "$TMPDIR_TEST/minimal.blar" "minimal.txt")
[[ "$OUT" == "minimal content" ]] && pass "13. minimal content correct" || fail "13. minimal content: got '$OUT'"

# =============================================================================
# 14. uid/gid/username/groupname: metadata round-trips
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" > "$TMPDIR_TEST/meta.json"
# Check that uid/gid fields are present in JSON (from the real archive)
HAS_UID=$("$BLAR" to-json "$TMPDIR_TEST/single.blar" | jq '.entries[0] | has("uid")')
# uid might be zero and omitted; just verify round-trip works
"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | jq '(.entries[0]).uid = 1000 | (.entries[0]).gid = 100 | (.entries[0]).username = "testuser" | (.entries[0]).groupname = "testgroup"' \
  > "$TMPDIR_TEST/uidgid.json"
"$BLAR" from-json "$TMPDIR_TEST/uidgid.json" -o "$TMPDIR_TEST/uidgid.blar"
"$BLAR" verify "$TMPDIR_TEST/uidgid.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "14. uid/gid/username/groupname verify" || fail "14. uid/gid verify failed"

# Round-trip the uid/gid archive and check values preserved
UID_RT=$("$BLAR" to-json "$TMPDIR_TEST/uidgid.blar" | jq '.entries[0].uid')
GID_RT=$("$BLAR" to-json "$TMPDIR_TEST/uidgid.blar" | jq '.entries[0].gid')
UN_RT=$("$BLAR" to-json "$TMPDIR_TEST/uidgid.blar" | jq -r '.entries[0].username')
GN_RT=$("$BLAR" to-json "$TMPDIR_TEST/uidgid.blar" | jq -r '.entries[0].groupname')
[[ "$UID_RT" == "1000" && "$GID_RT" == "100" && "$UN_RT" == "testuser" && "$GN_RT" == "testgroup" ]] \
  && pass "14. uid/gid/username/groupname round-trip" || fail "14. metadata: uid=$UID_RT gid=$GID_RT un=$UN_RT gn=$GN_RT"

# =============================================================================
# 15. Empty content: empty file round-trips
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/empty.blar" > "$TMPDIR_TEST/empty.json"
"$BLAR" from-json "$TMPDIR_TEST/empty.json" -o "$TMPDIR_TEST/empty_rt.blar"
OUT=$("$BLAR" cat "$TMPDIR_TEST/empty_rt.blar" "empty.txt")
[[ "$OUT" == "" ]] && pass "15. empty file round-trip" || fail "15. empty file: got '$OUT'"

# =============================================================================
# 16. from-json with -o flag: output to specified file
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" > "$TMPDIR_TEST/for_output.json"
"$BLAR" from-json "$TMPDIR_TEST/for_output.json" -o "$TMPDIR_TEST/output_test.blar"
[[ -f "$TMPDIR_TEST/output_test.blar" ]] && pass "16. -o flag creates output file" || fail "16. -o output file missing"
"$BLAR" verify "$TMPDIR_TEST/output_test.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "16. -o output verifies" || fail "16. -o output verify failed"

# =============================================================================
# 17. from-json from stdin: pipe JSON into from-json
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | "$BLAR" from-json -o "$TMPDIR_TEST/stdin_test.blar"
"$BLAR" verify "$TMPDIR_TEST/stdin_test.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "17. from-json from stdin" || fail "17. stdin from-json verify failed"

# =============================================================================
# 18. Error: malformed JSON
# =============================================================================

echo "NOT JSON {{{" > "$TMPDIR_TEST/bad.json"
if "$BLAR" from-json "$TMPDIR_TEST/bad.json" -o "$TMPDIR_TEST/bad.blar" 2>/dev/null; then
  fail "18. malformed JSON should fail"
else
  pass "18. malformed JSON returns error"
fi

# =============================================================================
# 19. Error: missing required "path" field
# =============================================================================

cat > "$TMPDIR_TEST/nopath.json" << 'EOF'
{
  "version": 1,
  "entries": [
    {"type": "file", "content": "no path here"}
  ]
}
EOF
if "$BLAR" from-json "$TMPDIR_TEST/nopath.json" -o "$TMPDIR_TEST/nopath.blar" 2>/dev/null; then
  fail "19. missing path should fail"
else
  pass "19. missing path returns error"
fi

# =============================================================================
# 20. miniblar to-json / from-json: works identically
# =============================================================================

"$MINIBLAR" to-json "$TMPDIR_TEST/mini.mblar" > "$TMPDIR_TEST/mini.json"
COUNT=$("$MINIBLAR" to-json "$TMPDIR_TEST/mini.mblar" | jq '.entries | length')
[[ "$COUNT" == "2" ]] && pass "20. miniblar to-json works" || fail "20. miniblar to-json count: got '$COUNT'"

"$MINIBLAR" from-json "$TMPDIR_TEST/mini.json" -o "$TMPDIR_TEST/mini_rt.mblar"
"$MINIBLAR" verify "$TMPDIR_TEST/mini_rt.mblar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "20. miniblar from-json round-trip" || fail "20. miniblar from-json verify failed"

# =============================================================================
# 21. --help: shows usage for both commands
# =============================================================================

OUT=$("$BLAR" to-json --help 2>&1)
[[ "$OUT" == *"to-json"* && "$OUT" == *"Usage"* ]] && pass "21a. to-json --help" || fail "21a. to-json --help: got '$OUT'"

OUT=$("$BLAR" from-json --help 2>&1)
[[ "$OUT" == *"from-json"* && "$OUT" == *"Usage"* ]] && pass "21b. from-json --help" || fail "21b. from-json --help: got '$OUT'"

# =============================================================================
# 22. xattrs preservation (if platform supports)
# =============================================================================

# xattrs are platform-dependent; just test the JSON representation round-trips
# by injecting xattrs via jq
"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | jq '(.entries[0]).xattrs = {"com.apple.quarantine": "test_value"}' \
  > "$TMPDIR_TEST/xattr.json"
"$BLAR" from-json "$TMPDIR_TEST/xattr.json" -o "$TMPDIR_TEST/xattr.blar"
"$BLAR" verify "$TMPDIR_TEST/xattr.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "22. xattrs round-trip verify" || fail "22. xattrs verify failed"

XATTR_RT=$("$BLAR" to-json "$TMPDIR_TEST/xattr.blar" | jq -r '.entries[0].xattrs["com.apple.quarantine"]')
[[ "$XATTR_RT" == "test_value" ]] \
  && pass "22. xattrs value preserved" || fail "22. xattr value: got '$XATTR_RT'"

# =============================================================================
# 23. Verify after every from-json: blar verify passes
# =============================================================================

# This is implicitly tested in all above tests, but let's do one final explicit check
"$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | jq '(.entries[] | select(.path=="hello.txt")).content = "final test"' \
  | "$BLAR" from-json -o "$TMPDIR_TEST/final.blar"
"$BLAR" verify "$TMPDIR_TEST/final.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "23. final verify passes" || fail "23. final verify failed"

# =============================================================================
# 24. Byte-identical round-trip: archive → to-json → from-json → cmp
# =============================================================================

# Multi-file archive: bytes must be identical after JSON round-trip
"$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | "$BLAR" from-json -o "$TMPDIR_TEST/multi_cmp.blar"
if cmp -s "$TMPDIR_TEST/multi.blar" "$TMPDIR_TEST/multi_cmp.blar"; then
  pass "24a. byte-identical round-trip (multi-file)"
else
  fail "24a. multi-file archives differ after JSON round-trip"
fi

# Single-file archive
"$BLAR" to-json "$TMPDIR_TEST/single.blar" \
  | "$BLAR" from-json -o "$TMPDIR_TEST/single_cmp.blar"
if cmp -s "$TMPDIR_TEST/single.blar" "$TMPDIR_TEST/single_cmp.blar"; then
  pass "24b. byte-identical round-trip (single-file)"
else
  fail "24b. single-file archives differ after JSON round-trip"
fi

# Binary content archive
"$BLAR" to-json "$TMPDIR_TEST/binary.blar" \
  | "$BLAR" from-json -o "$TMPDIR_TEST/binary_cmp.blar"
if cmp -s "$TMPDIR_TEST/binary.blar" "$TMPDIR_TEST/binary_cmp.blar"; then
  pass "24c. byte-identical round-trip (binary content)"
else
  fail "24c. binary archives differ after JSON round-trip"
fi

# Directory archive
"$BLAR" to-json "$TMPDIR_TEST/dirs.blar" \
  | "$BLAR" from-json -o "$TMPDIR_TEST/dirs_cmp.blar"
if cmp -s "$TMPDIR_TEST/dirs.blar" "$TMPDIR_TEST/dirs_cmp.blar"; then
  pass "24d. byte-identical round-trip (directory archive)"
else
  fail "24d. directory archives differ after JSON round-trip"
fi

# Empty file archive
"$BLAR" to-json "$TMPDIR_TEST/empty.blar" \
  | "$BLAR" from-json -o "$TMPDIR_TEST/empty_cmp.blar"
if cmp -s "$TMPDIR_TEST/empty.blar" "$TMPDIR_TEST/empty_cmp.blar"; then
  pass "24e. byte-identical round-trip (empty file)"
else
  fail "24e. empty file archives differ after JSON round-trip"
fi

# Miniblar archive
"$MINIBLAR" to-json "$TMPDIR_TEST/mini.mblar" \
  | "$MINIBLAR" from-json -o "$TMPDIR_TEST/mini_cmp.mblar"
if cmp -s "$TMPDIR_TEST/mini.mblar" "$TMPDIR_TEST/mini_cmp.mblar"; then
  pass "24f. byte-identical round-trip (miniblar)"
else
  fail "24f. miniblar archives differ after JSON round-trip"
fi

# =============================================================================
# 25. from-json -z produces compressed archive
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | "$BLAR" from-json -z -o "$TMPDIR_TEST/compressed.blar"
# Verify blar list works (read_archive decompresses transparently)
"$BLAR" list "$TMPDIR_TEST/compressed.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "25a. from-json -z: list works" || fail "25a. from-json -z: list failed"

# Content matches original
for path in hello.txt second.txt third.txt; do
  ORIG=$("$BLAR" cat "$TMPDIR_TEST/multi.blar" "$path" 2>/dev/null)
  COMP=$("$BLAR" cat "$TMPDIR_TEST/compressed.blar" "$path" 2>/dev/null)
  if [[ "$ORIG" != "$COMP" ]]; then
    fail "25b. from-json -z: content mismatch for $path"
  fi
done
pass "25b. from-json -z: content matches original"

# Compressed archive should differ from uncompressed (larger header/different bytes)
if cmp -s "$TMPDIR_TEST/multi.blar" "$TMPDIR_TEST/compressed.blar"; then
  fail "25c. from-json -z: compressed archive identical to uncompressed (compression not applied)"
else
  pass "25c. from-json -z: compressed archive differs from uncompressed"
fi

# =============================================================================
# 26. from-json -e produces encrypted archive
# =============================================================================

BLIP_PASSWORD=testpass "$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | BLIP_PASSWORD=testpass "$BLAR" from-json -e -o "$TMPDIR_TEST/encrypted.blar"

# List without password should fail
if "$BLAR" list "$TMPDIR_TEST/encrypted.blar" > /dev/null 2>&1; then
  fail "26a. from-json -e: list without password should fail"
else
  pass "26a. from-json -e: list without password fails correctly"
fi

# List with password should succeed
BLIP_PASSWORD=testpass "$BLAR" list "$TMPDIR_TEST/encrypted.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "26b. from-json -e: list with password works" || fail "26b. from-json -e: list with password failed"

# Content matches original
for path in hello.txt second.txt third.txt; do
  ORIG=$("$BLAR" cat "$TMPDIR_TEST/multi.blar" "$path" 2>/dev/null)
  ENC=$(BLIP_PASSWORD=testpass "$BLAR" cat "$TMPDIR_TEST/encrypted.blar" "$path" 2>/dev/null)
  if [[ "$ORIG" != "$ENC" ]]; then
    fail "26c. from-json -e: content mismatch for $path"
  fi
done
pass "26c. from-json -e: content matches original"

# =============================================================================
# 27. from-json -z -e produces compressed+encrypted archive
# =============================================================================

BLIP_PASSWORD=testpass "$BLAR" to-json "$TMPDIR_TEST/multi.blar" \
  | BLIP_PASSWORD=testpass "$BLAR" from-json -z -e -o "$TMPDIR_TEST/both.blar"

# List with password should succeed
BLIP_PASSWORD=testpass "$BLAR" list "$TMPDIR_TEST/both.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "27a. from-json -z -e: list with password works" || fail "27a. from-json -z -e: list with password failed"

# Content matches original
for path in hello.txt second.txt third.txt; do
  ORIG=$("$BLAR" cat "$TMPDIR_TEST/multi.blar" "$path" 2>/dev/null)
  BOTH=$(BLIP_PASSWORD=testpass "$BLAR" cat "$TMPDIR_TEST/both.blar" "$path" 2>/dev/null)
  if [[ "$ORIG" != "$BOTH" ]]; then
    fail "27b. from-json -z -e: content mismatch for $path"
  fi
done
pass "27b. from-json -z -e: content matches original"

# =============================================================================
# 28. from-json -e chacha with --kdf pbkdf2
# =============================================================================

"$BLAR" to-json "$TMPDIR_TEST/single.blar" > "$TMPDIR_TEST/for_chacha.json"
BLIP_PASSWORD=testpass "$BLAR" from-json -e chacha --kdf pbkdf2 -o "$TMPDIR_TEST/chacha.blar" "$TMPDIR_TEST/for_chacha.json"

BLIP_PASSWORD=testpass "$BLAR" list "$TMPDIR_TEST/chacha.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "28. from-json -e chacha --kdf pbkdf2 works" || fail "28. from-json -e chacha --kdf pbkdf2 failed"

# =============================================================================
# 29. from-json -e without BLIP_PASSWORD warns and skips encryption
# =============================================================================

unset BLIP_PASSWORD
"$BLAR" from-json -e -o "$TMPDIR_TEST/no_pw.blar" "$TMPDIR_TEST/for_chacha.json" 2>"$TMPDIR_TEST/no_pw_err.txt"

# Verify stderr contains warning about BLIP_PASSWORD
if grep -qi "warning" "$TMPDIR_TEST/no_pw_err.txt" && grep -qi "BLIP_PASSWORD" "$TMPDIR_TEST/no_pw_err.txt"; then
  pass "29a. from-json -e no password: warning printed"
else
  fail "29a. from-json -e no password: expected warning about BLIP_PASSWORD, got: $(cat "$TMPDIR_TEST/no_pw_err.txt")"
fi

# Output should NOT be encrypted (list works without password)
"$BLAR" list "$TMPDIR_TEST/no_pw.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "29b. from-json -e no password: output is not encrypted" || fail "29b. from-json -e no password: output should be readable without password"

# =============================================================================
# 30. Full round-trip: create -z -e → to-json → from-json -z -e → verify content
# =============================================================================

BLIP_PASSWORD=roundtrip "$BLAR" create -z -e -o "$TMPDIR_TEST/full_rt_orig.blar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/second.txt" 2>/dev/null

# to-json decrypts+decompresses transparently
BLIP_PASSWORD=roundtrip "$BLAR" to-json "$TMPDIR_TEST/full_rt_orig.blar" \
  | BLIP_PASSWORD=roundtrip "$BLAR" from-json -z -e -o "$TMPDIR_TEST/full_rt_new.blar"

# Verify the new archive with password
BLIP_PASSWORD=roundtrip "$BLAR" list "$TMPDIR_TEST/full_rt_new.blar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "30a. full round-trip: list with password works" || fail "30a. full round-trip: list failed"

# Content matches
ORIG=$(BLIP_PASSWORD=roundtrip "$BLAR" cat "$TMPDIR_TEST/full_rt_orig.blar" "hello.txt" 2>/dev/null)
NEW=$(BLIP_PASSWORD=roundtrip "$BLAR" cat "$TMPDIR_TEST/full_rt_new.blar" "hello.txt" 2>/dev/null)
[[ "$ORIG" == "$NEW" ]] && pass "30b. full round-trip: content matches" || fail "30b. full round-trip: content mismatch: '$ORIG' vs '$NEW'"

# =============================================================================
# 31. from-json --help shows -z and -e flags
# =============================================================================

OUT=$("$BLAR" from-json --help 2>&1)
[[ "$OUT" == *"-z"* && "$OUT" == *"-e"* && "$OUT" == *"--kdf"* ]] \
  && pass "31. from-json --help shows -z, -e, --kdf" || fail "31. from-json --help missing flags: got '$OUT'"

# =============================================================================
# Results
# =============================================================================

echo
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ "$FAIL" -eq 0 ]] || exit 1
