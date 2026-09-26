# platform-guardrails

Reusable CI gates for the portfolio fleet. Two callable workflows cover any
stack: `ci.yml` for general repos (auto-detects Terraform, Python, Docker, Node,
Go) and `tf-ci.yml` for Terraform-only repos with stricter gates.

The problem this solves: infrastructure code that applies cleanly and does the
wrong thing permanently. A wide-open security group, a log group that bills
forever, a forced replacement that takes a database with it. None of those fail
a unit test, and none of them are obvious in a 4,000-line plan output at the end
of a long day. They have to be caught mechanically.

## What it enforces

| Gate | Blocks on | Runs where |
| --- | --- | --- |
| gitleaks | Any committed secret | `tf-ci` + pre-commit |
| `terraform fmt` / `validate` | Malformed or unparseable config | `tf-ci` |
| Lock file check | Missing `.terraform.lock.hcl` (unpinned providers) | `tf-ci` |
| tflint | Provider-level lint errors | `tf-ci` |
| Checkov | IaC misconfiguration, baseline-aware | `tf-ci` |
| Trivy | CRITICAL/HIGH config findings | `tf-ci` |
| conftest / OPA | Org rules Checkov does not know (see below) | `tf-ci` |
| destroy-guard | Destroy or replace of a stateful resource | `tf-plan` |
| Infracost | Cost diff comment on the PR | `tf-plan` |

Custom policy in `policy/`:

- **tags** — every significant resource carries `Project`, `Environment`,
  `Owner`, `ManagedBy`. Provider-level `default_tags` count toward this. Makes a
  surprise line item traceable to the thing that caused it.
- **cost** — approved regions only, `retention_in_days` required on every log
  group, warnings on multiple NAT gateways and oversized instances.
- **network** — no `0.0.0.0/0` ingress outside 80/443, no wide-open Azure NSG
  rules, no `aws_iam_access_key` (federate with OIDC instead), warning on IAM
  policies that appear to grant `Action:*` on `Resource:*`.

`deny` blocks the build. `warn` prints and passes, used where static analysis
cannot actually prove the finding (a `jsonencode`d IAM document is an opaque
string, so the policy says "read this" rather than pretending to know).

## Using it in a repo

### ci.yml — general purpose (recommended for most repos)

Auto-detects stack and runs appropriate gates. SARIF upload puts findings in the
GitHub Security tab.

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]
jobs:
  ci:
    uses: jordann6/platform-guardrails/.github/workflows/ci.yml@v1
    permissions:
      contents: read
      security-events: write
    # Optional: fail on findings instead of report-only
    # with:
    #   enforce_iac: true
    #   enforce_sast: true
    #   enforce_container: true
```

### tf-ci.yml — Terraform with stricter gates

```yaml
# .github/workflows/guardrails.yml
name: Guardrails
on: [push, pull_request]
permissions:
  contents: read
jobs:
  static:
    uses: jordann6/platform-guardrails/.github/workflows/tf-ci.yml@v1
    with:
      terraform_dir: terraform
```

Or run the installer, which also drops in the pre-commit config, PR template,
ADR scaffold, and gitignore entries:

```bash
./install.sh /path/to/repo terraform
```

Adopting a repo that already has findings: generate a Checkov baseline so the
gate blocks *new* problems without blocking the adoption commit, then ratchet it
down over time.

```bash
checkov -d terraform --framework terraform --create-baseline
```

## The credentialed half

`tf-plan.yml` needs a real cloud read, so it authenticates with GitHub OIDC and
nothing else. No long-lived access keys, and the trust policy should be scoped
to a single repo and ref:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:jordann6/my-repo:ref:refs/heads/main"]
}
```

It plans, runs the destroy guard, summarises the changes into the job summary,
and posts a cost diff. The destroy guard is bypassed only by labelling the pull
request `destroy-approved`, which makes "yes, delete the database" an explicit,
recorded act rather than a scroll-past.

`install.sh` does not wire this up, because it cannot know your role ARN. Once
the role exists, add this job to the repo's `guardrails.yml`:

```yaml
  plan:
    permissions:
      contents: read
      id-token: write
      pull-requests: write
    uses: jordann6/platform-guardrails/.github/workflows/tf-plan.yml@v1
    with:
      terraform_dir: terraform
      aws_role_arn: arn:aws:iam::111111111111:role/gha-plan
      aws_region: us-east-2
      enable_infracost: false
    secrets:
      INFRACOST_API_KEY: ${{ secrets.INFRACOST_API_KEY }}
```

Two things about that block are load-bearing.

The permissions must sit on the job, not at the top of the file. `tf-plan.yml`
declares `id-token: write` and `pull-requests: write`, and a reusable workflow
cannot be granted more than its caller holds. Hoisting them to workflow level
also works, and quietly hands OIDC token-minting to the `static` job, which on a
`pull_request` event is running Terraform written by whoever opened the PR. That
is the exact split these two workflows exist to maintain.

There is no point adding the job with an empty `aws_role_arn` and an `if: false`
until the role is ready. GitHub resolves `uses:` and checks the requested
permissions *before* it evaluates `if:`, so a gated job with missing permissions
still fails the entire run at startup, with no logs and no jobs, on every push.

## Gated apply, destroy, and the TTL guard

`tf-plan.yml` reads. Three more workflows write, tear down, and watch, and all
three authenticate with OIDC only.

`tf-apply.yml` is the just-in-time-to-prod control expressed in CI. It plans
read-only, runs the destroy guard, and saves that exact plan; a second job bound
to a GitHub environment pauses for a required reviewer and then applies the saved
plan. The reviewer approves the change they read, not a promise to re-plan, and
the write-scoped role lives behind the environment so the plan half can never
mutate. Two roles, by design.

```yaml
  apply:
    uses: jordann6/platform-guardrails/.github/workflows/tf-apply.yml@v1.3.0
    with:
      terraform_dir: terraform
      environment: prod-apply          # must have a required reviewer
      plan_role_arn:  arn:aws:iam::111111111111:role/gha-plan
      apply_role_arn: arn:aws:iam::111111111111:role/gha-apply
      aws_region: us-east-1
```

`tf-destroy.yml` has two modes because a teardown and the timer that watches for
a forgotten teardown are the same operation from two ends. With `check_only:
false` (wire it to `workflow_dispatch`) it destroys, then re-reads state and
fails if anything hourly survived, which is the section-8 teardown verification.
With `check_only: true` (wire it to `on: schedule`) it is the TTL guard: it reads
live state and fails if any hourly-billed resource is still standing. The red
scheduled run is the alarm; it changes nothing unless you also set
`auto_destroy: true`.

```yaml
# .github/workflows/ttl-guard.yml
on:
  schedule:
    - cron: "0 * * * *"   # hourly: is anything billable still up?
jobs:
  ttl:
    uses: jordann6/platform-guardrails/.github/workflows/tf-destroy.yml@v1.3.0
    with:
      terraform_dir: terraform
      aws_role_arn: arn:aws:iam::111111111111:role/gha-plan
      check_only: true
```

What counts as "hourly" is `scripts/hourly-guard.sh`: NAT gateways, managed
firewalls, VPC/private endpoints, managed databases, k8s control planes, load
balancers, VMs, and their Azure/GCP equivalents. KMS keys, empty backup vaults,
secrets, and log groups are deliberately excluded: they are the ~$1-3/mo standing
footprint the design lets survive a destroy. Override the list per repo with
`.guardrails/hourly-types.txt`.

## Local use

```bash
make check   # every static gate, same as CI
make guard   # plan and run the destroy guard against real state
make test    # prove the policies still gate
```

`make test` is the part that matters over time. It runs the suite against
`examples/pass` (must come back clean) and `examples/fail` (must be blocked). A
policy that quietly stops matching after a provider schema change is worse than
no policy, because it still looks green.

## What this deliberately does not do

It does not auto-remediate, and it does not gate on cost. Infracost comments,
it does not block, because a threshold that fires on legitimate growth gets
ignored within a month. The judgment stays with the reviewer; the tooling just
makes sure the reviewer is looking at the right three lines.
