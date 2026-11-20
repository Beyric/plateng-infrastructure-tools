# SOP — AWS cost trims, measured (NAT / S3 endpoint, ECR, log retention)

**Prepared:** 2026-11-20 · **Kind:** read-only measurement + one small Terraform change + one prune script · **Nothing applied.**
PR: Beyric/plateng-infrastructure-tools, branch `chore/aws-cost-trims` · **Cost delta if all done: about $1.5–3 a month**
(before tax; tax adds about 15.6 % on top). The review that started this found $472 in 30 days (2026-10-21 → 2026-11-19, Cost
Explorer, reproduced: $471.71). The three items below are real hygiene but are not where the money is: compute is $212,
EKS control plane $72, NAT hours $32, EBS $17.

## Verdict per item

| # | Item | Measured | Monthly saving | Verdict |
|---|---|---|---|---|
| 1 | S3 gateway endpoint for the NAT | **Already exists** (`main.tf:49`, in the first commit `1ea950a` 2026-08-31; live as `vpce-069b4d6b610b230f7`, route `pl-63a5400a` on the private **and** public route tables, policy full-access) | **$0**, nothing to add | Do nothing. ECR interface endpoints would cost more than they save (below) |
| 2 | ECR cleanup | 979 + 384 images; ECR bills **$3.46 / 30 d** in total | **about $1.5–2.7** (up to 76 % of the $3.56 run-rate, less where layers are shared); cache grows back | Worth doing once, cheaply, with `scripts/ecr-prune.sh`. A lifecycle rule cannot express the safe policy |
| 3 | Log retention | CloudWatch Logs bills **$0.08 / 30 d** in total | **$0.00–0.1** | RDS groups: done in Terraform (hygiene, "never expire" is a slow leak). EKS group: **deliberately left alone** (below) |

## 1. NAT and the S3 gateway endpoint — measured

NAT `nat-08645c69e8e6ef5d5` (single, us-east-1a, created 2026-09-01). CloudWatch `AWS/NATGateway`, 2026-10-21 → 2026-11-20:

| Metric | GB (30 d) |
|---|---|
| `BytesOutToDestination` (VPC → internet) | 53.5 |
| `BytesInFromDestination` (internet → VPC) | 153.8 |
| Processed (billed) = in from source + in from destination | **≈ 207** |

Cost Explorer (`NatGateway-Bytes`, $0.045 / GB): **187.8 GB = $8.45** over the same 30 days (it trails CloudWatch by about a day);
October 316.6 GB = $14.25; 1–19 November 67.9 GB = $3.06 — falling. `NatGateway-Hours`: 718 h = $32.31, fixed.

- **Image layers already bypass the NAT.** ECR serves layers from S3; the endpoint is in the private route table. That is why the
  per-GB bill is only $8.45. The expected saving from "adding" the endpoint is already banked.
- Daily inbound is a floor of **0.73 GB** (about 22 GB a month, steady) plus spikes on build days (36.5 GB on 10-21, 14 GB on
  11-05 and 11-17). That pattern is CI pulling base images, packages and scanner data from the internet. It cannot be attributed
  further without VPC Flow Logs (not enabled; not worth enabling for a few dollars).
- **ECR interface endpoints (`ecr.api` + `ecr.dkr`) lose money:** about $0.01 / h per endpoint per AZ ≈ $7.30 / month each; two
  endpoints in two AZs ≈ **$29 / month** to remove only the ECR API-call share of an $8.45 bill. Not added.
- **Cross-region S3 buckets are not reachable through a gateway endpoint** (it covers only the endpoint's own region). Nothing
  here depends on that: the Terraform-managed buckets (state, CloudTrail, Loki, Vault snapshot) are us-east-1, ECR is us-east-1,
  and the endpoint policy is full-access, so Kyverno / Argo CD / Jenkins / Kaniko S3 traffic is unchanged. Anything fetching from
  a bucket in another region (for example a public mirror) keeps using the NAT, as before.
- **Aside, not asked:** `DataTransfer-Regional-Bytes` (traffic between availability zones) is **930 GB = $9.29** in the same 30 days,
  larger than the NAT per-GB bill. It is the price of the hard zone spread chosen in ADR-024; noted, not proposed for change.

## 2. ECR cleanup

### Why 976 and 384 images are left

The policy in `main.tf` (`aws_ecr_lifecycle_policy.expire_untagged`) expires untagged images after 7 days and `*-b*` PR/branch tags
after 7 days. A lifecycle preview of it expires **0** images on both repos today — it works as written. What it cannot touch:

| Repo | Total | Main builds (12-hex) | Kaniko cache (64-hex) | PR/branch (`*-b*`) |
|---|---|---|---|---|
| `weysure-api` | 976 (29 GB listed) | 101 | **867** | 8 |
| `weysure-web` | 384 (40 GB listed) | 81 | **290** | 13 |

Kaniko's `--cache-repo` shares the app repo and writes a 64-hex tag per cached layer. A lifecycle rule has only prefixes and `*`,
so it cannot separate those from 12-hex main SHAs (`COST_CONTROLS.md` recorded this on 2026-10-03). Main builds are kept forever
by design, and nearly every one is promoted (86 api / 73 web distinct promoted tags in gitops history).

### Why the requested policy is not a lifecycle rule

"Keep the newest 30 **and** never expire what gitops references **and** the previous 10 promoted" cannot be written as an ECR
lifecycle policy: rules only *select images to expire*, there is no exemption for a named tag, and a count rule would count cache
layers among the "newest 30". An age rule alone would eventually expire the image of a service that has not changed in that long,
and the next pod reschedule would hit `ImagePullBackOff`. So the policy is a script, run by a person.

### What shipped: `scripts/ecr-prune.sh`

Dry run by default; `--apply` deletes (human-run per `HUMAN_GATED_COMMANDS.md`). For each repo it **keeps**: the newest 30 main
builds; every tag in any `images.yaml` on gitops `origin/main` (prod now, stage when it exists); the previous 10 promoted tags per
file (rollback targets, from git history); every image a running pod uses (`kubectl get pods -A`, read-only); untagged,
PR/branch and any other tag shape (the lifecycle policy owns those). It **deletes** main builds outside that set and cache layers
older than 14 days (Kaniko's own cache TTL is 14 days). It stops if the prod tag in `images.yaml` is not found in the repo. It
asserts that no protected image is in the delete set.

Dry run, 2026-11-20 12:50 UTC (both prod tags were also running in the cluster):

| Repo | Images | Would delete | = main builds + cache layers | Keeps |
|---|---|---|---|---|
| `weysure-api` | 979 | **899** | 72 + 827 | 80 |
| `weysure-web` | 384 | **314** | 51 + 263 | 70 |

Deployed tags `de5e9d06ff92` (api, api-worker) and `c0e35fe58b0b` (web) were confirmed against `kubectl get pods -A` and are in
the protected set. Counts drift daily (the api tag changed between my first read and the dry run, from `a3005ddcbaab`).

### Rejected

- **Separate `-cache` repos** with a 14-day rule (the durable fix): Terraform for two repos and a Jenkins agent policy change,
  plus a `--cache-repo` change in both app Jenkinsfiles. Already deferred in the checklist at ~$0.50/mo; now ~$3 and slowly growing, still not worth three repos of change. Revisit if ECR passes ~$10 a month.
- **Age rule on all tags**: unsafe for an unchanged service (above).

## 3. Log retention

- **EKS control-plane logging is already off.** `aws eks describe-cluster`: `api, audit, authenticator, controllerManager,
  scheduler` all `enabled: false` (Terraform `enabled_log_types = []`, applied 2026-09-29). The log group
  `/aws/eks/beyric-prod/cluster` holds **8.15 GB**, last event 2026-09-29, retention 90 days, so it empties itself on
  **2026-12-28**. At $0.03 / GB-month that is at most about $0.24 / month.
- **Not changed to 30 days, on purpose.** Because logging stopped on 09-29, every event in the group is older than 30 days; setting
  30 would delete **all of it the moment it is applied** (irreversible) to save about 20 cents. It is also the only audit history
  that exists for 2026-09-02 → 09-29. If Adebayo wants it gone anyway: set `cloudwatch_log_group_retention_in_days = 30` in the
  `module "eks"` block and apply.
- **Flag, not part of this change:** `audit` and `authenticator` are off while the platform is live (since 2026-10-15). The comment
  in `main.tf` says "Before go-live: turn audit back on and ship it somewhere cheaper than CloudWatch". All three types together
  cost $51 / month in September (3.5 GB a day at $0.50 / GB ingest); the share of `audit` alone cannot be read from CloudWatch
  (per-stream sizes are not reported). Recommend re-enabling only `audit` and `authenticator` with 30-day retention after
  measuring one day; `api` (kube-apiserver) is the one nobody reads and should stay off.
- **RDS groups (this change).** `weysure-postgres-v2/postgresql` (4.8 MB) had no retention. `rds.tf` now sets
  `create_cloudwatch_log_group = true` and 30 days; `rds-log-groups.tf` imports the existing group (Terraform adopts it, nothing
  is recreated) and the module creates the empty `…/upgrade` group with 30 days. The verified plan is below.
- **Old `/aws/rds/instance/weysure-postgres/postgresql`** (3.2 MB, created 2026-09-04): the instance `weysure-postgres` is gone
  (`DBInstanceNotFound`; deleted 2026-10-13, SOP `2026-10-13-nlb-cloudflare-only-and-old-rds-deleted.md`). No Terraform, gitops,
  alarm, metric filter or dashboard references the group (searched both repos and CloudWatch). Safe to delete, by hand, below.

## Steps for Adebayo, in order

All commands from `~/Documents/Beyric/projects/plateng-infra/plateng-infrastructure-tools`. Start with `aws sso login --profile beyric-admin`.

**A. Log retention (Terraform; apply after the PR is merged to `main`)**

```bash
cd projects/weysure/terraform && terraform plan -out=tfplan
```

Expect (plus a harmless "Objects have changed outside of Terraform" note about the EKS `platform_version` going `eks.12` → `eks.17`):

```
  # module.rds.module.db_instance.aws_cloudwatch_log_group.this["postgresql"] will be updated in-place
  # (imported from "/aws/rds/instance/weysure-postgres-v2/postgresql")
      ~ retention_in_days           = 0 -> 30
  # module.rds.module.db_instance.aws_cloudwatch_log_group.this["upgrade"] will be created
Plan: 1 to import, 1 to add, 1 to change, 0 to destroy.
```

If the plan shows anything else (another session's change may be applied first), stop and do not apply.

```bash
terraform apply tfplan
```

Expect `Apply complete! Resources: 1 imported, 1 added, 1 changed, 0 destroyed.`

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/rds/instance/weysure-postgres-v2 --query 'logGroups[].[logGroupName,retentionInDays]' --output text
```

Expect two lines, both `30`. **If it goes wrong:** the change touches only log-group metadata. Roll back by deleting the
`rds-log-groups.tf` import and the two module lines, or set retention back with `aws logs delete-retention-policy`.

**B. Delete the old RDS log group (one `aws` command, irreversible, 3 MB)**

```bash
aws logs delete-log-group --log-group-name /aws/rds/instance/weysure-postgres/postgresql
```

Expect no output; `aws logs describe-log-groups --log-group-name-prefix /aws/rds/instance/weysure-postgres/` then lists only `weysure-postgres-v2`.

**C. ECR prune (after the PR is merged, or from the branch)**

```bash
./scripts/ecr-prune.sh
```

Read-only. Expect `cluster reachable`, then per repo a line "prod tag … stays: True" and a total near **1,200 images** (about 900 api, 310
web, drifting daily). If it prints `STOP`, `WARNING: cluster not reachable` or "stays: False", do not continue.

```bash
./scripts/ecr-prune.sh --apply
```

Expect `deleted N, failures 0` per batch of 100. Afterwards `aws ecr describe-images --repository-name weysure-api --query 'length(imageDetails)'` should be about 80
and web about 70. The saving shows in Cost Explorer after about two days. **Rollback:** deleted ECR images cannot be restored; cache layers
rebuild on the next build (a slow first build), main builds can be rebuilt from their commit. Nothing running or in the rollback window is deleted.

## Verification

| Claim | How | Result |
|---|---|---|
| Endpoint exists and is attached | `aws ec2 describe-vpc-endpoints`, `describe-route-tables` | verified live |
| NAT bytes and cost | CloudWatch + Cost Explorer (above) | verified live |
| Current policy expires nothing more | `start-lifecycle-policy-preview` both repos | `expiringImageTotalCount: 0` both |
| Prune script keeps deployed images | dry run against live ECR + `kubectl get pods -A` | verified live; script also asserts it |
| Log-retention Terraform | `terraform fmt -check`, `validate`, `tflint`, `plan -lock=false` against real state | verified: 1 import, 1 add, 1 change, 0 destroy |
| `terraform apply`, import, `--apply` prune, saving figures | — | **not verified: needs apply**; savings are ranges from billed usage, not measured after the fact |

## Follow-ups

- Re-enable EKS `audit` + `authenticator` logging before more real users (see above); decision for Adebayo.
- Rerun `scripts/ecr-prune.sh` monthly, or split the Kaniko cache into its own repos when ECR passes ~$10 a month.
- Delete `rds-log-groups.tf` after the apply (an import block that has run is a no-op).
