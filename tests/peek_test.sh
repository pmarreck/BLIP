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
# Results
# =============================================================================

echo
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ "$FAIL" -eq 0 ]] || exit 1
