#!/usr/bin/env bash
# Self-test for render-release.sh against the example app's deploy template.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmpl="$root/examples/app/deploy"
digest="sha256:$(printf '%064d' 0 | tr 0 a)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
	echo "FAIL: $1"
	failures=$((failures + 1))
}

"$root/scripts/render-release.sh" "$tmpl" "$work/ok" example-app "ghcr.io/o/example-app@$digest" 1.4.2 abc123
grep -q "digest: $digest" "$work/ok/kustomization.yaml" || fail "digest not appended"
grep -q 'app-release/version: "1.4.2"' "$work/ok/kustomization.yaml" || fail "version annotation not appended"
cmp -s "$tmpl/rollout.yaml" "$work/ok/rollout.yaml" || fail "template files must be copied unchanged"

reject() { # name args...
	local name="$1"
	shift
	if "$root/scripts/render-release.sh" "$@" >/dev/null 2>&1; then fail "$name"; fi
}
reject "a tag instead of a digest is rejected" "$tmpl" "$work/a" example-app "ghcr.io/o/example-app:latest" 1.0.0 c
reject "a non-semver version is rejected" "$tmpl" "$work/b" example-app "ghcr.io/o/example-app@$digest" v1 c
reject "a non-empty output directory is rejected" "$tmpl" "$work/ok" example-app "ghcr.io/o/example-app@$digest" 1.0.0 c
mkdir -p "$work/bad" && cp "$tmpl"/*.yaml "$work/bad/" && printf 'images:\n  - name: x\n' >>"$work/bad/kustomization.yaml"
reject "a template that sets images is rejected" "$work/bad" "$work/c" example-app "ghcr.io/o/example-app@$digest" 1.0.0 c

[[ "$failures" -eq 0 ]] && echo "render-release: all checks passed"
exit "$failures"
