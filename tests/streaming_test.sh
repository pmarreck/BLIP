#!/usr/bin/env bash
set -u

# =============================================================================
# Streaming archive creation integration tests
# =============================================================================
# Verifies that the streaming path produces byte-identical archives to the
# in-memory path, and that both verify and extract correctly.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"

echo "Building blar..."
(cd "$PROJECT_DIR" && nix develop -c zig build -Doptimize=ReleaseFast) \
  || { echo "FATAL: build failed"; exit 1; }

if [[ ! -x "$BLAR" ]]; then
  echo "FATAL: blar binary not found at $BLAR"
  exit 1
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# =============================================================================
# Test 1: Streaming byte-identity for simple files
# =============================================================================
echo "--- Test 1: Simple file streaming byte-identity ---"

mkdir -p "$TMPDIR_TEST/t1/input"
echo "Hello, world!" > "$TMPDIR_TEST/t1/input/hello.txt"
echo "Second file content" > "$TMPDIR_TEST/t1/input/second.txt"
dd if=/dev/urandom bs=1024 count=10 of="$TMPDIR_TEST/t1/input/random.bin" 2>/dev/null

# In-memory path (default)
(cd "$TMPDIR_TEST/t1" && "$BLAR" create -z -f -o inmem.blar input 2>/dev/null)
# Streaming path
(cd "$TMPDIR_TEST/t1" && "$BLAR" create -z -f --streaming -o stream.blar input 2>/dev/null)

if [[ -f "$TMPDIR_TEST/t1/inmem.blar" && -f "$TMPDIR_TEST/t1/stream.blar" ]]; then
  INMEM_MD5=$(md5 < "$TMPDIR_TEST/t1/inmem.blar")
  STREAM_MD5=$(md5 < "$TMPDIR_TEST/t1/stream.blar")
  if [[ "$INMEM_MD5" == "$STREAM_MD5" ]]; then
    pass "streaming byte-identical to in-memory"
  else
    fail "streaming differs from in-memory (inmem=$INMEM_MD5 stream=$STREAM_MD5)"
  fi
else
  fail "archive(s) not created"
fi

# Verify streaming archive is valid
"$BLAR" verify "$TMPDIR_TEST/t1/stream.blar" 2>/dev/null
if [[ $? -eq 0 ]]; then
  pass "streaming archive passes verify"
else
  fail "streaming archive fails verify"
fi

# Extract and checksum roundtrip
mkdir -p "$TMPDIR_TEST/t1/ext"
"$BLAR" extract "$TMPDIR_TEST/t1/stream.blar" -f -C "$TMPDIR_TEST/t1/ext" 2>/dev/null
ORIG_MD5=$(md5 < "$TMPDIR_TEST/t1/input/hello.txt")
EXT_MD5=$(md5 < "$TMPDIR_TEST/t1/ext/input/hello.txt" 2>/dev/null)
if [[ "$ORIG_MD5" == "$EXT_MD5" ]]; then
  pass "streaming roundtrip preserves content"
else
  fail "streaming roundtrip content differs"
fi

# =============================================================================
# Results
# =============================================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
