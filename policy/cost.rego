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
	"us-central1",
	"us-east1",
	"us-east4",
	"us-west1",
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

# GCP machine types large enough to be a deliberate choice rather than a default.
# Matches the vCPU suffix on the standard families (n2-standard-32, c3-highmem-44)
# and any accelerator-optimized family.
gcp_expensive_machine_patterns := [
	"^[a-z0-9]+-(standard|highmem|highcpu)-(16|22|30|32|44|48|60|64|80|88|96|128|176|180|192|224|360)$",
	"^(a2|a3|g2|m1|m2|m3)-.*",
]

warn contains msg if {
	some r in resources
	r.type in {"google_compute_instance", "google_compute_instance_template"}
	mtype := r.body.machine_type
	is_string(mtype)
	not unresolved(mtype)
	matches_any(mtype, gcp_expensive_machine_patterns)

	msg := sprintf(
		"%s: %s.%s requests machine_type %q. Confirm the size is justified before merging.",
		[r.path, r.type, r.name, mtype],
	)
}

warn contains msg if {
	some r in resources
	r.type == "google_container_node_pool"
	some nc in blocks_of(r.body.node_config)
	mtype := nc.machine_type
	is_string(mtype)
	not unresolved(mtype)
	matches_any(mtype, gcp_expensive_machine_patterns)

	msg := sprintf(
		"%s: %s.%s requests machine_type %q for every node in the pool. Confirm the size is justified before merging.",
		[r.path, r.type, r.name, mtype],
	)
}

# A regional Cloud SQL instance (HA) bills two instances' worth of compute. It
# is the right answer for prod and a quiet doubling anywhere else.
warn contains msg if {
	some r in resources
	r.type == "google_sql_database_instance"
	some st in blocks_of(r.body.settings)
	st.availability_type == "REGIONAL"

	msg := sprintf(
		"%s: %s.%s is REGIONAL (HA), which doubles compute cost. Confirm this is a prod instance or a timed failover demo.",
		[r.path, r.type, r.name],
	)
}
