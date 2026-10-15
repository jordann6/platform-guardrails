#!/usr/bin/env bash
#
# publish-contract.sh: hand an infrastructure root's outputs to application
# pipelines through SSM, without giving them Terraform state.
#
# Usage:
#   scripts/publish-contract.sh <terraform_dir> <ssm_parameter> <allowlist_file> [contract_version]
#   scripts/publish-contract.sh --delete <ssm_parameter>
#
# Reads `terraform output -json` in <terraform_dir>, keeps only the output names
# listed in <allowlist_file> (one per line, # comments allowed), adds
# contract_version, source_commit and published_at, and writes the JSON document to
# <ssm_parameter> as a String. The allowlist is the boundary: an output that is not
# listed is never published, and a listed output that is missing or null fails the
# run, so a consumer can never read a partial contract.
#
# Runs as a step in tf-apply.yml when the caller sets contract_parameter, and the
# same way by an operator after a local apply. --delete is used by tf-destroy.yml
# so a destroyed environment leaves no contract behind.
#
# Requires terraform, jq and the aws CLI with credentials that may write the parameter.

set -euo pipefail

if [[ "${1:-}" == "--delete" ]]; then
	param="${2:?usage: $0 --delete <ssm_parameter>}"
	if aws ssm delete-parameter --name "$param" >/dev/null 2>&1; then
		echo "publish-contract: deleted $param"
	else
		echo "publish-contract: $param did not exist"
	fi
	exit 0
fi

tf_dir="${1:?usage: $0 <terraform_dir> <ssm_parameter> <allowlist_file> [contract_version]}"
param="${2:?missing ssm_parameter}"
allowlist="${3:?missing allowlist_file}"
version="${4:-1}"

if [[ ! -f "$allowlist" ]]; then
	echo "publish-contract: allowlist $allowlist not found" >&2
	exit 2
fi

names="$(grep -v '^[[:space:]]*#' "$allowlist" | sed 's/[[:space:]]//g' | sed '/^$/d' | jq -R . | jq -s .)"
if [[ "$(jq length <<<"$names")" -eq 0 ]]; then
	echo "publish-contract: allowlist $allowlist is empty" >&2
	exit 2
fi

outputs="$(terraform -chdir="$tf_dir" output -json)"

missing="$(jq -r --argjson names "$names" '[$names[] as $n | select((.[$n].value // null) == null) | $n] | join(", ")' <<<"$outputs")"
if [[ -n "$missing" ]]; then
	echo "publish-contract: allowlisted outputs missing or null: $missing" >&2
	exit 1
fi

commit="${GITHUB_SHA:-$(git -C "$tf_dir" rev-parse HEAD)}"
contract="$(jq -c --argjson names "$names" --arg version "$version" --arg commit "$commit" \
	--arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
	  [$names[] as $n | {key: $n, value: .[$n].value}] | from_entries
	  + {contract_version: $version, source_commit: $commit, published_at: $published}' <<<"$outputs")"

aws ssm put-parameter --name "$param" --type String --tier Standard --overwrite \
	--description "Deployment contract (allowlisted outputs of $tf_dir)" \
	--value "$contract" >/dev/null

generation="$(jq -r '.generation_id // empty' <<<"$contract")"
echo "publish-contract: wrote $(jq length <<<"$names") outputs to $param (version $version, commit ${commit:0:12}${generation:+, generation $generation})"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "contract_parameter=$param"
		echo "generation_id=$generation"
	} >>"$GITHUB_OUTPUT"
fi
