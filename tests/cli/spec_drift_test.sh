#!/usr/bin/env bash
# MFIC drift control: the wire spec's "Container Type IDs" table MUST match the
# ContainerTypeId enum in code. The spec is the source of truth during development
# (see memory: spec-is-source-of-truth); this fails loud if code and spec diverge —
# exactly the RAW(4)/DATA(8)-vs-data=4 drift that started this whole thread.
#
# NOTE: no `set -e` — assertions are explicit and accumulate into $fail.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
enum_file="$ROOT/src/container_types.zig"
spec_file="$ROOT/BLIP_WIRE_SPEC.md"

fail=0

# (id NAME) from the ContainerTypeId enum body. `[a-z0-9_]+` includes the digit in
# names like utf8 — omitting it silently dropped UTF8 while prototyping this check.
enum=$(awk -F'[ =,]+' '
  /ContainerTypeId = enum/ {f=1; next}
  f && /^};/ {exit}
  f && /^[ \t]+[a-z0-9_]+ = [0-9]+,/ { print $3, toupper($2) }
' "$enum_file" | sort)

# (id NAME) from the spec table rows "| N | NAME | ... |", scoped to the
# "### Container Type IDs" section so the COMP/CSUM/ENC id tables aren't picked up.
spec=$(awk -F'|' '
  /^### Container Type IDs/ {f=1; next}
  f && /^#/ {exit}
  f && $2 ~ /^ *[0-9]+ *$/ { gsub(/ /,"",$2); gsub(/ /,"",$3); print $2, $3 }
' "$spec_file" | sort)

# Guard against a vacuous pass: if a parser breaks and returns nothing, an empty==empty
# diff would falsely pass. There are 8 container types; require a sane floor.
n_enum=$(printf '%s\n' "$enum" | grep -c .)
n_spec=$(printf '%s\n' "$spec" | grep -c .)
if [[ "$n_enum" -lt 5 || "$n_spec" -lt 5 ]]; then
	echo "FAIL: type-id extraction returned too few rows (enum=$n_enum, spec=$n_spec) — a parser is broken."
	fail=1
fi

if ! diff <(printf '%s\n' "$enum") <(printf '%s\n' "$spec") >/dev/null 2>&1; then
	echo "FAIL: spec <-> code drift in container type IDs (< = enum, > = BLIP_WIRE_SPEC.md):"
	diff <(printf '%s\n' "$enum") <(printf '%s\n' "$spec") | sed 's/^/    /'
	echo "  The spec is the source of truth during development — reconcile code to it (or deliberately revise the spec)."
	fail=1
fi

if [[ "$fail" -eq 0 ]]; then
	echo "spec drift control: ContainerTypeId enum == BLIP_WIRE_SPEC.md type table ($n_enum types) OK"
fi
exit $fail
