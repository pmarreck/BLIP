#!/usr/bin/env bash
# tests/compression_test.sh — Unified compression CLI tests for all algorithms
#
# Tests -z flag for create with lzma2/bzip2/lz4, transparent decompression
# for list/extract/verify/info/cat/peek/to-json/from-json, plus backward
# compatibility (default algo, aliases).

set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# ── Build ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"
MINIBLAR="$PROJECT_DIR/zig-out/bin/miniblar"

echo "Building blar and miniblar..."
(cd "$PROJECT_DIR" && zig build 2>/dev/null) || { echo "FATAL: build failed"; exit 1; }

# ── Setup ────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

echo "hello world" > "$TMPDIR_TEST/hello.txt"
echo "goodbye world" > "$TMPDIR_TEST/goodbye.txt"
dd if=/dev/urandom bs=1024 count=10 of="$TMPDIR_TEST/random.bin" 2>/dev/null

# Normalized paths (leading / stripped)
NORM_HELLO="${TMPDIR_TEST#/}/hello.txt"
NORM_GOODBYE="${TMPDIR_TEST#/}/goodbye.txt"
NORM_RANDOM="${TMPDIR_TEST#/}/random.bin"

# Algo → COMP byte mapping
declare -A COMP_BYTE=( [lzma2]="01" [bzip2]="02" [lz4]="03" [zstd]="04" )

# ══════════════════════════════════════════════════════════════════════════
# Per-algorithm tests (parameterized)
# ══════════════════════════════════════════════════════════════════════════

for ALGO in lzma2 bzip2 lz4 zstd; do
  COMP=${COMP_BYTE[$ALGO]}
  Z_FLAG="-z $ALGO"
  # lzma2 is the default for bare -z, but we test explicitly here
  PREFIX="[$ALGO]"

  echo ""
  echo "── Testing $ALGO ──"

  # --- blar create -z $ALGO (default: per-file compression) ---

  "$BLAR" create $Z_FLAG -o "$TMPDIR_TEST/${ALGO}_comp.blar" \
    "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
  [ -f "$TMPDIR_TEST/${ALGO}_comp.blar" ] \
    && pass "$PREFIX blar create (per-file) produces output" \
    || fail "$PREFIX blar create (per-file) produces output"

  # Per-file: outer LP header should NOT have COMP attribute
  HEADER_HEX=$(xxd -l 15 -p "$TMPDIR_TEST/${ALGO}_comp.blar" | tr -d '\n')
  echo "$HEADER_HEX" | grep -qv "8110${COMP}" \
    && pass "$PREFIX per-file: no COMP in outer LP header" \
    || fail "$PREFIX per-file: unexpected COMP in outer header (got $HEADER_HEX)"

  # --- blar create --solid -z $ALGO ---

  "$BLAR" create --solid $Z_FLAG -o "$TMPDIR_TEST/${ALGO}_solid.blar" \
    "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
  [ -f "$TMPDIR_TEST/${ALGO}_solid.blar" ] \
    && pass "$PREFIX blar create (solid) produces output" \
    || fail "$PREFIX blar create (solid) produces output"

  # Solid: outer LP header SHOULD have COMP attribute
  SOLID_HEADER=$(xxd -l 15 -p "$TMPDIR_TEST/${ALGO}_solid.blar" | tr -d '\n')
  echo "$SOLID_HEADER" | grep -q "8110${COMP}" \
    && pass "$PREFIX solid: COMP=0x${COMP} in LP header" \
    || fail "$PREFIX solid: COMP=0x${COMP} not found (got $SOLID_HEADER)"

  # --- Transparent decompression: list, extract, verify, info, cat, peek, to-json ---

  LIST_OUT=$("$BLAR" list "$TMPDIR_TEST/${ALGO}_comp.blar" 2>/dev/null)
  echo "$LIST_OUT" | grep -q 'hello.txt' \
    && pass "$PREFIX blar list works" \
    || fail "$PREFIX blar list — output: $LIST_OUT"

  echo "$LIST_OUT" | grep -q 'goodbye.txt' \
    && pass "$PREFIX list shows all files" \
    || fail "$PREFIX list shows all files — output: $LIST_OUT"

  EXTRACT_DIR="$TMPDIR_TEST/${ALGO}_extract"
  mkdir -p "$EXTRACT_DIR"
  "$BLAR" extract "$TMPDIR_TEST/${ALGO}_comp.blar" -C "$EXTRACT_DIR" 2>/dev/null

  [ -f "$EXTRACT_DIR/$NORM_HELLO" ] && [ "$(cat "$EXTRACT_DIR/$NORM_HELLO")" = "hello world" ] \
    && pass "$PREFIX extract hello.txt correct" \
    || fail "$PREFIX extract hello.txt correct"

  [ -f "$EXTRACT_DIR/$NORM_GOODBYE" ] && [ "$(cat "$EXTRACT_DIR/$NORM_GOODBYE")" = "goodbye world" ] \
    && pass "$PREFIX extract goodbye.txt correct" \
    || fail "$PREFIX extract goodbye.txt correct"

  VERIFY_OUT=$("$BLAR" verify "$TMPDIR_TEST/${ALGO}_comp.blar" 2>&1)
  echo "$VERIFY_OUT" | grep -q 'OK' \
    && pass "$PREFIX verify passes" \
    || fail "$PREFIX verify — output: $VERIFY_OUT"

  INFO_OUT=$("$BLAR" info "$TMPDIR_TEST/${ALGO}_comp.blar" 2>/dev/null)
  echo "$INFO_OUT" | grep -q 'hello.txt' \
    && pass "$PREFIX info shows files" \
    || fail "$PREFIX info — output: $INFO_OUT"

  CAT_OUT=$("$BLAR" cat "$TMPDIR_TEST/${ALGO}_comp.blar" "$NORM_HELLO" 2>/dev/null)
  [ "$CAT_OUT" = "hello world" ] \
    && pass "$PREFIX cat correct content" \
    || fail "$PREFIX cat (got: '$CAT_OUT')"

  PEEK_OUT=$("$BLAR" peek "$TMPDIR_TEST/${ALGO}_comp.blar" "[1][0][0][pa]" 2>&1)
  echo "$PEEK_OUT" | grep -q 'hello.txt' \
    && pass "$PREFIX peek works" \
    || fail "$PREFIX peek — output: $PEEK_OUT"

  JSON_OUT=$("$BLAR" to-json "$TMPDIR_TEST/${ALGO}_comp.blar" 2>/dev/null)
  ENTRY_COUNT=$(echo "$JSON_OUT" | jq '.entries | length')
  [ "$ENTRY_COUNT" -ge 2 ] \
    && pass "$PREFIX to-json valid ($ENTRY_COUNT entries)" \
    || fail "$PREFIX to-json entry count: $ENTRY_COUNT"

  # --- Solid archive: transparent decompression ---

  SOLID_LIST=$("$BLAR" list "$TMPDIR_TEST/${ALGO}_solid.blar" 2>/dev/null)
  echo "$SOLID_LIST" | grep -q 'hello.txt' \
    && pass "$PREFIX solid list works" \
    || fail "$PREFIX solid list — output: $SOLID_LIST"

  SOLID_EXTRACT="$TMPDIR_TEST/${ALGO}_solid_ext"
  mkdir -p "$SOLID_EXTRACT"
  "$BLAR" extract "$TMPDIR_TEST/${ALGO}_solid.blar" -C "$SOLID_EXTRACT" 2>/dev/null
  [ -f "$SOLID_EXTRACT/$NORM_HELLO" ] && [ "$(cat "$SOLID_EXTRACT/$NORM_HELLO")" = "hello world" ] \
    && pass "$PREFIX solid extract correct" \
    || fail "$PREFIX solid extract correct"

  SOLID_VERIFY=$("$BLAR" verify "$TMPDIR_TEST/${ALGO}_solid.blar" 2>&1)
  echo "$SOLID_VERIFY" | grep -q 'OK' \
    && pass "$PREFIX solid verify passes" \
    || fail "$PREFIX solid verify — output: $SOLID_VERIFY"

  # --- miniblar ---

  "$MINIBLAR" create $Z_FLAG -o "$TMPDIR_TEST/${ALGO}_mini.mblar" \
    "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
  [ -f "$TMPDIR_TEST/${ALGO}_mini.mblar" ] \
    && pass "$PREFIX miniblar create produces output" \
    || fail "$PREFIX miniblar create produces output"

  MINI_LIST=$("$MINIBLAR" list "$TMPDIR_TEST/${ALGO}_mini.mblar" 2>/dev/null)
  echo "$MINI_LIST" | grep -q 'hello.txt' \
    && pass "$PREFIX miniblar list works" \
    || fail "$PREFIX miniblar list — output: $MINI_LIST"

  MINI_EXTRACT="$TMPDIR_TEST/${ALGO}_mini_ext"
  mkdir -p "$MINI_EXTRACT"
  "$MINIBLAR" extract "$TMPDIR_TEST/${ALGO}_mini.mblar" -C "$MINI_EXTRACT" 2>/dev/null
  [ -f "$MINI_EXTRACT/$NORM_HELLO" ] && [ "$(cat "$MINI_EXTRACT/$NORM_HELLO")" = "hello world" ] \
    && pass "$PREFIX miniblar extract correct" \
    || fail "$PREFIX miniblar extract correct"

  MINI_VERIFY=$("$MINIBLAR" verify "$TMPDIR_TEST/${ALGO}_mini.mblar" 2>&1)
  echo "$MINI_VERIFY" | grep -q 'OK' \
    && pass "$PREFIX miniblar verify passes" \
    || fail "$PREFIX miniblar verify — output: $MINI_VERIFY"

  MINI_CAT=$("$MINIBLAR" cat "$TMPDIR_TEST/${ALGO}_mini.mblar" "$NORM_HELLO" 2>/dev/null)
  [ "$MINI_CAT" = "hello world" ] \
    && pass "$PREFIX miniblar cat correct" \
    || fail "$PREFIX miniblar cat (got: '$MINI_CAT')"

  # --- miniblar --solid ---

  "$MINIBLAR" create --solid $Z_FLAG -o "$TMPDIR_TEST/${ALGO}_mini_solid.mblar" \
    "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
  MINI_SOLID_HEADER=$(xxd -l 15 -p "$TMPDIR_TEST/${ALGO}_mini_solid.mblar" | tr -d '\n')
  echo "$MINI_SOLID_HEADER" | grep -q "8110${COMP}" \
    && pass "$PREFIX miniblar solid: COMP in header" \
    || fail "$PREFIX miniblar solid: COMP not found (got $MINI_SOLID_HEADER)"

  MINI_SOLID_LIST=$("$MINIBLAR" list "$TMPDIR_TEST/${ALGO}_mini_solid.mblar" 2>/dev/null)
  echo "$MINI_SOLID_LIST" | grep -q 'hello.txt' \
    && pass "$PREFIX miniblar solid list works" \
    || fail "$PREFIX miniblar solid list — output: $MINI_SOLID_LIST"

  # --- Binary round-trip ---

  "$BLAR" create $Z_FLAG -o "$TMPDIR_TEST/${ALGO}_binary.blar" "$TMPDIR_TEST/random.bin" 2>/dev/null
  BIN_EXT="$TMPDIR_TEST/${ALGO}_bin_ext"
  mkdir -p "$BIN_EXT"
  "$BLAR" extract "$TMPDIR_TEST/${ALGO}_binary.blar" -C "$BIN_EXT" 2>/dev/null
  cmp -s "$TMPDIR_TEST/random.bin" "$BIN_EXT/$NORM_RANDOM" \
    && pass "$PREFIX binary round-trip" \
    || fail "$PREFIX binary round-trip"

  # --- Directory archive ---

  mkdir -p "$TMPDIR_TEST/${ALGO}_dir/subdir"
  echo "nested" > "$TMPDIR_TEST/${ALGO}_dir/subdir/file.txt"
  echo "top" > "$TMPDIR_TEST/${ALGO}_dir/top.txt"
  "$BLAR" create $Z_FLAG -o "$TMPDIR_TEST/${ALGO}_dircomp.blar" "$TMPDIR_TEST/${ALGO}_dir" 2>/dev/null

  DIR_LIST=$("$BLAR" list "$TMPDIR_TEST/${ALGO}_dircomp.blar" 2>/dev/null)
  echo "$DIR_LIST" | grep -q 'file.txt' \
    && pass "$PREFIX dir archive list works" \
    || fail "$PREFIX dir archive list — output: $DIR_LIST"

  DIR_EXT="$TMPDIR_TEST/${ALGO}_dir_ext"
  mkdir -p "$DIR_EXT"
  "$BLAR" extract "$TMPDIR_TEST/${ALGO}_dircomp.blar" -C "$DIR_EXT" 2>/dev/null
  NORM_NESTED="${TMPDIR_TEST#/}/${ALGO}_dir/subdir/file.txt"
  [ -f "$DIR_EXT/$NORM_NESTED" ] && [ "$(cat "$DIR_EXT/$NORM_NESTED")" = "nested" ] \
    && pass "$PREFIX dir extract nested content correct" \
    || fail "$PREFIX dir extract nested content"

  # --- from-json -z $ALGO ---

  "$BLAR" to-json "$TMPDIR_TEST/${ALGO}_comp.blar" > "$TMPDIR_TEST/${ALGO}.json" 2>/dev/null
  "$BLAR" from-json $Z_FLAG -o "$TMPDIR_TEST/${ALGO}_fj.blar" "$TMPDIR_TEST/${ALGO}.json" 2>/dev/null
  FJ_HEADER=$(xxd -l 15 -p "$TMPDIR_TEST/${ALGO}_fj.blar" | tr -d '\n')
  echo "$FJ_HEADER" | grep -q "8110${COMP}" \
    && pass "$PREFIX from-json creates $ALGO archive" \
    || fail "$PREFIX from-json COMP — got $FJ_HEADER"

  FJ_LIST=$("$BLAR" list "$TMPDIR_TEST/${ALGO}_fj.blar" 2>/dev/null)
  echo "$FJ_LIST" | grep -q 'hello.txt' \
    && pass "$PREFIX from-json round-trip list works" \
    || fail "$PREFIX from-json round-trip — output: $FJ_LIST"

done

# ══════════════════════════════════════════════════════════════════════════
# Non-parameterized tests (backward compat, aliases, help, uncompressed)
# ══════════════════════════════════════════════════════════════════════════

echo ""
echo "── Non-parameterized tests ──"

# -z alone defaults to lzma2 (per-file mode — verify via --solid)
"$BLAR" create --solid -z -o "$TMPDIR_TEST/default_z_solid.blar" "$TMPDIR_TEST/hello.txt" 2>/dev/null
DEFAULT_HEADER=$(xxd -l 15 -p "$TMPDIR_TEST/default_z_solid.blar" | tr -d '\n')
echo "$DEFAULT_HEADER" | grep -q "811001" \
  && pass "-z alone defaults to lzma2 (--solid COMP=0x01)" \
  || fail "-z alone defaults to lzma2 — got $DEFAULT_HEADER"

# -z per-file: content still extractable
"$BLAR" create -z -o "$TMPDIR_TEST/default_z_pf.blar" "$TMPDIR_TEST/hello.txt" 2>/dev/null
DZ_PF_LIST=$("$BLAR" list "$TMPDIR_TEST/default_z_pf.blar" 2>/dev/null)
echo "$DZ_PF_LIST" | grep -q "hello.txt" \
  && pass "-z per-file: list works" \
  || fail "-z per-file: list — output: $DZ_PF_LIST"

# -z lzma alias works (verify via --solid)
"$BLAR" create --solid -z lzma -o "$TMPDIR_TEST/lzma_alias.blar" "$TMPDIR_TEST/hello.txt" 2>/dev/null
LZMA_HEADER=$(xxd -l 15 -p "$TMPDIR_TEST/lzma_alias.blar" | tr -d '\n')
echo "$LZMA_HEADER" | grep -q "811001" \
  && pass "-z lzma alias works (--solid COMP=0x01)" \
  || fail "-z lzma alias — got $LZMA_HEADER"

# -z bz2 alias works (verify via --solid)
"$BLAR" create --solid -z bz2 -o "$TMPDIR_TEST/bz2_alias.blar" "$TMPDIR_TEST/hello.txt" 2>/dev/null
BZ2_HEADER=$(xxd -l 15 -p "$TMPDIR_TEST/bz2_alias.blar" | tr -d '\n')
echo "$BZ2_HEADER" | grep -q "811002" \
  && pass "-z bz2 alias works (--solid COMP=0x02)" \
  || fail "-z bz2 alias — got $BZ2_HEADER"

# Solid compressed is smaller than uncompressed (text files with lzma2)
"$BLAR" create -o "$TMPDIR_TEST/uncompressed.blar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
# Use solid lzma2 for fair size comparison
"$BLAR" create --solid -z -o "$TMPDIR_TEST/comp_both.blar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
COMP_BOTH=$(wc -c < "$TMPDIR_TEST/comp_both.blar" | tr -d ' ')
UNCOMP_SIZE=$(wc -c < "$TMPDIR_TEST/uncompressed.blar" | tr -d ' ')
[ "$COMP_BOTH" -lt "$UNCOMP_SIZE" ] \
  && pass "solid lzma2 compressed smaller than uncompressed ($COMP_BOTH < $UNCOMP_SIZE)" \
  || fail "solid lzma2 compressed not smaller ($COMP_BOTH >= $UNCOMP_SIZE)"

# Uncompressed archives still work
UNCOMP_LIST=$("$BLAR" list "$TMPDIR_TEST/uncompressed.blar" 2>/dev/null)
echo "$UNCOMP_LIST" | grep -q 'hello.txt' \
  && pass "uncompressed archive still works" \
  || fail "uncompressed archive still works"

# Help text
BLAR_HELP=$("$BLAR" --help 2>&1)
echo "$BLAR_HELP" | grep -q '\-z' \
  && pass "blar --help mentions -z" \
  || fail "blar --help mentions -z"
echo "$BLAR_HELP" | grep -q '\-\-solid' \
  && pass "blar --help mentions --solid" \
  || fail "blar --help mentions --solid"
for ALGO in bzip2 lz4; do
  echo "$BLAR_HELP" | grep -q "$ALGO" \
    && pass "blar --help mentions $ALGO" \
    || fail "blar --help mentions $ALGO"
done

MINI_HELP=$("$MINIBLAR" --help 2>&1)
echo "$MINI_HELP" | grep -q '\-z' \
  && pass "miniblar --help mentions -z" \
  || fail "miniblar --help mentions -z"
echo "$MINI_HELP" | grep -q '\-\-solid' \
  && pass "miniblar --help mentions --solid" \
  || fail "miniblar --help mentions --solid"

# ── Large payload compression ────────────────────────────────────────────

echo ""
echo "=== Large payload compression ==="

LARGE_FILE="$TMPDIR_TEST/large.bin"
dd if=/dev/urandom bs=1048576 count=50 of="$LARGE_FILE" 2>/dev/null

for ALGO in lz4 lzma2 bzip2; do
  LARGE_ARCHIVE="$TMPDIR_TEST/large_${ALGO}.blar"
  if "$BLAR" create -z "$ALGO" -o "$LARGE_ARCHIVE" "$LARGE_FILE" 2>/dev/null; then
    pass "large payload ($ALGO): create succeeds"
    if "$BLAR" list "$LARGE_ARCHIVE" 2>/dev/null | grep -q "large.bin"; then
      pass "large payload ($ALGO): list shows file"
    else
      fail "large payload ($ALGO): list shows file"
    fi
    LARGE_EXTRACT="$TMPDIR_TEST/large_extract_${ALGO}"
    mkdir -p "$LARGE_EXTRACT"
    if "$BLAR" extract "$LARGE_ARCHIVE" -C "$LARGE_EXTRACT" 2>/dev/null; then
      EXTRACTED_FILE=$(find "$LARGE_EXTRACT" -name "large.bin" -type f)
      if [ -n "$EXTRACTED_FILE" ] && cmp -s "$LARGE_FILE" "$EXTRACTED_FILE"; then
        pass "large payload ($ALGO): round-trip matches"
      else
        fail "large payload ($ALGO): round-trip matches"
      fi
    else
      fail "large payload ($ALGO): extract succeeds"
    fi
    rm -f "$LARGE_ARCHIVE"
    rm -rf "$LARGE_EXTRACT"
  else
    fail "large payload ($ALGO): create succeeds (exit code $?)"
  fi
done

rm -f "$LARGE_FILE"

# ── Results ──────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
