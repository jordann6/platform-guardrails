#!/usr/bin/env bash
#
# app-release-e2e.sh: prove app-release.yml end to end on a kind cluster.
#
# Run by app-release-selftest.yml after app-release.yml has published the example
# app and delivered version $VERSION. Installs Flux and k8s/delivery-platform,
# points Flux at the deploy artifact, then:
#   1. the delivered version goes live (first release, no canary),
#   2. a second version canaries through the http-canary analysis to Healthy,
#   3. a degraded version (30% injected 500s) is aborted by the analysis and only
#      the previous version keeps serving,
#   4. a good version rolls forward from the abort, so the highest version in the
#      registry is always a healthy one.
#
# Env: IMAGE (repo@sha256:...), DEPLOY_REPO (registry/app-deploy), VERSION
# (MAJOR.MINOR.PATCH delivered by the workflow), REGISTRY_USER, REGISTRY_TOKEN.

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
app=example-app
ns=example-app
: "${IMAGE:?}" "${DEPLOY_REPO:?}" "${VERSION:?}" "${REGISTRY_USER:?}" "${REGISTRY_TOKEN:?}"
registry="${DEPLOY_REPO%%/*}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say() { echo "::group::$1"; }
done_() { echo "::endgroup::"; }
fail() {
	echo "::error::$1"
	kubectl -n "$ns" get rollout,analysisrun,pods -o wide || true
	kubectl -n flux-system get kustomization,ocirepository || true
	exit 1
}
phase() { kubectl -n "$ns" get rollout "$app" -o jsonpath='{.status.phase}'; }
current() {
	[[ "$(kubectl -n "$ns" get rollout "$app" -o jsonpath='{.status.observedGeneration}')" == \
		"$(kubectl -n "$ns" get rollout "$app" -o jsonpath='{.metadata.generation}')" ]]
}
# wait_phase WANT SECONDS: the Rollout reaches WANT for its current spec.
wait_phase() {
	local want="$1" deadline=$((SECONDS + $2))
	while ((SECONDS < deadline)); do
		if kubectl -n "$ns" get rollout "$app" >/dev/null 2>&1 && current && [[ "$(phase)" == "$want" ]]; then
			return 0
		fi
		sleep 5
	done
	return 1
}
serving_versions() {
	kubectl -n "$ns" get pods -l app.kubernetes.io/name="$app" -o json |
		jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
		        | .metadata.annotations["app-release/version"]] | unique | join(",")'
}
# deliver VERSION [FAIL_RATIO]: render and push like app-release.yml does.
deliver() {
	local version="$1" ratio="${2:-}" out="$work/r-$1"
	"$root/scripts/render-release.sh" "$root/examples/app/deploy" "$out" "$app" "$IMAGE" "$version" "$GITHUB_SHA"
	if [[ -n "$ratio" ]]; then
		cat >>"$out/kustomization.yaml" <<YAML
patches:
  - target:
      kind: Rollout
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value: {name: FAIL_RATIO, value: "$ratio"}
YAML
	fi
	flux push artifact "oci://$DEPLOY_REPO:$version" --path "$out" \
		--source "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" --revision "e2e@sha1:$GITHUB_SHA" >/dev/null
	flux reconcile source oci "$app" -n flux-system >/dev/null
	flux reconcile kustomization "$app" -n flux-system --timeout=30s >/dev/null 2>&1 || true
}

say "Install Flux and the delivery platform"
flux install --components=source-controller,kustomize-controller >/dev/null
kubectl apply --server-side -k "$root/k8s/delivery-platform" >/dev/null 2>&1 || true
kubectl wait --for condition=established --timeout=60s crd/rollouts.argoproj.io crd/clusteranalysistemplates.argoproj.io >/dev/null
kubectl apply --server-side -k "$root/k8s/delivery-platform" >/dev/null
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s
kubectl -n monitoring rollout status deploy/prometheus --timeout=180s
kubectl -n monitoring rollout status deploy/otel-collector --timeout=180s
done_

say "Wire the app (private registry)"
echo "$REGISTRY_TOKEN" | docker login "$registry" -u "$REGISTRY_USER" --password-stdin >/dev/null
sed -e "s|APP_NAMESPACE|$ns|g" -e "s|APP_NAME|$app|g" -e "s|DEPLOY_REPOSITORY|$DEPLOY_REPO|g" \
	-e 's|  # secretRef:|  secretRef:|' -e "s|  #   name: $app-registry|    name: $app-registry|" \
	"$root/templates/app/flux.yaml" >"$work/flux.yaml"
kubectl create namespace "$ns" >/dev/null
kubectl label namespace "$ns" pod-security.kubernetes.io/enforce=restricted >/dev/null
for n in flux-system "$ns"; do
	kubectl -n "$n" create secret docker-registry "$app-registry" --docker-server="$registry" \
		--docker-username="$REGISTRY_USER" --docker-password="$REGISTRY_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
kubectl -n "$ns" patch serviceaccount default -p "{\"imagePullSecrets\":[{\"name\":\"$app-registry\"}]}" >/dev/null
kubectl apply -f "$work/flux.yaml" >/dev/null
done_

say "1. Delivered version $VERSION goes live"
wait_phase Healthy 300 || fail "version $VERSION did not become Healthy"
[[ "$(serving_versions)" == "$VERSION" ]] || fail "expected $VERSION serving, got $(serving_versions)"
echo "Healthy, serving $VERSION"
done_

say "Synthetic traffic (from the deploy template)"
kubectl -n "$ns" rollout status "deploy/$app-synthetic" --timeout=120s
done_

IFS=. read -r major minor patch <<<"$VERSION"
good="$major.$minor.$((patch * 100 + 1))"
bad="$major.$minor.$((patch * 100 + 2))"
fix="$major.$minor.$((patch * 100 + 3))"

say "2. Version $good canaries through analysis"
deliver "$good"
sleep 10
wait_phase Healthy 480 || fail "canary $good did not become Healthy"
run="$(kubectl -n "$ns" get analysisrun -o json | jq -r '.items | sort_by(.metadata.creationTimestamp) | .[-1]')"
[[ "$(jq -r '.status.phase' <<<"$run")" == "Successful" ]] || fail "analysis for $good was not Successful"
jq -r '"analysis: " + ([.status.metricResults[] | "\(.name)=\([.measurements[].value] | join(","))"] | join(" "))' <<<"$run"
[[ "$(serving_versions)" == "$good" ]] || fail "expected $good serving, got $(serving_versions)"
done_

say "3. Degraded version $bad is stopped by analysis"
deliver "$bad" 0.3
sleep 10
wait_phase Degraded 480 || fail "degraded canary $bad was not aborted"
[[ "$(kubectl -n "$ns" get rollout "$app" -o jsonpath='{.status.abort}')" == "true" ]] || fail "Rollout not marked aborted"
kubectl -n "$ns" get analysisrun -o json |
	jq -r '.items | sort_by(.metadata.creationTimestamp) | .[-1] | "analysis \(.status.phase): \(.status.message // "")"'
sleep 15
[[ "$(serving_versions)" == "$good" ]] || fail "expected only $good serving after the abort, got $(serving_versions)"
echo "Aborted; only $good serving"
done_

# Leave the registry's highest version healthy: a cluster that starts following
# this artifact later must not begin with the degraded build. This is also the
# recovery path: a fix (or a rollback) ships as a higher version.
say "4. Version $fix rolls forward from the aborted release"
deliver "$fix"
sleep 10
wait_phase Healthy 480 || fail "fix $fix did not become Healthy after the abort"
[[ "$(serving_versions)" == "$fix" ]] || fail "expected $fix serving, got $(serving_versions)"
echo "Healthy, serving $fix"
done_

{
	echo "### app-release end to end"
	echo "| Step | Result |"
	echo "|---|---|"
	echo "| $VERSION delivered by app-release.yml | Healthy |"
	echo "| $good canary with analysis | Healthy, analysis Successful |"
	echo "| $bad with 30% injected errors | Aborted by analysis, $good kept serving |"
	echo "| $fix after the abort | Healthy |"
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "app-release-e2e: all checks passed"
