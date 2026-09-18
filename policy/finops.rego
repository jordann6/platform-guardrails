package main

# FinOps allocation policy.
#
# tags.rego proves a resource is attributable to a project, an environment and a
# human. That is identity. This file proves the spend can be billed back to a
# budget line, which is allocation. The two are not the same rule: a resource
# can satisfy every tag in tags.rego and still be a hole in the chargeback
# report because CostCenter is missing or set to "TODO".
#
# CostCenter is singled out because it is the key every chargeback, showback and
# unit-economics report groups by. A missing or placeholder value does not
# error anywhere; it just quietly lands the spend in an "unallocated" bucket
# that finance cannot bill, which is exactly the failure this gate exists to
# catch at PR time instead of in next month's invoice.
#
# Runs on conftest's hcl2 parser in --combine mode, same as the other policies,
# and reuses resources / providers / blocks_of / unresolved / taggable /
# default_tag_keys from helpers.rego and tags.rego (same package).

import rego.v1

allocation_tag := "CostCenter"

# Values that pass a presence check but mean "nobody filled this in". Compared
# lowercased, because "TODO" and "todo" are the same excuse.
placeholder_values := {"", "todo", "tbd", "changeme", "xxx", "none", "n/a", "temp"}

# The shape a real cost centre code takes. Free text drifts into synonyms
# ("Platform", "platform-team", "PlatformEng") that split one budget line into
# three that do not add up, so the key is pinned to a format. Adjust this
# pattern to whatever your finance system actually issues.
cost_center_pattern := "^cc-[0-9]{4}$"

# --- helpers -----------------------------------------------------------------

# The CostCenter value a resource declares inline, if any.
resource_alloc_value(body) := v if {
	is_object(body.tags)
	v := body.tags[allocation_tag]
}

# CostCenter values supplied by provider-level default_tags. Values, not just
# keys, because a default of "TODO" is a fleet-wide placeholder, not coverage.
default_alloc_values contains v if {
	some p in providers
	some dt in blocks_of(p.body.default_tags)
	v := dt.tags[allocation_tag]
}

is_placeholder(v) if {
	is_string(v)
	not unresolved(v)
	lower(v) in placeholder_values
}

# --- module repos ------------------------------------------------------------

# Same reasoning as tags.rego: once a repo declares module blocks, HCL analysis
# cannot see the resources inside them, so provider default_tags is the only
# static guarantee that the allocation key reaches every resource.
deny contains msg if {
	uses_modules
	not allocation_tag in default_tag_keys

	msg := sprintf(
		"this repo declares module blocks, so resources inside them can only be tagged by provider default_tags, and %q is not set there. Add it to the provider default_tags block.",
		[allocation_tag],
	)
}

# --- resource-level presence -------------------------------------------------

deny contains msg if {
	some r in resources
	taggable(r.type)

	tags := object.get(r.body, "tags", null)
	not unresolved(tags)

	not resource_alloc_value(r.body)
	not allocation_tag in default_tag_keys

	msg := sprintf(
		"%s: %s.%s is missing the %q allocation tag, so its spend cannot be charged back. Set it on the resource or in provider default_tags.",
		[r.path, r.type, r.name, allocation_tag],
	)
}

# --- placeholder values (resource and default) -------------------------------

deny contains msg if {
	some r in resources
	taggable(r.type)
	v := resource_alloc_value(r.body)
	is_placeholder(v)

	msg := sprintf(
		"%s: %s.%s sets %q to placeholder %q. A placeholder allocation tag is worse than none: it looks allocated and is not.",
		[r.path, r.type, r.name, allocation_tag, v],
	)
}

deny contains msg if {
	some v in default_alloc_values
	is_placeholder(v)

	msg := sprintf(
		"provider default_tags sets %q to placeholder %q, which stamps every resource with an unbillable cost centre.",
		[allocation_tag, v],
	)
}

# --- format (advisory) -------------------------------------------------------

# A real, resolved value that does not match the house format. A warn, not a
# deny, because the format is an opinion the presence rule above is not.
warn contains msg if {
	some r in resources
	taggable(r.type)
	v := resource_alloc_value(r.body)
	is_string(v)
	not unresolved(v)
	not is_placeholder(v)
	not regex.match(cost_center_pattern, v)

	msg := sprintf(
		"%s: %s.%s sets %q to %q, which does not match the expected cost centre format %q. Mismatched codes split the allocation report.",
		[r.path, r.type, r.name, allocation_tag, v, cost_center_pattern],
	)
}

# --- waste that only FinOps cares about --------------------------------------

# gp3 is ~20% cheaper than gp2 at equal or better baseline performance, and
# there is no workload that prefers gp2 on price. This mirrors the reactive
# waste scan in the cost dashboard, moved left to before the volume exists.
warn contains msg if {
	some r in resources
	r.type == "aws_ebs_volume"
	r.body.type == "gp2"

	msg := sprintf(
		"%s: %s.%s uses gp2. gp3 is ~20%% cheaper for equal or better baseline performance; there is no price reason to choose gp2.",
		[r.path, r.type, r.name],
	)
}
