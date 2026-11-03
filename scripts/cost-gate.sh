#!/usr/bin/env bash
#
# cost-gate.sh: enforce the monthly cost threshold on an `infracost diff` result.
#
# Fails closed. An estimate that is missing, unreadable, not a number, or that
# Infracost marked with project errors is a failure, never a $0 change. A cost
# gate that passes when it could not measure is not a gate.
#
# Usage:
#   infracost diff ... --format json --out-file diff.json
#   APPROVED=true|false scripts/cost-gate.sh diff.json <max-monthly-increase>
#
# APPROVED=true (the PR carries the cost-approved label) lets an over-threshold
# change pass. It never makes a missing estimate pass.
#
# Exit codes: 0 pass, 1 gate failed, 2 usage error.

set -euo pipefail

DIFF="${1:-}"
LIMIT="${2:-}"
if [[ -z "$DIFF" || -z "$LIMIT" ]]; then
	echo "usage: cost-gate.sh <infracost-diff.json> <max-monthly-increase>" >&2
	exit 2
fi
if ! [[ "$LIMIT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
	echo "cost-gate: limit must be a non-negative number, got '$LIMIT'" >&2
	exit 2
fi

fail() {
	echo "::error::$1"
	exit 1
}

[[ -r "$DIFF" ]] || fail "No Infracost estimate at $DIFF. The cost gate cannot pass without one."
jq -e . "$DIFF" >/dev/null 2>&1 || fail "The Infracost estimate at $DIFF is not valid JSON."

errors="$(jq -r '[.projects[]?.metadata.errors[]?.message // empty] | join("; ")' "$DIFF")"
[[ -z "$errors" ]] || fail "Infracost could not price every project: $errors"

delta="$(jq -r '.diffTotalMonthlyCost // empty' "$DIFF")"
[[ -n "$delta" ]] || fail "The Infracost estimate has no diffTotalMonthlyCost. Refusing to treat it as \$0."
[[ "$delta" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || fail "diffTotalMonthlyCost is not a number: '$delta'."

printf 'Projected monthly change: $%s (limit: $%s)\n' "$delta" "$LIMIT"
if awk -v d="$delta" -v l="$LIMIT" 'BEGIN { exit !(d > l) }'; then
	if [[ "${APPROVED:-false}" == "true" ]]; then
		echo "::notice::Over the \$$LIMIT/mo gate, but the 'cost-approved' label is present. Passing."
		exit 0
	fi
	fail "This change adds \$$delta/mo, above the \$$LIMIT/mo gate. Justify it and add the 'cost-approved' label to override."
fi
echo "Within the \$$LIMIT/mo gate."
