package main

# Cost rules. Nothing in an editor or an AI suggestion has ever seen your bill,
# so the expensive defaults have to be caught structurally.

import rego.v1

approved_regions := {
	"us-east-1",
	"us-east-2",
	"us-west-2",
	"eastus",
	"eastus2",
	"centralus",
	"westus2",
}

deny contains msg if {
	some p in providers
	region := p.body.region
	not unresolved(region)
	is_string(region)
	not region in approved_regions

	msg := sprintf(
		"%s: provider %q uses region %q, which is outside the approved set %v. Cross-region data transfer and split reservations are the usual cost surprise here.",
		[p.path, p.name, region, sort(approved_regions)],
	)
}

# An unbounded log group bills forever for data nobody reads.
deny contains msg if {
	some r in resources
	r.type == "aws_cloudwatch_log_group"
	not r.body.retention_in_days

	msg := sprintf(
		"%s: %s.%s does not set retention_in_days, so logs are retained (and billed) forever.",
		[r.path, r.type, r.name],
	)
}

nat_gateways contains r if {
	some r in resources
	r.type == "aws_nat_gateway"
}

# Roughly $32/month each before data processing, and the single most common
# way a portfolio account quietly runs up a bill.
warn contains msg if {
	count(nat_gateways) > 1

	msg := sprintf(
		"%d aws_nat_gateway resources are declared. Each one is ~$32/month before data processing charges. Confirm per-AZ redundancy is actually required, or use a single NAT gateway or VPC endpoints.",
		[count(nat_gateways)],
	)
}

expensive_instance_patterns := [
	"^(m|c|r|i|x|p|g)[0-9]+[a-z]*\\.(4|8|9|12|16|24|32|48)x?large$",
	"^(p|g)[0-9]+.*",
]

warn contains msg if {
	some r in resources
	r.type in {"aws_instance", "aws_launch_template"}
	itype := r.body.instance_type
	is_string(itype)
	not unresolved(itype)
	matches_any(itype, expensive_instance_patterns)

	msg := sprintf(
		"%s: %s.%s requests instance_type %q. Confirm the size is justified before merging.",
		[r.path, r.type, r.name, itype],
	)
}
