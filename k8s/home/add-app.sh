#!/usr/bin/env bash
#
# k8s/home/add-app.sh: point the home cluster at an app wired by install.sh --app.
#
# Applies the app's deploy/flux.yaml with the GHCR credential from up.sh, and
# gives the app namespace the same credential for image pulls. From then on,
# every delivery the app's Release workflow publishes is applied within a minute
# and canaried by the delivery platform.
#
# Usage: k8s/home/add-app.sh <repo-dir>    (the repo must contain deploy/flux.yaml)

set -euo pipefail

cluster="${HOME_CLUSTER:-home}"
ctx="k3d-$cluster"
k() { kubectl --context "$ctx" "$@"; }

repo="${1:-}"
flux_yaml="$repo/deploy/flux.yaml"
[[ -n "$repo" && -f "$flux_yaml" ]] || {
	echo "usage: add-app.sh <repo-dir> (needs deploy/flux.yaml; run install.sh --app first)" >&2
	exit 2
}
app="$(awk '/^kind: OCIRepository/{f=1} f && /^  name:/{print $2; exit}' "$flux_yaml")"
ns="$(awk '/targetNamespace:/{print $2; exit}' "$flux_yaml")"
[[ -n "$app" && -n "$ns" ]] || {
	echo "add-app: could not read the app name and namespace from $flux_yaml" >&2
	exit 1
}
k -n flux-system get secret ghcr >/dev/null 2>&1 || {
	echo "add-app: run k8s/home/up.sh first" >&2
	exit 1
}

k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
k label namespace "$ns" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
for n in flux-system "$ns"; do
	k -n flux-system get secret ghcr -o json |
		jq --arg n "$n" --arg name "$app-registry" '{apiVersion, kind, type, data, metadata: {name: $name, namespace: $n}}' |
		k apply -f - >/dev/null
done
k -n "$ns" patch serviceaccount default -p "{\"imagePullSecrets\":[{\"name\":\"$app-registry\"}]}" >/dev/null

# The repo's flux.yaml, with the private-registry secretRef switched on.
sed -e 's|  # secretRef:|  secretRef:|' -e "s|  #   name: $app-registry|    name: $app-registry|" "$flux_yaml" | k apply -f - >/dev/null
echo "add-app: $app follows $(awk '/url: oci/{print $2; exit}' "$flux_yaml") into namespace $ns"
echo "         watch: kubectl --context $ctx -n $ns get rollout $app -w"
