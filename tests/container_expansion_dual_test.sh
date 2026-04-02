#!/usr/bin/env bash
set -u

# =============================================================================
# Dual-mode container expansion tests
# =============================================================================
# Runs the full container expansion test suite TWICE:
#   1. Normal mode (in-memory path)
#   2. Forced streaming mode (BLAR_STREAMING_THRESHOLD=0)
#
# This ensures both code paths produce correct results for all 46+ tests.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Container Expansion — Dual Mode Tests              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# --- Pass 1: Normal (in-memory) ---
echo ""
echo "━━━ Pass 1: In-memory mode ━━━"
unset BLAR_STREAMING_THRESHOLD
OUTPUT=$(bash "$SCRIPT_DIR/container_expansion_test.sh" 2>&1)
echo "$OUTPUT" | tail -5
PASS1=$(echo "$OUTPUT" | grep "^Results:" | sed 's/Results: \([0-9]*\) passed.*/\1/')
FAIL1=$(echo "$OUTPUT" | grep "^Results:" | sed 's/.*, \([0-9]*\) failed/\1/')
TOTAL_PASS=$((TOTAL_PASS + PASS1))
TOTAL_FAIL=$((TOTAL_FAIL + FAIL1))

# --- Pass 2: Forced streaming ---
echo ""
echo "━━━ Pass 2: Streaming mode (BLAR_STREAMING_THRESHOLD=0) ━━━"
export BLAR_STREAMING_THRESHOLD=0
OUTPUT=$(bash "$SCRIPT_DIR/container_expansion_test.sh" 2>&1)
echo "$OUTPUT" | tail -5
PASS2=$(echo "$OUTPUT" | grep "^Results:" | sed 's/Results: \([0-9]*\) passed.*/\1/')
FAIL2=$(echo "$OUTPUT" | grep "^Results:" | sed 's/.*, \([0-9]*\) failed/\1/')
TOTAL_PASS=$((TOTAL_PASS + PASS2))
TOTAL_FAIL=$((TOTAL_FAIL + FAIL2))
unset BLAR_STREAMING_THRESHOLD

# --- Summary ---
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  In-memory:  $PASS1 passed, $FAIL1 failed"
echo "║  Streaming:  $PASS2 passed, $FAIL2 failed"
echo "║  TOTAL:      $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "╚══════════════════════════════════════════════════════════════╝"

[[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
