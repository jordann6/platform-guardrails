#!/usr/bin/env bash
#
# destroy-guard.sh — fail when a Terraform plan destroys or replaces a
# stateful resource, unless the change was explicitly approved.
#
# The failure this exists to prevent: a plan that applies cleanly and takes a
# database with it because nobody read 4,000 lines of plan output.
#
# Usage:
#   terraform plan -out=tfplan
#   terraform show -json tfplan > plan.json
#   scripts/destroy-guard.sh plan.json
#
# Environment:
#   DESTROY_APPROVED=true   Bypass the gate (set by CI only when the PR carries
#                           the 'destroy-approved' label).
#   PROTECTED_PATTERNS      Path to a newline-delimited file of extended regexes
#                           matched against the resource type. Defaults to
#                           .guardrails/protected-types.txt, then to the
#                           built-in list below.

set -euo pipefail

PLAN_JSON="${1:-}"

if [[ -z "$PLAN_JSON" ]]; then
  echo "usage: $0 <plan.json>" >&2
  exit 2
fi

if [[ ! -f "$PLAN_JSON" ]]; then
  echo "destroy-guard: plan file not found: $PLAN_JSON" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "destroy-guard: jq is required" >&2
  exit 2
fi

# Resource types that hold state worth crying over.
DEFAULT_PATTERNS=$(
  cat <<'EOF'
^aws_db_instance$
^aws_db_cluster_snapshot$
^aws_rds_cluster$
^aws_dynamodb_table$
^aws_s3_bucket$
^aws_efs_file_system$
^aws_elasticache_.*$
^aws_kms_key$
^aws_secretsmanager_secret$
^aws_ecr_repository$
^aws_cloudwatch_log_group$
^aws_eks_cluster$
^azurerm_storage_account$
^azurerm_key_vault$
^azurerm_mssql_database$
^azurerm_postgresql_.*$
^azurerm_kubernetes_cluster$
^azurerm_container_registry$
EOF
)

patterns_file="${PROTECTED_PATTERNS:-.guardrails/protected-types.txt}"
if [[ -f "$patterns_file" ]]; then
  PATTERNS=$(grep -vE '^\s*(#|$)' "$patterns_file" || true)
  echo "destroy-guard: using protected types from $patterns_file"
else
  PATTERNS="$DEFAULT_PATTERNS"
  echo "destroy-guard: using built-in protected type list"
fi

# Every resource the plan will delete, including delete-then-create replacements.
destructive=$(
  jq -r '
    .resource_changes[]?
    | select(.change.actions | index("delete"))
    | [.type, .address, (.change.actions | join("+"))]
    | @tsv
  ' "$PLAN_JSON"
)

if [[ -z "$destructive" ]]; then
  echo "destroy-guard: no destroy or replace actions in plan. OK"
  exit 0
fi

echo ""
echo "destroy-guard: plan contains destructive actions:"
echo "$destructive" | while IFS=$'\t' read -r type address actions; do
  echo "  - $address ($actions)"
done

violations=()
while IFS=$'\t' read -r type address actions; do
  [[ -z "$type" ]] && continue
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if [[ "$type" =~ $pattern ]]; then
      violations+=("$address ($actions)")
      break
    fi
  done <<<"$PATTERNS"
done <<<"$destructive"

if [[ ${#violations[@]} -eq 0 ]]; then
  echo ""
  echo "destroy-guard: no protected (stateful) resources affected. OK"
  exit 0
fi

echo ""
echo "destroy-guard: PROTECTED resources would be destroyed or replaced:"
for v in "${violations[@]}"; do
  echo "  !! $v"
done

if [[ "${DESTROY_APPROVED:-false}" == "true" ]]; then
  echo ""
  echo "destroy-guard: DESTROY_APPROVED=true, allowing the change."
  exit 0
fi

cat <<'EOF'

destroy-guard: blocking.

If this is intentional, either:
  - add the 'destroy-approved' label to the pull request, or
  - re-run locally with DESTROY_APPROVED=true

If it is not intentional, the usual causes are a changed argument that forces
replacement, a renamed resource that needs 'terraform state mv', or a module
version bump. Check the "must be replaced" reason in the human-readable plan.
EOF

exit 1
