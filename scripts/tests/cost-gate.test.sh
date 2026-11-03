#!/usr/bin/env bash
# Self-test for cost-gate.sh. The gate must fail closed: a missing or unpriced
# estimate fails even when the cost-approved label is present.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fx="$root/examples/costs"
failures=0

# expect NAME WANT_EXIT APPROVED FILE [LIMIT]
expect() {
	local name="$1" want="$2" approved="$3" file="$4" limit="${5:-50}" got=0
	APPROVED="$approved" "$root/scripts/cost-gate.sh" "$file" "$limit" >/dev/null 2>&1 || got=$?
	if [[ "$got" -ne "$want" ]]; then
		echo "FAIL: $name (exit $got, expected $want)"
		failures=$((failures + 1))
	fi
}

expect "under the limit passes" 0 false "$fx/under.json"
expect "a cost decrease passes" 0 false "$fx/decrease.json"
expect "over the limit fails" 1 false "$fx/over.json"
expect "over the limit with cost-approved passes" 0 true "$fx/over.json"
expect "a missing diffTotalMonthlyCost fails" 1 false "$fx/missing-total.json"
expect "a missing total fails even with cost-approved" 1 true "$fx/missing-total.json"
expect "an Infracost project error fails" 1 false "$fx/project-error.json"
expect "a project error fails even with cost-approved" 1 true "$fx/project-error.json"
expect "no estimate file fails" 1 false "$fx/does-not-exist.json"
expect "an invalid limit is a usage error" 2 false "$fx/under.json" "fifty"
expect "a missing argument is a usage error" 2 false "" ""

[[ "$failures" -eq 0 ]] && echo "cost-gate: all checks passed"
exit "$failures"
