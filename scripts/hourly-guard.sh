#!/usr/bin/env bash
#
# hourly-guard.sh — detect resources that bill by the hour in Terraform state.
#
# The failure this exists to prevent: a demo landing zone deployed, shown, and
# then "destroyed" while a NAT gateway, a managed firewall, a load balancer, or
# an RDS instance quietly keeps billing. The topology and guardrail layer is
# nearly free; the whole cost risk is a forgotten hourly resource.
#
# Two callers, one script:
#   - TTL guard (scheduled): run against live state. A non-zero exit means
#     something billable is standing, which is the alarm.
#   - Post-destroy verify: run again after `terraform destroy`. A non-zero exit
#     means the destroy did not actually take everything hourly with it.
#
# Usage:
#   terraform -chdir=DIR state list > state.txt
#   scripts/hourly-guard.sh state.txt
#   # or: terraform -chdir=DIR state list | scripts/hourly-guard.sh
#
# Exit codes:
#   0  no hourly resources present
#   1  at least one hourly resource present
#   2  usage / environment error
#
# Environment:
#   HOURLY_PATTERNS   Path to a newline-delimited file of extended regexes
#                     matched against each state address. Defaults to
#                     .guardrails/hourly-types.txt, then to the built-in list.
#
# KMS keys, empty backup vaults, secrets, and log groups are deliberately NOT
# on this list: they are the ~$1-3/mo standing footprint the design allows to
# survive a destroy. This script only flags what bills by the hour.

set -euo pipefail

INPUT="${1:-}"

read_state() {
	if [[ -n "$INPUT" ]]; then
		if [[ ! -f "$INPUT" ]]; then
			echo "hourly-guard: state file not found: $INPUT" >&2
			exit 2
		fi
		cat "$INPUT"
	else
		# Read the state list from stdin.
		cat
	fi
}

# Resource types that bill by the hour across the three clouds. Matched against
# the full state address, so module-nested resources are caught too.
DEFAULT_PATTERNS=$(
	cat <<'EOF'
aws_nat_gateway
aws_networkfirewall_firewall
aws_vpc_endpoint
aws_db_instance
aws_rds_cluster(_instance)?
aws_elasticache_(cluster|replication_group)
aws_eks_cluster
aws_eks_node_group
aws_instance
aws_lb$
aws_alb$
aws_ec2_transit_gateway$
aws_ec2_client_vpn_endpoint
aws_vpn_gateway
aws_globalaccelerator_accelerator
azurerm_firewall$
azurerm_bastion_host
azurerm_virtual_network_gateway
azurerm_kubernetes_cluster
azurerm_(linux|windows)_virtual_machine
azurerm_mssql_database
azurerm_private_endpoint
azurerm_lb$
google_compute_router_nat
google_container_cluster
google_container_node_pool
google_sql_database_instance
google_compute_instance$
google_compute_forwarding_rule
EOF
)

patterns_file="${HOURLY_PATTERNS:-.guardrails/hourly-types.txt}"
if [[ -f "$patterns_file" ]]; then
	PATTERNS=$(grep -vE '^\s*(#|$)' "$patterns_file" || true)
	echo "hourly-guard: using patterns from $patterns_file"
else
	PATTERNS="$DEFAULT_PATTERNS"
	echo "hourly-guard: using built-in hourly-resource list"
fi

addresses=$(read_state | grep -vE '^\s*$' || true)

if [[ -z "$addresses" ]]; then
	echo "hourly-guard: state is empty. No hourly resources. OK"
	exit 0
fi

found=()
while IFS= read -r address; do
	[[ -z "$address" ]] && continue
	while IFS= read -r pattern; do
		[[ -z "$pattern" ]] && continue
		if [[ "$address" =~ $pattern ]]; then
			found+=("$address")
			break
		fi
	done <<<"$PATTERNS"
done <<<"$addresses"

if [[ ${#found[@]} -eq 0 ]]; then
	echo "hourly-guard: no hourly-billed resources in state. OK"
	exit 0
fi

echo ""
echo "hourly-guard: HOURLY-BILLED resources are present in state:"
for f in "${found[@]}"; do
	echo "  !! $f"
done
echo ""
echo "hourly-guard: these bill continuously. If this is a scheduled TTL check,"
echo "the demo window has outlived its budget; run the destroy. If this is a"
echo "post-destroy verification, the destroy did not remove everything."
exit 1
