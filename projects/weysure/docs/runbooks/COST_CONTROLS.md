# Runbook — Cost controls and state-backend hardening

## State backend — verified 2026-08-27

`beyric-tfstate-767397877316` (renamed from `victor-terraform-state-2026` per ADR-015; the old
bucket held one state file describing zero resources, so this was a create, not a migration).

| Control | Status |
|---|---|
| Versioning | `Enabled` |
| Public access block (all 4 settings) | `true` |
| Default encryption | `AES256` |
| State locking | S3 native (`use_lockfile = true`), not DynamoDB — see below |

Region `us-east-1`. Backend block lives in `projects/weysure/terraform/versions.tf` and
carries no `profile` argument — credentials resolve through the standard AWS credential chain
(ADR-017), so the same configuration works unmodified from a laptop, CI runner, or a second
engineer's machine.

### S3 native locking replaces the DynamoDB lock table

Terraform 1.10 added `use_lockfile` on the `s3` backend: the lock is held as a plain object
(`<state-key>.tflock`) in the same bucket, using S3's own conditional-write (`If-None-Match`)
semantics to guarantee only one holder at a time. This removes a whole component from the
stack — no separate DynamoDB table to provision, IAM-permission, or pay for — while providing
the same guarantee: a second `terraform plan` or `apply` against the same state blocks until
the first one releases the lock.

Toolchain confirmed to support it:

```
$ terraform version | head -1
Terraform v1.15.8
```

(`>= 1.10` required by `versions.tf`; 1.15.8 exceeds it.)

**Verification status of the lock mechanism itself:** the config declares `use_lockfile = true`
and the toolchain supports it, but the end-to-end proof — actually watching a `.tflock` object
appear and disappear in the bucket during a real `terraform plan` — is blocked pending the SSO
session refresh described below. See "Dry-run status."

## Budget — prepared, not yet created (`[HUMAN]`)

Budget creation is an `aws budgets create-budget` call, which is a mutating AWS API call. Per
this repo's `docs/conventions/HUMAN_GATED_COMMANDS.md`, Adebayo runs it, not an agent.

| Setting | Value |
|---|---|
| Name | `weysure-platform-monthly` |
| Limit | **$250 USD / month** |
| Alerts | ACTUAL > 50%, ACTUAL > 80%, **FORECASTED > 100%** |
| Notification address | `<your-alert-email>` |

The forecast alert is the important one: it fires when AWS *projects* an overrun, which leaves
time to act. An actual-spend alert at 100% is a post-mortem.

**Where:** anywhere, with `beyric-admin` credentials available.

```bash
cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "weysure-platform-monthly",
  "BudgetLimit": { "Amount": "250", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

cat > /tmp/notifications.json <<'JSON'
[
  {
    "Notification": { "NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 50, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "<your-alert-email>" } ]
  },
  {
    "Notification": { "NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 80, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "<your-alert-email>" } ]
  },
  {
    "Notification": { "NotificationType": "FORECASTED", "ComparisonOperator": "GREATER_THAN", "Threshold": 100, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "<your-alert-email>" } ]
  }
]
JSON

aws budgets create-budget --account-id 767397877316 \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notifications.json \
  --profile beyric-admin
```

**Expect:** the call returns silently on success.

**Verify:**

```bash
aws budgets describe-budgets --account-id 767397877316 --profile beyric-admin \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount}' --output table
aws budgets describe-notifications-for-budget --account-id 767397877316 \
  --budget-name weysure-platform-monthly --profile beyric-admin \
  --query 'Notifications[].{Type:NotificationType,Threshold:Threshold}' --output table
```

Expected: one budget at `250`, and three notifications — ACTUAL 50, ACTUAL 80, FORECASTED 100.

**If it goes wrong:** a `DuplicateRecordException` means the budget already exists — check with
`describe-budgets` before retrying `create-budget`, don't just re-run it.

## Dry-run status — blocked on SSO session, not yet re-attempted

The brief's Step 9 (`terraform init` + `terraform plan` against the real backend) is the
highest-value verification in Phase 0: it proves SSO credentials → S3 backend → state locking
→ AWS provider → module resolution all work end to end before Phase 1 spends money on it.

Attempting it this session (`cd projects/weysure/terraform && export AWS_PROFILE=beyric-admin
&& terraform init`) failed with:

```
Error: No valid credential sources found
Error: failed to refresh cached credentials, refresh cached SSO token failed,
unable to refresh SSO token, operation error SSO OIDC: CreateToken ...
InvalidGrantException: ...
```

**Root cause:** the `beyric-admin` SSO session is configured with a 1-hour session duration.
The cached SSO token (`~/.aws/sso/cache/afb9d1dc*.json`) had `expiresAt: 2026-08-27T19:18:55Z`;
the `terraform init` attempt ran at `19:27` UTC, ~9 minutes past expiry, and the OIDC refresh
grant was rejected outright rather than silently renewed. `aws sts get-caller-identity` still
succeeded around the same time because the AWS CLI had a separately cached short-lived STS
credential from an earlier call in this session that had not yet expired — that cache is
distinct from the SSO OIDC token cache Terraform's Go SDK refreshes against, so the two tools
disagreed on whether the session was still good. This is expected, recurring behaviour with a
1-hour SSO session duration, not a one-off fluke — anyone driving this backend will hit it
repeatedly and the fix is always the same.

**Fix (human — requires Adebayo's own browser to approve the device login):**

```bash
aws sso login --profile beyric-admin
```

**Then re-run the dry run:**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform
export AWS_PROFILE=beyric-admin
terraform init
terraform plan -out=/tmp/phase0-dryrun.tfplan
```

**Expect:** `Terraform has been successfully initialized`, then either a plan summary
`Plan: N to add, 0 to change, 0 to destroy` (every resource is a create — nothing exists yet)
or an error. **Both outcomes are fine and neither should be applied** — the value of this step
is exercising the credential chain and the S3 backend/lock, not producing a clean plan. Known
gaps Phase 1 will still need to add: EKS `access_config` / access entries, add-ons, the OIDC
provider, and Karpenter — do not fix those here.

**To confirm the lock engaged**, in a second terminal while the plan is running:

```bash
aws s3api list-objects-v2 --bucket beyric-tfstate-767397877316 \
  --prefix weysure/infrastructure/ --profile beyric-admin --query 'Contents[].Key' --output text
```

A `.tflock` object should appear during the run and disappear once it completes.

**Discard the plan when done** — nothing is applied in Phase 0:

```bash
rm -f /tmp/phase0-dryrun.tfplan
```

Then confirm `terraform.tfvars` never shows in `git status --short` (it is `.gitignore`d via
`*.tfvars`) and that `aws s3 ls s3://beyric-tfstate-767397877316/weysure/infrastructure/
--profile beyric-admin` shows no leftover `.tflock` object once the plan has finished.

## Expected steady state

| Item | $/mo |
|---|---|
| EKS control plane | 73 |
| `system` node group — 1 × m6i.large on-demand | 70 |
| Karpenter-provisioned spot | 22–48 |
| NAT Gateway | 33 |
| Network Load Balancer | 18 |
| RDS db.t4g.micro + 20 GB | 14 |
| EBS volumes ~60 GB | 6 |
| ECR + data transfer | 8 |
| Cloudflare | **0** (free plan) |
| **Total** | **240–270** |

## If a budget alert fires

1. **Cost Explorer → Group by Service** — find which service moved.
2. Common causes, in order of likelihood:
   - **NAT Gateway data processing** — a workload pulling large images repeatedly, or egress
     that should be going through the S3 gateway endpoint.
   - **Karpenter provisioned more than expected** — check `kubectl get nodeclaims` and the
     NodePool limits. A pod with an unsatisfiable request can drive continuous provisioning.
   - **EBS volumes orphaned by deleted PVCs** — check for `available` volumes.
   - **A load balancer left behind** by a deleted Service of type LoadBalancer.
3. Check for anything unexpected in another region: `aws ec2 describe-regions` then iterate.

## Levers, cheapest first

| Lever | Saves | Cost of pulling it |
|---|---|---|
| Reduce Karpenter NodePool max | varies | Less burst headroom |
| NAT instance instead of NAT Gateway | ~$29/mo | Self-managed SPOF — see ADR-004 |
| Graviton (`m7g`) instances | ~20% of compute | Requires multi-arch image builds |
| Scale the `system` node group to 0 overnight | ~$35/mo | Cluster is unusable while scaled down |

## Emergency stop

Phase 0–1 only, and only when nothing stateful exists yet:

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform
terraform destroy
```

**Never run this once RDS holds real data.** From Phase 5 onward, take a final snapshot first
and follow `DATABASE_RECOVERY.md`.

## Open items for Adebayo

1. Run `aws sso login --profile beyric-admin`, then the dry run above, and confirm the `.tflock`
   object was observed and the plan (pass or fail) matches the "known gaps" expectation.
2. Run the budget-creation command above.
3. Once both are done, update this file's "Dry-run status" and "Budget" sections with the real
   outcome (plan resource counts or the verbatim error) and tick the corresponding items in
   `projects/weysure/docs/checklist/BUILD_CHECKLIST.md`.
