# Weysure — Terraform root module

Provisions the AWS foundation for the Weysure platform: VPC, EKS, RDS, ECR, IAM.

**Nothing here has been applied.** No AWS resources exist yet. See
[the Phase 0 plan](../docs/plans/2026-08-26-phase-0-foundations.md) for where this sits.

## Credentials — read this before running anything

**This configuration deliberately contains no `profile` argument**, in either the `backend "s3"`
block or the `provider "aws"` block. Credentials come from the environment, via the standard AWS
credential chain.

A hardcoded `profile = "..."` requires every machine that ever runs this configuration to have a
named profile spelled exactly that way in `~/.aws/config`. That is true of a laptop and false of
almost everything else — and it would break Phase 6 outright, where Jenkins authenticates through
**IRSA** and has no `~/.aws/config` at all.

| Where | How credentials arrive |
|---|---|
| Your laptop | `export AWS_PROFILE=beyric-admin`, refreshed by `aws sso login` |
| CI (Phase 6+) | IRSA — the pod's ServiceAccount assumes an IAM role; no profile, no keys |
| Break-glass | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars |

The configuration is identical in all three cases. That is the point.

```bash
export AWS_PROFILE=beyric-admin
aws sso login                                    # 1-hour session (ADR-009)
aws sts get-caller-identity --query Arn --output text
```

The ARN must contain `assumed-role`, not `user`. If it says `user`, you are on static keys and
the session will not expire — stop and fix that first.

## Usage

```bash
terraform init      # requires AWS_PROFILE to be set
terraform plan -out=tfplan
```

`terraform apply` is **human-only** — see
[HUMAN_GATED_COMMANDS](../../../docs/conventions/HUMAN_GATED_COMMANDS.md). An agent may run
`plan`, `validate` and `fmt`; it may not run `apply` or `destroy`.

## State

| | |
|---|---|
| Bucket | `beyric-tfstate-767397877316` (ADR-015) |
| Key | `weysure/infrastructure/terraform.tfstate` |
| Locking | S3 native (`use_lockfile`) — requires Terraform ≥ 1.10 |
| Encryption | SSE-S3 (AES256), versioning enabled, public access fully blocked |

No DynamoDB lock table. S3 conditional writes replaced it in Terraform 1.10; the old
DynamoDB pattern is legacy and is one fewer resource to pay for and maintain.

## Secrets

There is no `db_password` variable and there never should be. RDS generates its own master
password into AWS Secrets Manager via `manage_master_user_password = true` (ADR-010) — it is
never in a `.tfvars`, never in state, never in git.

`terraform.tfvars` is gitignored. Copy `terraform.tfvars.example` and edit locally.
