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

# --- GCP -------------------------------------------------------------------------

# VPC firewall rule open to the internet on a non-web port. direction defaults
# to INGRESS when omitted, so an absent direction is treated as ingress.
gcp_ingress(body) if {
	not body.direction
}

gcp_ingress(body) if {
	upper(body.direction) == "INGRESS"
}

deny contains msg if {
	some r in resources
	r.type == "google_compute_firewall"
	gcp_ingress(r.body)
	some cidr in r.body.source_ranges
	cidr in public_cidrs
	some a in blocks_of(r.body.allow)
	not gcp_web_only(a)

	msg := sprintf(
		"%s: %s.%s allows ingress from %s on %v. Restrict source_ranges or limit to 80/443.",
		[r.path, r.type, r.name, cidr, object.get(a, "ports", "all ports")],
	)
}

# An allow with no ports list opens every port of the protocol.
gcp_web_only(a) if {
	count(a.ports) > 0
	every p in a.ports {
		p in {"80", "443"}
	}
}

# Hierarchical and network firewall policy rules carry the same risk one level
# up, where one mistake applies to every VPC beneath the attach point.
deny contains msg if {
	some r in resources
	r.type in {"google_compute_firewall_policy_rule", "google_compute_network_firewall_policy_rule"}
	lower(r.body.action) == "allow"
	upper(r.body.direction) == "INGRESS"
	some m in blocks_of(r.body.match)
	some cidr in m.src_ip_ranges
	cidr in public_cidrs

	msg := sprintf(
		"%s: %s.%s allows ingress from %s at the policy level, which every VPC beneath it inherits.",
		[r.path, r.type, r.name, cidr],
	)
}

# Same reasoning as aws_iam_access_key: a service account key is a long-lived
# credential in state. Workload Identity Federation replaces it.
deny contains msg if {
	some r in resources
	r.type == "google_service_account_key"

	msg := sprintf(
		"%s: %s.%s creates a long-lived service account key. Use Workload Identity Federation or impersonation instead.",
		[r.path, r.type, r.name],
	)
}

# access_config on a network interface is what gives a VM an external IP.
deny contains msg if {
	some r in resources
	r.type in {"google_compute_instance", "google_compute_instance_template"}
	some ni in blocks_of(r.body.network_interface)
	ni.access_config

	msg := sprintf(
		"%s: %s.%s attaches an access_config, which gives the VM an external IP. Use IAP for admin access and Cloud NAT for egress.",
		[r.path, r.type, r.name],
	)
}

public_principals := {"allUsers", "allAuthenticatedUsers"}

deny contains msg if {
	some r in resources
	r.type in {"google_storage_bucket_iam_member", "google_storage_bucket_iam_binding"}
	some m in gcp_members(r.body)
	m in public_principals

	msg := sprintf(
		"%s: %s.%s grants %s on a bucket, which makes its objects public.",
		[r.path, r.type, r.name, m],
	)
}

gcp_members(body) := {body.member} if {
	is_string(body.member)
}

gcp_members(body) := {m | some m in body.members} if {
	is_array(body.members)
}

# Cloud SQL with a public IPv4 address. The org policy sql.restrictPublicIp
# blocks this at apply time; catching it here fails the PR instead.
deny contains msg if {
	some r in resources
	r.type == "google_sql_database_instance"
	some st in blocks_of(r.body.settings)
	some ipc in blocks_of(st.ip_configuration)
	ipc.ipv4_enabled == true

	msg := sprintf(
		"%s: %s.%s enables a public IPv4 address. Use private IP (PSA or PSC) only.",
		[r.path, r.type, r.name],
	)
}

# Basic roles are the GCP equivalent of Action:* on Resource:*.
basic_roles := {"roles/owner", "roles/editor"}

warn contains msg if {
	some r in resources
	r.type in {
		"google_project_iam_member", "google_project_iam_binding",
		"google_folder_iam_member", "google_folder_iam_binding",
		"google_organization_iam_member", "google_organization_iam_binding",
	}
	r.body.role in basic_roles

	msg := sprintf(
		"%s: %s.%s grants basic role %s. Use a predefined or custom role scoped to the job.",
		[r.path, r.type, r.name, r.body.role],
	)
}
