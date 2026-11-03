#!/usr/bin/env bash
#
# render-release.sh: stamp one release onto an app's deploy template.
#
# Copies the template directory and appends, to the copy's kustomization.yaml,
# the image pinned by digest and the release annotations app-release/version and
# app-release/commit. The template must not set images or commonAnnotations
# itself. The result is what app-release.yml pushes as the deploy artifact.
#
# Usage:
#   scripts/render-release.sh <template-dir> <out-dir> <image-name> <repo@sha256:digest> <version> <commit>
#
# Exit codes: 0 rendered, 1 template or reference rejected, 2 usage error.

set -euo pipefail

if [[ $# -ne 6 ]]; then
	echo "usage: render-release.sh <template-dir> <out-dir> <image-name> <repo@sha256:digest> <version> <commit>" >&2
	exit 2
fi
TEMPLATE="$1" OUT="$2" NAME="$3" REF="$4" VERSION="$5" COMMIT="$6"

fail() {
	echo "render-release: $1" >&2
	exit 1
}

[[ -f "$TEMPLATE/kustomization.yaml" ]] || fail "$TEMPLATE has no kustomization.yaml"
[[ "$REF" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || fail "image must be pinned by digest (repo@sha256:...), got '$REF'"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be MAJOR.MINOR.PATCH, got '$VERSION'"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || fail "invalid image name '$NAME'"
if grep -Eq '^(images|commonAnnotations):' "$TEMPLATE/kustomization.yaml"; then
	fail "the template sets images or commonAnnotations; the release sets those"
fi
[[ ! -e "$OUT" || -z "$(ls -A "$OUT" 2>/dev/null)" ]] || fail "$OUT exists and is not empty"

mkdir -p "$OUT"
cp -R "$TEMPLATE/." "$OUT/"
cat >>"$OUT/kustomization.yaml" <<YAML

images:
  - name: $NAME
    newName: ${REF%@*}
    digest: ${REF#*@}
commonAnnotations:
  app-release/version: "$VERSION"
  app-release/commit: "$COMMIT"
YAML
