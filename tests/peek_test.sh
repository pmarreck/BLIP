#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# peek integration test suite
# =============================================================================
# Exercises the peek command in both blar and miniblar CLIs: navigation,
# accessors (.type, .count, .hash, .keys), output modes (--json, --raw, --type),
# semantic display of known metadata keys, and error handling.
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
"$BLAR" create -o "$TMPDIR_TEST/test.blar" "$TMPDIR_TEST/a.txt" 2>/dev/null

# =============================================================================
# Navigation & type tests
# =============================================================================

# root is ARRAY
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "" --type)
[[ "$OUT" == "ARRAY" ]] && pass "root type is ARRAY" || fail "root type: got '$OUT'"

# [0] is RAW (magic)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[0]" --type)
[[ "$OUT" == "RAW" ]] && pass "[0] is RAW (magic)" || fail "[0] type: got '$OUT'"

# [1] is ARRAY (body)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1]" --type)
[[ "$OUT" == "ARRAY" ]] && pass "[1] is ARRAY (body)" || fail "[1] type: got '$OUT'"

# [1][0] is FILE
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0]" --type)
[[ "$OUT" == "FILE" ]] && pass "[1][0] is FILE" || fail "[1][0] type: got '$OUT'"

# [1][0][0] is DICT (metadata)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0]" --type)
[[ "$OUT" == "DICT" ]] && pass "[1][0][0] is DICT (metadata)" || fail "[1][0][0] type: got '$OUT'"

# [1][0][1] is DATA (content)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][1]" --type)
[[ "$OUT" == "DATA" ]] && pass "[1][0][1] is DATA (content)" || fail "[1][0][1] type: got '$OUT'"

# =============================================================================
# .type accessor (same as --type flag)
# =============================================================================

OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0].type")
[[ "$OUT" == "FILE" ]] && pass ".type accessor works" || fail ".type accessor: got '$OUT'"

# .type at root with empty path
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" ".type")
[[ "$OUT" == "ARRAY" ]] && pass ".type on root" || fail ".type on root: got '$OUT'"

# =============================================================================
# Value extraction
# =============================================================================

# Path value (UTF8 string)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][pa]")
# Path contains "a.txt" (may have prefix from normalization)
[[ "$OUT" == *"a.txt"* ]] && pass "path value contains a.txt" || fail "path value: got '$OUT'"

# Content via --raw
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][1]" --raw)
[[ "$OUT" == "hello" ]] && pass "DATA --raw returns content" || fail "DATA --raw: got '$OUT'"

# =============================================================================
# Semantic display of known metadata keys
# =============================================================================

# md (mode) displayed as octal
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][md]")
# Should be an octal like 0644, 0755 etc
[[ "$OUT" =~ ^0[0-7]{3,4}$ ]] && pass "mode displayed as octal" || fail "mode display: got '$OUT'"

# mt (mtime) displayed as ISO 8601
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][mt]")
[[ "$OUT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && pass "mtime as ISO 8601" || fail "mtime display: got '$OUT'"

# ui (uid) displayed as decimal
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][ui]")
[[ "$OUT" =~ ^[0-9]+$ ]] && pass "uid as decimal" || fail "uid display: got '$OUT'"

# gi (gid) displayed as decimal
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][gi]")
[[ "$OUT" =~ ^[0-9]+$ ]] && pass "gid as decimal" || fail "gid display: got '$OUT'"

# un (username) is a string
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][un]")
[[ -n "$OUT" ]] && pass "username is non-empty string" || fail "username: got '$OUT'"

# =============================================================================
# Accessors: .count, .hash, .keys
# =============================================================================

# .count on FILE (should be 2: metadata DICT + DATA content)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0].count")
[[ "$OUT" == "2" ]] && pass "FILE .count is 2" || fail "FILE .count: got '$OUT'"

# .count on DICT (metadata keys)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0].count")
[[ "$OUT" =~ ^[0-9]+$ && "$OUT" -ge 5 ]] && pass "DICT .count >= 5" || fail "DICT .count: got '$OUT'"

# .hash on FILE (16-char hex string)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0].hash")
[[ "$OUT" =~ ^[0-9a-f]{16}$ ]] && pass "FILE .hash is 16-char hex" || fail "FILE .hash: got '$OUT'"

# .keys on DICT
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0].keys")
[[ "$OUT" == *"pa"* && "$OUT" == *"md"* && "$OUT" == *"mt"* ]] \
  && pass ".keys includes pa, md, mt" || fail ".keys: got '$OUT'"

# .keys --json on DICT
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0].keys" --json)
[[ "$OUT" =~ ^\[\".*\"\]$ ]] && pass ".keys --json is JSON array" || fail ".keys --json: got '$OUT'"
[[ "$OUT" == *'"pa"'* ]] && pass ".keys --json contains pa" || fail ".keys --json missing pa: got '$OUT'"

# =============================================================================
# Container summaries (default display for containers)
# =============================================================================

OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0]")
[[ "$OUT" == "FILE (2 elements)" ]] && pass "FILE summary" || fail "FILE summary: got '$OUT'"

OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0]")
[[ "$OUT" =~ ^DICT\ \([0-9]+\ pairs\)$ ]] && pass "DICT summary" || fail "DICT summary: got '$OUT'"

# =============================================================================
# JSON output mode
# =============================================================================

# JSON string value
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][pa]" --json)
[[ "$OUT" =~ ^\".*a\.txt\"$ ]] && pass "JSON string value" || fail "JSON string: got '$OUT'"

# JSON container
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0]" --json)
[[ "$OUT" == *'"type":"FILE"'* && "$OUT" == *'"count":2'* ]] \
  && pass "JSON container summary" || fail "JSON container: got '$OUT'"

# JSON type accessor
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0].type" --json)
[[ "$OUT" == '"FILE"' ]] && pass "JSON .type accessor" || fail "JSON .type: got '$OUT'"

# JSON hash
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0].hash" --json)
[[ "$OUT" =~ ^\"[0-9a-f]{16}\"$ ]] && pass "JSON .hash is quoted hex" || fail "JSON .hash: got '$OUT'"

# =============================================================================
# Error cases
# =============================================================================

# Out-of-bounds index
if "$BLAR" peek "$TMPDIR_TEST/test.blar" "[99]" 2>/dev/null; then
  fail "OOB index should fail"
else
  pass "OOB index returns error"
fi

# Malformed path
if "$BLAR" peek "$TMPDIR_TEST/test.blar" "[abc" 2>/dev/null; then
  fail "malformed path should fail"
else
  pass "malformed path returns error"
fi

# Missing archive
if "$BLAR" peek "$TMPDIR_TEST/nonexistent.blar" 2>/dev/null; then
  fail "missing archive should fail"
else
  pass "missing archive returns error"
fi

# =============================================================================
# miniblar peek cross-check
# =============================================================================

# miniblar peek should work identically
OUT=$("$MINIBLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][pa]")
[[ "$OUT" == *"a.txt"* ]] && pass "miniblar peek path" || fail "miniblar peek path: got '$OUT'"

OUT=$("$MINIBLAR" peek "$TMPDIR_TEST/test.blar" "[1][0].type")
[[ "$OUT" == "FILE" ]] && pass "miniblar peek .type" || fail "miniblar peek .type: got '$OUT'"

OUT=$("$MINIBLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][1]" --raw)
[[ "$OUT" == "hello" ]] && pass "miniblar peek --raw" || fail "miniblar peek --raw: got '$OUT'"

OUT=$("$MINIBLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0].keys" --json)
[[ "$OUT" == *'"pa"'* ]] && pass "miniblar peek .keys --json" || fail "miniblar peek .keys --json: got '$OUT'"

# miniblar tar-style kf
OUT=$("$MINIBLAR" kf "$TMPDIR_TEST/test.blar" "[1][0][0][pa]")
[[ "$OUT" == *"a.txt"* ]] && pass "miniblar kf shorthand" || fail "miniblar kf: got '$OUT'"

# =============================================================================
# --hex flag tests
# =============================================================================

# --hex on DATA content
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][1]" --hex)
[[ "$OUT" =~ ^0x[0-9a-f]+$ ]] && pass "--hex on DATA gives 0x-prefixed hex" || fail "--hex on DATA: got '$OUT'"

# --hex content matches known value: "hello" = 68656c6c6f
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][1]" --hex)
[[ "$OUT" == "0x68656c6c6f" ]] && pass "--hex hello = 0x68656c6c6f" || fail "--hex hello: got '$OUT'"

# --hex on FILE container (should give hash hex)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0]" --hex)
[[ "$OUT" =~ ^0x[0-9a-f]{16}$ ]] && pass "--hex on FILE gives container hash" || fail "--hex on FILE: got '$OUT'"

# --hex on RAW metadata value (mode)
OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][0][md]" --hex)
[[ "$OUT" =~ ^0x[0-9a-f]+$ ]] && pass "--hex on RAW (mode) gives hex" || fail "--hex on RAW (mode): got '$OUT'"

# =============================================================================
# Multi-file archive tests
# =============================================================================

# Create 3 test files
echo -n "alpha" > "$TMPDIR_TEST/file1.txt"
echo -n "bravo" > "$TMPDIR_TEST/file2.txt"
echo -n "charlie" > "$TMPDIR_TEST/file3.txt"
"$BLAR" create -o "$TMPDIR_TEST/multi.blar" \
  "$TMPDIR_TEST/file1.txt" "$TMPDIR_TEST/file2.txt" "$TMPDIR_TEST/file3.txt" 2>/dev/null

# Body array should have 3 entries
OUT=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1].count")
[[ "$OUT" == "3" ]] && pass "multi-file: body has 3 entries" || fail "multi-file body count: got '$OUT'"

# Each file should be a FILE container
OUT=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][0].type")
[[ "$OUT" == "FILE" ]] && pass "multi-file: [1][0] is FILE" || fail "multi-file [1][0].type: got '$OUT'"
OUT=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][1].type")
[[ "$OUT" == "FILE" ]] && pass "multi-file: [1][1] is FILE" || fail "multi-file [1][1].type: got '$OUT'"
OUT=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][2].type")
[[ "$OUT" == "FILE" ]] && pass "multi-file: [1][2] is FILE" || fail "multi-file [1][2].type: got '$OUT'"

# Peek at each file's content via --raw
OUT=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][0][1]" --raw)
[[ "$OUT" == "alpha" ]] && pass "multi-file: file1 content = alpha" || fail "multi-file file1: got '$OUT'"
OUT=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][1][1]" --raw)
[[ "$OUT" == "bravo" ]] && pass "multi-file: file2 content = bravo" || fail "multi-file file2: got '$OUT'"
OUT=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][2][1]" --raw)
[[ "$OUT" == "charlie" ]] && pass "multi-file: file3 content = charlie" || fail "multi-file file3: got '$OUT'"

# Each file should have distinct paths
OUT1=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][0][0][pa]")
OUT2=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][1][0][pa]")
OUT3=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][2][0][pa]")
[[ "$OUT1" != "$OUT2" && "$OUT2" != "$OUT3" ]] \
  && pass "multi-file: distinct paths" || fail "multi-file paths not distinct: $OUT1, $OUT2, $OUT3"

# =============================================================================
# Directory archive tests
# =============================================================================

# Create nested directory structure
mkdir -p "$TMPDIR_TEST/mydir/sub"
echo -n "top" > "$TMPDIR_TEST/mydir/top.txt"
echo -n "nested" > "$TMPDIR_TEST/mydir/sub/nested.txt"
"$BLAR" create -o "$TMPDIR_TEST/dir.blar" "$TMPDIR_TEST/mydir" 2>/dev/null

# Body should have entries (directory + files)
OUT=$("$BLAR" peek "$TMPDIR_TEST/dir.blar" "[1].count")
[[ "$OUT" -ge 1 ]] && pass "dir archive: body has entries" || fail "dir archive body count: got '$OUT'"

# There should be at least one DIR entry in the body
# Scan body entries looking for a DIR type
found_dir=false
body_count=$("$BLAR" peek "$TMPDIR_TEST/dir.blar" "[1].count")
for ((i=0; i<body_count; i++)); do
  t=$("$BLAR" peek "$TMPDIR_TEST/dir.blar" "[1][$i].type" 2>/dev/null || echo "ERR")
  if [[ "$t" == "DIR" ]]; then
    found_dir=true
    break
  fi
done
[[ "$found_dir" == "true" ]] && pass "dir archive: contains DIR entry" || fail "dir archive: no DIR entry found"

# Find a FILE entry and verify its content is accessible
found_file_content=false
for ((i=0; i<body_count; i++)); do
  t=$("$BLAR" peek "$TMPDIR_TEST/dir.blar" "[1][$i].type" 2>/dev/null || echo "ERR")
  if [[ "$t" == "FILE" ]]; then
    content=$("$BLAR" peek "$TMPDIR_TEST/dir.blar" "[1][$i][1]" --raw 2>/dev/null || echo "")
    if [[ "$content" == "top" || "$content" == "nested" ]]; then
      found_file_content=true
      break
    fi
  fi
done
[[ "$found_file_content" == "true" ]] && pass "dir archive: FILE content accessible" || fail "dir archive: no FILE content found"

# =============================================================================
# Hash verification against xxhsum
# =============================================================================

# Get hash from .hash accessor (hex)
PEEK_HASH=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0].hash")

# Get the same hash via --raw on DATA content + xxhsum
# DATA content for "hello" -> compute xxhash64
CONTENT_HASH=$(echo -n "hello" | xxhsum -H64 | awk '{print $1}')
# xxhsum outputs: <hash>  stdin
# The hash is a big-endian hex string, while peek .hash is LE bytes formatted as hex
# So we need to byte-reverse for comparison

# Helper: reverse hex byte order (e.g. "aabb0011" -> "1100bbaa")
reverse_hex() {
  local hex="$1"
  local reversed=""
  for ((i=${#hex}-2; i>=0; i-=2)); do
    reversed="${reversed}${hex:$i:2}"
  done
  echo "$reversed"
}

# Strip the leading 0x if present from xxhsum output
CONTENT_HASH="${CONTENT_HASH#0x}"
CONTENT_HASH_LE=$(reverse_hex "$CONTENT_HASH")

# But wait — .hash on FILE returns the container hash (over all FILE bytes), not the DATA hash.
# For DATA hash verification, we should peek at the DATA container directly.
DATA_HASH=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][1].hash")

# The DATA hash should match xxhash64 of its content bytes
# DATA hash is over the content (stored as LE bytes), xxhsum gives BE hex display
[[ "$DATA_HASH" == "$CONTENT_HASH_LE" ]] \
  && pass "DATA hash matches xxhsum of content" \
  || fail "DATA hash mismatch: peek='$DATA_HASH' xxhsum_le='$CONTENT_HASH_LE' xxhsum_be='$CONTENT_HASH'"

# =============================================================================
# --hex flag + content verification
# =============================================================================

# --hex on known content should produce the hex of the content bytes
HEX_OUT=$("$BLAR" peek "$TMPDIR_TEST/test.blar" "[1][0][1]" --hex)
# "hello" in hex = 68656c6c6f
[[ "$HEX_OUT" == "0x68656c6c6f" ]] && pass "--hex exact content match" || fail "--hex content: got '$HEX_OUT'"

# --hex on multi-file: each file's content hex should differ
HEX1=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][0][1]" --hex)
HEX2=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][1][1]" --hex)
HEX3=$("$BLAR" peek "$TMPDIR_TEST/multi.blar" "[1][2][1]" --hex)
[[ "$HEX1" != "$HEX2" && "$HEX2" != "$HEX3" ]] \
  && pass "--hex distinct for different files" || fail "--hex not distinct: $HEX1, $HEX2, $HEX3"

# =============================================================================
# Binary DATA with printable-binary identity check (JSON mode)
# =============================================================================

# Create a file with binary content
printf '\x00\x01\x02\xff' > "$TMPDIR_TEST/binary.dat"
"$BLAR" create -o "$TMPDIR_TEST/binary.blar" "$TMPDIR_TEST/binary.dat" 2>/dev/null

# --raw without tty should return raw bytes (4 bytes)
RAW_LEN=$("$BLAR" peek "$TMPDIR_TEST/binary.blar" "[1][0][1]" --raw 2>/dev/null | wc -c | tr -d ' ')
[[ "$RAW_LEN" == "4" ]] && pass "binary --raw returns 4 bytes" || fail "binary --raw len: got '$RAW_LEN'"

# --hex on binary content should be 00010002ff... wait, it's \x00\x01\x02\xff
HEX_BIN=$("$BLAR" peek "$TMPDIR_TEST/binary.blar" "[1][0][1]" --hex)
[[ "$HEX_BIN" == "0x000102ff" ]] && pass "binary --hex = 0x000102ff" || fail "binary --hex: got '$HEX_BIN'"

# =============================================================================
# Results
# =============================================================================

echo
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ "$FAIL" -eq 0 ]] || exit 1
