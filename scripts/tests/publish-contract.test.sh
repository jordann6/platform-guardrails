#!/usr/bin/env bash
# Self-test for publish-contract.sh with stub terraform and aws commands on PATH.
# Assertions are single-quoted on purpose: check() evaluates them after each run.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/tf"
failures=0

cat >"$tmp/bin/terraform" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_OUTPUTS"
STUB
cat >"$tmp/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_AWS_ARGS"
STUB
chmod +x "$tmp/bin/terraform" "$tmp/bin/aws"
export PATH="$tmp/bin:$PATH" STUB_OUTPUTS="$tmp/outputs.json" STUB_AWS_ARGS="$tmp/aws.args" GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
unset GITHUB_OUTPUT

printf '# contract\ngeneration_id\nregion\n\ncluster_name\n' >"$tmp/allow.txt"
cat >"$tmp/outputs.json" <<'JSON'
{"generation_id":{"value":"aaaabbbbccccdddd"},"region":{"value":"us-east-1"},
 "cluster_name":{"value":"prod"},"db_password":{"value":"must-not-leak","sensitive":true}}
JSON

check() {
	if ! eval "$2"; then
		echo "FAIL: $1"
		failures=$((failures + 1))
	fi
}

"$root/scripts/publish-contract.sh" "$tmp/tf" /delivery/x/prod/contract "$tmp/allow.txt" >/dev/null
value="$(grep -A1 -x -- '--value' "$tmp/aws.args" | tail -1)"
check "publishes allowlisted outputs" '[[ "$(jq -r .cluster_name <<<"$value")" == prod ]]'
check "never publishes outputs outside the allowlist" '! grep -q must-not-leak "$tmp/aws.args"'
check "adds version and commit" '[[ "$(jq -r .contract_version <<<"$value")" == 1 && "$(jq -r .source_commit <<<"$value")" == "$GITHUB_SHA" ]]'
check "writes the named parameter" 'grep -qx /delivery/x/prod/contract "$tmp/aws.args"'

printf 'generation_id\nmissing_output\n' >"$tmp/allow-missing.txt"
rm -f "$tmp/aws.args"
check "fails on a missing allowlisted output" '! "$root/scripts/publish-contract.sh" "$tmp/tf" /p "$tmp/allow-missing.txt" >/dev/null 2>&1'
check "writes nothing when an output is missing" '[[ ! -f "$tmp/aws.args" ]]'

echo '{"generation_id":{"value":null}}' >"$tmp/outputs.json"
printf 'generation_id\n' >"$tmp/allow-null.txt"
check "fails on a null allowlisted output" '! "$root/scripts/publish-contract.sh" "$tmp/tf" /p "$tmp/allow-null.txt" >/dev/null 2>&1'

"$root/scripts/publish-contract.sh" --delete /delivery/x/prod/contract >/dev/null
check "deletes the parameter" 'grep -qx delete-parameter "$tmp/aws.args"'

if [[ $failures -gt 0 ]]; then
	echo "$failures publish-contract case(s) failed"
	exit 1
fi
echo "publish-contract self-test: all cases passed"
