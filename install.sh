#!/usr/bin/env bash
#
# install.sh — wire an existing repo to the shared guardrails.
#
# Usage:
#   ./install.sh [--ref <commit>] [--no-terraform] /path/to/target-repo [terraform_dir]
#   ./install.sh [--ref <commit>] --app <name> /path/to/target-repo
#
# Copies the local hook config, gitignore additions, PR template and ADR
# scaffold into the target repo, and drops in a caller workflow that points at
# the reusable workflows here. Existing files are never overwritten silently.
#
#   --ref <commit>   Commit the caller pins in `uses:` and passes as
#                    guardrails_ref. Defaults to this checkout's HEAD. A full
#                    SHA is required: tags can move, commits cannot.
#   --no-terraform   For application repos with no Terraform root: the caller
#                    runs ci.yml (secret scan plus stack detection) instead of
#                    tf-ci.yml. Their infrastructure lives in its owning repo.
#   --app <name>     Also deliver the app through app-release.yml (implies
#                    --no-terraform): adds .github/workflows/release.yml, a canary
#                    deploy template in deploy/app and the cluster-side Flux
#                    objects in deploy/flux.yaml. Name: lowercase, the image name.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF=""
NO_TERRAFORM=0
APP=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--ref)
		REF="${2:-}"
		shift 2
		;;
	--no-terraform)
		NO_TERRAFORM=1
		shift
		;;
	--app)
		APP="${2:-}"
		NO_TERRAFORM=1
		shift 2
		;;
	-h | --help)
		sed -n '2,25p' "$0"
		exit 0
		;;
	*)
		POSITIONAL+=("$1")
		shift
		;;
	esac
done
TARGET="${POSITIONAL[0]:-}"
TF_DIR="${POSITIONAL[1]:-terraform}"

if [[ -z "$TARGET" ]]; then
	echo "usage: $0 [--ref <commit>] [--no-terraform | --app <name>] /path/to/target-repo [terraform_dir]" >&2
	exit 2
fi
if [[ -n "$APP" && ! "$APP" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
	echo "install: --app must be a lowercase image name, got '$APP'" >&2
	exit 2
fi

if [[ -z "$REF" ]]; then
	REF="$(git -C "$SRC" rev-parse HEAD)"
	if [[ -n "$(git -C "$SRC" status --porcelain)" ]]; then
		echo "install: warning: $SRC has uncommitted changes; the pinned commit will not include them" >&2
	fi
fi
if [[ ! "$REF" =~ ^[0-9a-f]{40}$ ]]; then
	echo "install: --ref must be a full 40-character commit SHA, got '$REF'" >&2
	exit 2
fi
REF_LABEL="$(git -C "$SRC" describe --tags --exact-match "$REF" 2>/dev/null || echo "untagged ${REF:0:12}")"
if ! git -C "$SRC" branch -r --contains "$REF" 2>/dev/null | grep -q .; then
	echo "install: warning: $REF is not on any remote branch yet; push it before the caller runs" >&2
fi

if [[ ! -d "$TARGET/.git" ]]; then
	echo "install: $TARGET is not a git repository" >&2
	exit 2
fi

copy_if_absent() {
	local src="$1" dst="$2"
	if [[ -e "$dst" ]]; then
		echo "  skip   ${dst#"$TARGET"/} (already exists)"
		return
	fi
	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst"
	echo "  add    ${dst#"$TARGET"/}"
}

if [[ $NO_TERRAFORM -eq 1 ]]; then
	echo "Installing guardrails into $TARGET (no Terraform, pinned to $REF_LABEL)"
	TEMPLATE="$SRC/templates/caller-workflow-app.yml"
else
	echo "Installing guardrails into $TARGET (terraform_dir=$TF_DIR, pinned to $REF_LABEL)"
	TEMPLATE="$SRC/templates/caller-workflow.yml"
fi

copy_if_absent "$SRC/templates/.pre-commit-config.yaml" "$TARGET/.pre-commit-config.yaml"
copy_if_absent "$SRC/templates/PULL_REQUEST_TEMPLATE.md" "$TARGET/.github/PULL_REQUEST_TEMPLATE.md"
copy_if_absent "$SRC/templates/adr-0000-template.md" "$TARGET/docs/adr/0000-template.md"

# Caller workflow, with the pinned commit and terraform directory substituted in.
workflow="$TARGET/.github/workflows/guardrails.yml"
if [[ -e "$workflow" ]]; then
	echo "  skip   .github/workflows/guardrails.yml (already exists)"
else
	mkdir -p "$(dirname "$workflow")"
	sed -e "s|__TF_DIR__|$TF_DIR|g" -e "s|__REF__|$REF|g" -e "s|__REF_LABEL__|$REF_LABEL|g" "$TEMPLATE" >"$workflow"
	echo "  add    .github/workflows/guardrails.yml"
fi

# Append gitignore entries that are missing rather than clobbering the file.
gitignore="$TARGET/.gitignore"
touch "$gitignore"
added=0
while IFS= read -r line; do
	[[ -z "$line" || "$line" == \#* ]] && continue
	if ! grep -qxF "$line" "$gitignore"; then
		if [[ $added -eq 0 ]]; then
			printf '\n# --- platform-guardrails ---\n' >>"$gitignore"
			added=1
		fi
		echo "$line" >>"$gitignore"
	fi
done <"$SRC/templates/gitignore-additions"
if [[ $added -eq 1 ]]; then
	echo "  update .gitignore"
else
	echo "  skip   .gitignore (nothing to add)"
fi

if [[ -n "$APP" ]]; then
	# Delivery: release caller, deploy template and cluster-side Flux objects.
	release="$TARGET/.github/workflows/release.yml"
	if [[ -e "$release" ]]; then
		echo "  skip   .github/workflows/release.yml (already exists)"
	else
		sed -e "s|__APP__|$APP|g" -e "s|__REF__|$REF|g" -e "s|__REF_LABEL__|$REF_LABEL|g" \
			"$SRC/templates/caller-workflow-release.yml" >"$release"
		echo "  add    .github/workflows/release.yml"
	fi
	if [[ -e "$TARGET/deploy/app" ]]; then
		echo "  skip   deploy/app (already exists)"
	else
		mkdir -p "$TARGET/deploy/app"
		for f in "$SRC"/templates/app/deploy/*.yaml; do
			sed "s|APP_NAME|$APP|g" "$f" >"$TARGET/deploy/app/$(basename "$f")"
		done
		echo "  add    deploy/app (Rollout, Service, PDB)"
	fi
	owner="$(git -C "$TARGET" remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+)/.*#\1#p' | tr '[:upper:]' '[:lower:]')"
	[[ -n "$owner" ]] || owner="OWNER"
	if [[ -e "$TARGET/deploy/flux.yaml" ]]; then
		echo "  skip   deploy/flux.yaml (already exists)"
	else
		sed -e "s|APP_NAMESPACE|$APP|g" -e "s|APP_NAME|$APP|g" -e "s|DEPLOY_REPOSITORY|ghcr.io/$owner/$APP-deploy|g" \
			"$SRC/templates/app/flux.yaml" >"$TARGET/deploy/flux.yaml"
		echo "  add    deploy/flux.yaml (cluster side, apply once)"
	fi
	cat <<EOF

Done. Remaining steps for $APP:

  1. cd $TARGET && pre-commit install
  2. Check deploy/app/rollout.yaml: container port, probe path (/healthz) and
     resources. The app must export OpenTelemetry HTTP server metrics; the
     template already sets OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES
     (service.version) and the collector endpoint. No metrics, no release.
  3. Point deploy/app/synthetic-traffic.yaml at a real route of the app (it
     gives the canary analysis requests to judge when there are no users).
  4. Local home cluster: $SRC/k8s/home/up.sh (once), then
       $SRC/k8s/home/add-app.sh $TARGET
     Any other cluster: install Flux, apply k8s/delivery-platform server-side
     (twice), then kubectl apply -f $TARGET/deploy/flux.yaml.
  5. Merge to main. The Release workflow builds, scans, publishes, attests and
     delivers; Flux applies it and the canary analysis decides.
EOF
	exit 0
fi

if [[ $NO_TERRAFORM -eq 1 ]]; then
	cat <<EOF

Done. Remaining manual steps:

  1. cd $TARGET && pre-commit install
  2. The caller runs ci.yml: gitleaks over full history plus the language and
     container gates it detects. If the repo builds its own image or runs its
     own SAST, set skip_container and keep those gates in the repo's pipeline.
  3. Infrastructure for this application belongs in its owning repository and
     runs through tf-ci.yml / tf-apply.yml there.
EOF
	exit 0
fi

cat <<EOF

Done. Remaining manual steps:

  1. cd $TARGET && pre-commit install
  2. Commit the provider lock file if it is not already tracked:
       terraform -chdir=$TF_DIR providers lock
  3. If the repo has pre-existing Checkov findings, create a baseline so the
     gate blocks new problems without blocking the adoption commit:
       checkov -d $TF_DIR --framework terraform --create-baseline
       # then set checkov_baseline in .github/workflows/guardrails.yml
  4. The credentialed gates (plan, destroy guard, cost diff) are not installed,
     because they need an OIDC role ARN this script cannot know. Once that role
     exists, copy the plan job from "The credentialed half" in the guardrails
     README, and confirm the trust policy is scoped to this repo. Add it only
     when the role is real: a gated job with missing permissions fails the run
     at startup rather than skipping.
  5. The FinOps allocation policy (CostCenter tag gate) is already active: it
     runs inside the static job via the shared policy set, no wiring needed.
     The FinOps cost *threshold* is stubbed as a commented 'finops' job in
     .github/workflows/guardrails.yml. Add the INFRACOST_API_KEY secret to the
     repo (free tier is fine), then uncomment that job to fail PRs that raise
     projected monthly spend past the limit.
EOF
