package main

# Network and identity rules: the two categories where a generated snippet that
# "works" is indistinguishable from one that is wide open.

import rego.v1

public_cidrs := {"0.0.0.0/0", "::/0"}

# Ports that are defensible on a public-facing listener. Anything else reaching
# the whole internet is a finding.
web_ports := {80, 443}

deny contains msg if {
	some r in resources
	r.type == "aws_security_group"
	some ing in blocks_of(r.body.ingress)
	some cidr in ing.cidr_blocks
	cidr in public_cidrs
	not ing.from_port in web_ports

	msg := sprintf(
		"%s: %s.%s allows ingress from %s on port %v. Restrict the CIDR or terminate on 80/443 only.",
		[r.path, r.type, r.name, cidr, ing.from_port],
	)
}

deny contains msg if {
	some r in resources
	r.type == "aws_security_group_rule"
	r.body.type == "ingress"
	some cidr in r.body.cidr_blocks
	cidr in public_cidrs
	not r.body.from_port in web_ports

	msg := sprintf(
		"%s: %s.%s allows ingress from %s on port %v. Restrict the CIDR or terminate on 80/443 only.",
		[r.path, r.type, r.name, cidr, r.body.from_port],
	)
}

deny contains msg if {
	some r in resources
	r.type == "azurerm_network_security_rule"
	lower(r.body.direction) == "inbound"
	lower(r.body.access) == "allow"
	r.body.source_address_prefix in {"*", "Internet", "0.0.0.0/0"}
	not r.body.destination_port_range in {"80", "443"}

	msg := sprintf(
		"%s: %s.%s allows inbound traffic from %q on port %v.",
		[r.path, r.type, r.name, r.body.source_address_prefix, r.body.destination_port_range],
	)
}

# IAM policy documents usually arrive as jsonencode() or a heredoc, so they
# reach the parser as opaque strings. A string match is the honest limit of
# what static analysis can claim here, which is why this warns rather than
# denies: confirm it by reading the policy, not by trusting the scanner.
iam_types := {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

warn contains msg if {
	some r in resources
	r.type in iam_types
	doc := r.body.policy
	is_string(doc)
	regex.match(`"Action"\s*:\s*(\[\s*)?"\*"`, doc)
	regex.match(`"Resource"\s*:\s*(\[\s*)?"\*"`, doc)

	msg := sprintf(
		"%s: %s.%s appears to grant Action:* on Resource:*. Scope it before merging.",
		[r.path, r.type, r.name],
	)
}

# Long-lived static credentials in Terraform means a secret in state and,
# eventually, a secret in a screenshot. CI should federate with OIDC instead.
deny contains msg if {
	some r in resources
	r.type == "aws_iam_access_key"

	msg := sprintf(
		"%s: %s.%s creates a long-lived IAM access key. Use OIDC federation or an instance/pod role instead.",
		[r.path, r.type, r.name],
	)
}
