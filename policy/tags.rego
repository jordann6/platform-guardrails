package main

# Every resource that costs money or holds data must be attributable to a
# project, an environment, and a human. This is the rule that makes a surprise
# bill traceable to the thing that caused it.

import rego.v1

required_tags := {"Project", "Environment", "Owner", "ManagedBy"}

# Deliberately a list of significant resource types rather than "everything
# taggable" — enumerating every AWS resource produces noise, not safety.
taggable_patterns := [
	"^aws_(instance|db_instance|rds_cluster|s3_bucket|dynamodb_table|eks_cluster|ecs_cluster|ecs_service|lambda_function|vpc|subnet|nat_gateway|elasticache_cluster|kms_key|sqs_queue|sns_topic|cloudwatch_log_group|ecr_repository|efs_file_system|lb|autoscaling_group|secretsmanager_secret)$",
	"^azurerm_(resource_group|storage_account|key_vault|kubernetes_cluster|linux_virtual_machine|windows_virtual_machine|container_registry|mssql_server|mssql_database|linux_web_app|windows_web_app|function_app|virtual_network|public_ip|log_analytics_workspace)$",
]

taggable(type) if {
	matches_any(type, taggable_patterns)
}

# Keys supplied by provider-level default_tags apply to every resource that
# provider creates, so they count toward the requirement.
default_tag_keys contains key if {
	some p in providers
	some dt in blocks_of(p.body.default_tags)
	some key, _ in dt.tags
}

resource_tag_keys(body) := keys if {
	is_object(body.tags)
	keys := {k | some k, _ in body.tags}
} else := set()

uses_modules if {
	some file in input
	file.contents.module
}

# Resources created inside a module are invisible to HCL-level analysis: the
# policy sees the module call, not the twenty resources it expands into. The
# only static guarantee available for a module-based repo is provider-level
# default_tags, so once a repo uses modules those defaults have to be complete
# on their own.
#
# Tag keys are compared case-sensitively on purpose. AWS treats "Owner" and
# "owner" as different keys, and mixed casing silently splits cost allocation
# reports into groups that do not add up.
deny contains msg if {
	uses_modules
	missing := required_tags - default_tag_keys
	count(missing) > 0

	msg := sprintf(
		"this repo declares module blocks, so resources created inside them can only be tagged by provider default_tags, and those are missing %v (found: %v). Add them to the provider default_tags block.",
		[sort(missing), sort(default_tag_keys)],
	)
}

deny contains msg if {
	some r in resources
	taggable(r.type)

	# Cannot prove anything about tags built by merge() or a variable, so those
	# are left to human review rather than reported as a violation.
	tags := object.get(r.body, "tags", null)
	not unresolved(tags)

	missing := required_tags - (resource_tag_keys(r.body) | default_tag_keys)
	count(missing) > 0

	msg := sprintf(
		"%s: %s.%s is missing required tags %v",
		[r.path, r.type, r.name, sort(missing)],
	)
}
