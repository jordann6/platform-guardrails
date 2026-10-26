#!/usr/bin/env bash
#
# drift-summary.sh: list the resources a refresh-only plan found drifted.
#
# Reads `terraform show -json` of a `plan -refresh-only` and prints one
# markdown bullet per drifted resource, naming the attributes that changed.
# It names attributes, never values: a drifted value can be a secret.
#
# Usage:
#   terraform show -json drift.tfplan > drift.json
#   scripts/drift-summary.sh drift.json
#
# Exit codes: 0 printed (possibly nothing), 2 usage error.

set -euo pipefail

INPUT="${1:-}"
if [[ -z "$INPUT" || ! -r "$INPUT" ]]; then
	echo "usage: drift-summary.sh <refresh-only-plan.json>" >&2
	exit 2
fi

jq -r '
  .resource_drift[]?
  | . as $r
  | ($r.change.before // {}) as $b
  | ($r.change.after // {}) as $a
  | ([($b | keys[]), ($a | keys[])] | unique
     | map(select($b[.] != $a[.]))) as $attrs
  | "- `\($r.address)` (\($r.change.actions | join("+"))): \(
      if $r.change.after == null then "deleted outside Terraform"
      elif ($attrs | length) > 0 then ($attrs | join(", "))
      else "changed" end)"
' "$INPUT"
