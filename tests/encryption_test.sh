#!/usr/bin/env bash
# tests/encryption_test.sh — Encryption CLI tests for blar
#
# Tests: -e flag for create, auto-decrypt on list/extract/verify,
#        wrong password rejection, ChaCha20, PBKDF2, compressed+encrypted

set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# ── Build ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"

echo "Building blar..."
(cd "$PROJECT_DIR" && zig build 2>/dev/null) || { echo "FATAL: build failed"; exit 1; }

# ── Setup ────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create test files
mkdir -p "$TMPDIR_TEST/src"
echo "hello world" > "$TMPDIR_TEST/src/hello.txt"
echo "secret data" > "$TMPDIR_TEST/src/secret.txt"

# ── 1. Create encrypted archive (AES-256-GCM, default) ──────────────────

BLIP_PASSWORD=testpass "$BLAR" create -e -o "$TMPDIR_TEST/enc.blar" "$TMPDIR_TEST/src" 2>/dev/null \
    && pass "1. create encrypted archive" \
    || fail "1. create encrypted archive"

# ── 2. List without password should fail ─────────────────────────────────
# Unset BLIP_PASSWORD so there's no password available (and no tty prompt)
(unset BLIP_PASSWORD; "$BLAR" list "$TMPDIR_TEST/enc.blar" </dev/null 2>/dev/null) \
    && fail "2. list without password should fail" \
    || pass "2. list without password should fail"

# ── 3. List with correct password works ──────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" list "$TMPDIR_TEST/enc.blar" 2>/dev/null \
    && pass "3. list with password" \
    || fail "3. list with password"

# ── 4. Extract with correct password works ───────────────────────────────

mkdir -p "$TMPDIR_TEST/out"
BLIP_PASSWORD=testpass "$BLAR" extract "$TMPDIR_TEST/enc.blar" -C "$TMPDIR_TEST/out" 2>/dev/null \
    && pass "4. extract with password" \
    || fail "4. extract with password"

# ── 5. Extracted content matches original ────────────────────────────────

# The paths stored in the archive include the full path (normalized)
NORM_SRC="${TMPDIR_TEST#/}/src"
if [ -f "$TMPDIR_TEST/out/$NORM_SRC/hello.txt" ] && \
   diff "$TMPDIR_TEST/src/hello.txt" "$TMPDIR_TEST/out/$NORM_SRC/hello.txt" >/dev/null 2>&1; then
    pass "5. content matches"
else
    fail "5. content matches"
fi

# ── 6. Wrong password fails ──────────────────────────────────────────────

BLIP_PASSWORD=wrongpass "$BLAR" list "$TMPDIR_TEST/enc.blar" 2>/dev/null \
    && fail "6. wrong password should fail" \
    || pass "6. wrong password should fail"

# ── 7. Verify with password works ────────────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" verify "$TMPDIR_TEST/enc.blar" 2>/dev/null \
    && pass "7. verify with password" \
    || fail "7. verify with password"

# ── 8. Create with ChaCha20-Poly1305 ────────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" create -e chacha -o "$TMPDIR_TEST/chacha.blar" "$TMPDIR_TEST/src" 2>/dev/null \
    && pass "8. create chacha encrypted" \
    || fail "8. create chacha encrypted"

# ── 9. ChaCha decrypt works ──────────────────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" list "$TMPDIR_TEST/chacha.blar" 2>/dev/null \
    && pass "9. list chacha with password" \
    || fail "9. list chacha with password"

# ── 10. Create with PBKDF2 ──────────────────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" create -e aes --kdf pbkdf2 -o "$TMPDIR_TEST/pbkdf2.blar" "$TMPDIR_TEST/src" 2>/dev/null \
    && pass "10. create with PBKDF2" \
    || fail "10. create with PBKDF2"

# ── 11. PBKDF2 decrypt works ────────────────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" list "$TMPDIR_TEST/pbkdf2.blar" 2>/dev/null \
    && pass "11. list PBKDF2 with password" \
    || fail "11. list PBKDF2 with password"

# ── 12. Encrypted + compressed ───────────────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" create -z -e -o "$TMPDIR_TEST/comp_enc.blar" "$TMPDIR_TEST/src" 2>/dev/null \
    && pass "12. create compressed + encrypted" \
    || fail "12. create compressed + encrypted"

# ── 13. Compressed + encrypted round-trip ────────────────────────────────

BLIP_PASSWORD=testpass "$BLAR" list "$TMPDIR_TEST/comp_enc.blar" 2>/dev/null \
    && pass "13. list compressed + encrypted" \
    || fail "13. list compressed + encrypted"

# ── 14. --help shows encryption options ──────────────────────────────────

"$BLAR" --help 2>&1 | grep -q '\-e' \
    && pass "14. help shows -e flag" \
    || fail "14. help shows -e flag"

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
