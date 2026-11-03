#!/usr/bin/env bash
#
# k8s/home/up.sh: a persistent local delivery target for app-release.yml.
#
# Creates (or repairs) a k3d cluster named "home" with Flux and the delivery
# platform, and stores a GHCR pull credential so Flux and the pods can pull
# private packages. Idempotent: run it again any time. k3d containers restart
# with Docker, so the cluster comes back on its own after a reboot as long as
# Docker Desktop starts at login.
#
# Needs: docker, k3d, kubectl, flux, and a GitHub token with ONLY the
# read:packages scope (classic PAT), from GHCR_TOKEN or the macOS Keychain item
# "ghcr-read" (security add-generic-password -a <user> -s ghcr-read -w). The token
# sits in a cluster Secret, so it must not carry broader scopes.
# GHCR_USER defaults to jordann6. Then wire each app with k8s/home/add-app.sh.
#
# Docker Desktop does not start at login on this machine: after a reboot, run
# `open -a Docker` and the cluster resumes by itself.

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cluster="${HOME_CLUSTER:-home}"
ctx="k3d-$cluster"
k() { kubectl --context "$ctx" "$@"; }

for tool in docker k3d kubectl flux jq; do
	command -v "$tool" >/dev/null || {
		echo "up: $tool is required" >&2
		exit 1
	}
done
docker info >/dev/null 2>&1 || {
	echo "up: Docker is not running" >&2
	exit 1
}
ghcr_user="${GHCR_USER:-jordann6}"
ghcr_token="${GHCR_TOKEN:-$(security find-generic-password -s ghcr-read -w 2>/dev/null || true)}"
if [[ -z "$ghcr_token" ]]; then
	echo "up: no GHCR token: set GHCR_TOKEN or add Keychain item ghcr-read (read:packages only)" >&2
	exit 1
fi
# Refuse a token that can do more than read packages. Classic PATs report their
# scopes in X-OAuth-Scopes.
scopes="$(curl -sS -o /dev/null -D - -H "Authorization: Bearer $ghcr_token" https://api.github.com/user |
	awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' | tr -d '\r')"
if [[ "$scopes" != "read:packages" ]]; then
	echo "up: the GHCR token must have only the read:packages scope (has: '${scopes:-unknown}')" >&2
	exit 1
fi

if ! k3d cluster list -o json | jq -e --arg c "$cluster" '.[] | select(.name == $c)' >/dev/null; then
	echo "up: creating cluster $cluster"
	k3d cluster create "$cluster" --servers 1 --agents 0 \
		--k3s-arg "--disable=traefik@server:0" \
		--kubeconfig-switch-context=false --wait >/dev/null
else
	k3d cluster start "$cluster" >/dev/null 2>&1 || true
fi
k wait --for=condition=Ready node --all --timeout=120s >/dev/null

echo "up: Flux (source and kustomize controllers)"
flux install --context "$ctx" --components=source-controller,kustomize-controller >/dev/null

echo "up: delivery platform"
# Server-side: the Argo Rollouts CRDs exceed the client-side annotation limit.
# Two passes: the CRDs must be established before the analysis template.
k apply --server-side --force-conflicts -k "$root/k8s/delivery-platform" >/dev/null 2>&1 || true
k wait --for condition=established --timeout=60s crd/rollouts.argoproj.io crd/clusteranalysistemplates.argoproj.io >/dev/null
k apply --server-side --force-conflicts -k "$root/k8s/delivery-platform" >/dev/null
for d in argo-rollouts/argo-rollouts monitoring/prometheus monitoring/otel-collector; do
	k -n "${d%/*}" rollout status "deploy/${d#*/}" --timeout=180s >/dev/null
done

echo "up: GHCR pull credential"
k -n flux-system create secret docker-registry ghcr --docker-server=ghcr.io \
	--docker-username="$ghcr_user" --docker-password="$ghcr_token" \
	--dry-run=client -o yaml | k apply -f - >/dev/null

echo "up: ready. kubectl context $ctx. Add apps with k8s/home/add-app.sh <repo-dir>."
