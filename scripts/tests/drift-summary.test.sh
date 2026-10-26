#!/usr/bin/env bash
# Self-test for drift-summary.sh against a refresh-only plan fixture.
# Expected lines are single-quoted on purpose: they contain literal backticks.
# shellcheck disable=SC2016
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$("$root/scripts/drift-summary.sh" "$root/examples/plans/drift-plan.json")"
failures=0

check() {
	if ! grep -qF -- "$2" <<<"$out"; then
		echo "FAIL: $1 (expected: $2)"
		failures=$((failures + 1))
	fi
}

check "names the changed attribute" '`azurerm_network_security_group.spoke` (update): security_rule'
check "reports a resource deleted outside Terraform" '`aws_s3_bucket.logs` (delete): deleted outside Terraform'
check "names a secret attribute" '`google_secret_manager_secret_version.db` (update): secret_data'
if grep -q "must-not-print" <<<"$out"; then
	echo "FAIL: printed a drifted value"
	failures=$((failures + 1))
fi
if [[ "$(grep -c '^- ' <<<"$out")" -ne 3 ]]; then
	echo "FAIL: expected 3 drifted resources"
	failures=$((failures + 1))
fi

empty="$(jq -n '{format_version:"1.2"}' | "$root/scripts/drift-summary.sh" /dev/stdin)"
[[ -z "$empty" ]] || { echo "FAIL: no drift should print nothing"; failures=$((failures + 1)); }

if "$root/scripts/drift-summary.sh" 2>/dev/null; then
	echo "FAIL: missing argument should be a usage error"
	failures=$((failures + 1))
fi

[[ "$failures" -eq 0 ]] && echo "drift-summary: all checks passed"
exit "$failures"
