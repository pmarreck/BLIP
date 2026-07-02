#!/usr/bin/env bash
# CLI tests for the `blip` LuaJIT tool (encode/decode byte-order transcoder).
# NOTE: no `set -e` — we test error paths that intentionally return non-zero.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLIP="${BLIP_BIN:-$HERE/../../bin/blip}"

pass_count=0
fail_count=0

# hex(bytes) helper: run a command, capture stdout as continuous lowercase hex.
# Usage: got=$(run_hex <cmd...> <<inputbytes)
# We compare against expected continuous hex strings.

# assert_hex "label" "expected_hex" -- with stdin already prepared by caller
# Caller pipes input; we run $BLIP with given args and hex-compare stdout.
_run_hex() { od -An -v -tx1 | tr -d ' \n'; }

assert() {
	local label="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass_count=$((pass_count+1))
		# echo "  ok: $label"
	else
		fail_count=$((fail_count+1))
		echo "  FAIL: $label"
		echo "        expected: [$expected]"
		echo "        actual:   [$actual]"
	fi
}

# ---- encode ---------------------------------------------------------------

# empty input -> header only
assert "encode empty (default BE)" "c0" "$(printf '' | "$BLIP" encode | _run_hex)"
assert "encode empty -l"          "80" "$(printf '' | "$BLIP" encode -l | _run_hex)"

# single byte < 0x80 -> immediate (bare byte), endianness irrelevant
assert "encode 0x41 (default)" "41" "$(printf '\x41' | "$BLIP" encode | _run_hex)"
assert "encode 0x41 -l"        "41" "$(printf '\x41' | "$BLIP" encode -l | _run_hex)"

# single byte >= 0x80 -> length-prefixed L=1
assert "encode 0xde (default BE)" "c1de" "$(printf '\xde' | "$BLIP" encode | _run_hex)"
assert "encode 0xde -l"           "81de" "$(printf '\xde' | "$BLIP" encode -l | _run_hex)"

# 4-byte blob: payload stored verbatim in BOTH modes (encoder never reverses)
assert "encode deadbeef (default BE)" "c4deadbeef" "$(printf '\xde\xad\xbe\xef' | "$BLIP" encode | _run_hex)"
assert "encode deadbeef -l"           "84deadbeef" "$(printf '\xde\xad\xbe\xef' | "$BLIP" encode -l | _run_hex)"

# later arg overrides earlier
assert "encode -l -b overrides to BE" "c4deadbeef" "$(printf '\xde\xad\xbe\xef' | "$BLIP" encode -l -b | _run_hex)"

# length-prefix boundary: 32 bytes -> continuation (low5=0, rem=1)
b32="$(printf '\xff%.0s' $(seq 1 32))"
assert "encode 32xff -l header+payload" "a001$(printf 'ff%.0s' $(seq 1 32))" "$(printf '%s' "$b32" | "$BLIP" encode -l | _run_hex)"
assert "encode 32xff -b header+payload" "e001$(printf 'ff%.0s' $(seq 1 32))" "$(printf '%s' "$b32" | "$BLIP" encode -b | _run_hex)"

# multi-byte continuation: 4096 bytes -> header a0 80 01 (LE)
assert "encode 4096 zeros -l header" "a08001" "$(head -c 4096 /dev/zero | "$BLIP" encode -l | head -c 3 | _run_hex)"

# ---- decode ---------------------------------------------------------------

assert "decode empty frame -> empty" "" "$(printf '\xc0' | "$BLIP" decode | _run_hex)"
assert "decode immediate 0x41"       "41" "$(printf '\x41' | "$BLIP" decode | _run_hex)"

# BE frame, default target BE -> verbatim
assert "decode BE frame default -> verbatim" "deadbeef" "$(printf '\xc4\xde\xad\xbe\xef' | "$BLIP" decode | _run_hex)"
# LE frame, default target BE -> reversed (normalized to big-endian)
assert "decode LE frame default -> reversed" "efbeadde" "$(printf '\x84\xde\xad\xbe\xef' | "$BLIP" decode | _run_hex)"
# LE frame, target LE -> verbatim
assert "decode LE frame -l -> verbatim" "deadbeef" "$(printf '\x84\xde\xad\xbe\xef' | "$BLIP" decode -l | _run_hex)"
# BE frame, target LE -> reversed
assert "decode BE frame -l -> reversed" "efbeadde" "$(printf '\xc4\xde\xad\xbe\xef' | "$BLIP" decode -l | _run_hex)"

# ---- roundtrip / idempotency ---------------------------------------------

assert "roundtrip BE identity" "deadbeef" "$(printf '\xde\xad\xbe\xef' | "$BLIP" encode | "$BLIP" decode | _run_hex)"
assert "roundtrip LE identity (request own order)" "efbeadde" "$(printf '\xef\xbe\xad\xde' | "$BLIP" encode -l | "$BLIP" decode -l | _run_hex)"
# fixpoint: LE data normalized to BE, stable under re-encode/re-decode
assert "fixpoint normalizes to BE" "deadbeef" "$(printf '\xef\xbe\xad\xde' | "$BLIP" encode -l | "$BLIP" decode | "$BLIP" encode | "$BLIP" decode | _run_hex)"

# ---- default subcommand (encode) -----------------------------------------

# piped data with no verb defaults to `encode`
assert "bare blip defaults to encode (BE)" "c4deadbeef" "$(printf '\xde\xad\xbe\xef' | "$BLIP" | _run_hex)"
assert "bare blip empty -> c0"             "c0"         "$(printf '' | "$BLIP" | _run_hex)"
# a leading flag with no verb also defaults to encode
assert "blip -l defaults to encode" "84deadbeef" "$(printf '\xde\xad\xbe\xef' | "$BLIP" -l | _run_hex)"
# roundtrip through the default encode
assert "bare blip | decode roundtrips" "6162636465" "$(printf 'abcde' | "$BLIP" | "$BLIP" decode | _run_hex)"
# an interactive stdin (no data) shows help instead of blocking on read
bh_rc=0; bh_out="$(BLIP_STDIN_TTY=1 "$BLIP" </dev/null 2>&1)" || bh_rc=$?
assert "bare blip interactive -> help exit 0" "0"   "$bh_rc"
assert "bare blip interactive -> shows usage" "yes" "$(grep -qi 'USAGE' <<<"$bh_out" && echo yes || echo no)"

# ---- error paths ----------------------------------------------------------

# TTY guard fires (simulated via BLIP_TTY=1); output suppressed, mentions printable-binary
tty_rc=0
tty_err="$(BLIP_TTY=1 "$BLIP" encode <<<"$(printf '\xde')" 2>&1 1>/dev/null)" || tty_rc=$?
assert "tty guard nonzero exit" "yes" "$([[ $tty_rc -ne 0 ]] && echo yes || echo no)"
assert "tty guard mentions printable-binary" "yes" "$(grep -q 'printable-binary' <<<"$tty_err" && echo yes || echo no)"

# -f bypasses TTY guard
force_rc=0
force_out="$(BLIP_TTY=1 printf '\xde' | BLIP_TTY=1 "$BLIP" encode -f | _run_hex)" || force_rc=$?
assert "tty guard bypassed with -f (exit 0)" "0" "$force_rc"
assert "tty guard bypassed with -f (output ok)" "c1de" "$force_out"

# decode truncated payload
trunc_rc=0
printf '\xc4\xde\xad' | "$BLIP" decode >/dev/null 2>&1 || trunc_rc=$?
assert "decode truncated -> nonzero" "yes" "$([[ $trunc_rc -ne 0 ]] && echo yes || echo no)"

# decode trailing data
trail_rc=0
printf '\xc1\xde\xff' | "$BLIP" decode >/dev/null 2>&1 || trail_rc=$?
assert "decode trailing -> nonzero" "yes" "$([[ $trail_rc -ne 0 ]] && echo yes || echo no)"

# decode sentinel (0x81 0x7E = NIL) -> error, not a data frame
sent_rc=0
sent_err="$(printf '\x81\x7e' | "$BLIP" decode 2>&1 1>/dev/null)" || sent_rc=$?
assert "decode sentinel -> nonzero" "yes" "$([[ $sent_rc -ne 0 ]] && echo yes || echo no)"
assert "decode sentinel mentions sentinel" "yes" "$(grep -qi 'sentinel' <<<"$sent_err" && echo yes || echo no)"

# unknown subcommand / arg
uk_rc=0; "$BLIP" frobnicate </dev/null >/dev/null 2>&1 || uk_rc=$?
assert "unknown subcommand -> nonzero" "yes" "$([[ $uk_rc -ne 0 ]] && echo yes || echo no)"
ua_rc=0; printf '' | "$BLIP" encode --bogus >/dev/null 2>&1 || ua_rc=$?
assert "unknown arg -> nonzero" "yes" "$([[ $ua_rc -ne 0 ]] && echo yes || echo no)"

# help / about
h_rc=0; "$BLIP" --help >/dev/null 2>&1 || h_rc=$?
assert "--help exit 0" "0" "$h_rc"
about_line="$("$BLIP" --about 2>/dev/null)"
assert "--about is one line" "1" "$(printf '%s\n' "$about_line" | wc -l | tr -d ' ')"
assert "--about mentions blip" "yes" "$(grep -qi 'blip' <<<"$about_line" && echo yes || echo no)"

# ---- summary --------------------------------------------------------------
echo ""
echo "blip CLI: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
