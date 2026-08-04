package main

# Shared helpers for the guardrail policies.
#
# Input is conftest's hcl2 parser in --combine mode: an array of
# {path, contents} where contents mirrors the HCL block structure.
# A single block parses to an object; repeated blocks parse to an array,
# so everything gets normalised through blocks_of() before use.

import rego.v1

blocks_of(v) := v if {
	is_array(v)
}

blocks_of(v) := [v] if {
	is_object(v)
}

resources contains r if {
	some file in input
	some type, named in file.contents.resource
	some name, block in named
	some body in blocks_of(block)
	r := {"type": type, "name": name, "body": body, "path": file.path}
}

providers contains p if {
	some file in input
	some name, block in file.contents.provider
	some body in blocks_of(block)
	p := {"name": name, "body": body, "path": file.path}
}

# A value HCL could not resolve statically (an interpolation, a function call,
# a variable reference) comes through as a string. Policies skip those rather
# than report a violation they cannot actually prove.
unresolved(v) if {
	is_string(v)
	contains(v, "${")
}

matches_any(s, patterns) if {
	some p in patterns
	regex.match(p, s)
}
