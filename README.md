# platform-guardrails

Reusable CI gates for Terraform repositories. One callable workflow, one policy
suite, one destroy guard, wired into a new repo in three lines.

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

```yaml
# .github/workflows/guardrails.yml
name: Guardrails
on: [push, pull_request]
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
