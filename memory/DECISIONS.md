# Architecture Decision Records

Decisions without recorded reasoning become cargo cult within about six weeks. Each record
states the context, the decision, the alternatives considered, the consequences accepted, and
the trigger that should make us revisit it.

**Status values:** `Accepted` · `Superseded` · `Revisit`

---

## ADR-001 — Migrate the application database from Supabase to AWS RDS PostgreSQL

**Date:** 2026-08-26 · **Status:** Accepted

**Context.** The application runs against Supabase Postgres in `eu-central-1`
(`aws-0-eu-central-1.pooler.supabase.com`), while the existing Terraform provisions an empty
RDS instance in `us-east-1` with `deletion_protection = true`. Applying it as written would
create a second, unused, hard-to-remove database.

Investigation confirmed Supabase provides **only hosted Postgres**. Authentication is already
self-hosted: `passlib` bcrypt hashing in `app/core/security.py`, `hashed_password` on the
local `users` table, JWTs signed with the application's own `SECRET_KEY`.
`app/core/supabase.py` is never imported.

**Decision.** Migrate to RDS as part of this build.

**Alternatives.** (a) Keep Supabase and drop the RDS module — cheapest and lowest risk.
(b) RDS for staging only, Supabase for production — pays for both.

**Consequences.** Full AWS ownership; enables Vault dynamic database credentials, which
Supabase cannot provide. Adds a rehearsed data migration with a maintenance window. Risk is
bounded because no passwords are stranded in a managed `auth` schema — the largest failure
mode of this migration class does not apply.

**Revisit if:** operational burden of self-managed Postgres exceeds the benefit.

---

## ADR-002 — All infrastructure in `us-east-1`

**Date:** 2026-08-26 · **Status:** Accepted

**Context.** Users are primarily in West Africa (Paystack integration). `us-east-1` is
roughly 140–180 ms from Lagos; European regions are roughly 95 ms. The existing Terraform
already targeted `us-east-1`.

**Decision.** `us-east-1`, with latency mitigated at the edge.

**Alternatives.** `eu-central-1` (same region as the current database, making the cutover
safer and permitting logical replication); `eu-west-1` (cheapest EU region); `af-south-1`
(closest, but a 15–30% price premium and a thinner service catalogue).

**Consequences.** Cheapest region and widest service coverage. Higher baseline latency,
mitigated by CloudFront edge TLS termination for both frontend and API, plus Redis caching.
The Supabase→RDS cutover becomes cross-region, so a maintenance window replaces logical
replication. `us-east-1` also has AWS's most publicised large-scale outage history.

**Revisit if:** measured p95 latency degrades the escrow flow, or a second region is
justified.

---

## ADR-003 — Two managed node groups: `platform` (on-demand) and `workload` (spot)

**Date:** 2026-08-26 · **Status:** Accepted

**Context.** Budget ceiling is $150–250/month. The EKS control plane consumes $73 of that
before any workload runs. Capacity analysis showed the platform stack needs ~4.5–6 vCPU and
13–17 GiB of requests; the originally configured `2 × t3.medium` provides ~3.5 vCPU / 6.4 GiB.

**Decision.** `platform` — 1 × `m6i.large` on-demand, hosting anything stateful or
control-plane-like. `workload` — 1–3 × `m6i.large` spot, hosting stateless replicas,
Prometheus, and ephemeral CI agents.

**Alternatives.** All on-demand (~$140/mo compute, over budget). All spot (Vault and Argo CD
subject to 2-minute reclaim). Karpenter (better economics, but obscures the primitives being
learned).

**Consequences.** Spot is 65–70% cheaper for reclaim-tolerant workloads. Requires node
labels, `nodeAffinity`, taints, `PodDisruptionBudget`s, and the AWS Node Termination Handler.
`m6i` over `t3` avoids CPU-credit throttling, which presents as an unexplained slowdown
rather than an error.

**Revisit if:** budget increases, or at the Phase 10 cost review (Karpenter, Graviton).

---

## ADR-004 — Deferred scope: Linkerd, Karpenter, multi-AZ NAT, multi-AZ RDS

**Date:** 2026-08-26 · **Status:** Accepted

**Decision.** Defer all four, each with an explicit revisit trigger.

**Consequences.** Linkerd's sidecar costs ~50m CPU / ~50 MiB on *every* pod — roughly 40% of
the on-demand node for mTLS not yet needed. A single NAT Gateway is a shared egress SPOF
across both AZs; an `us-east-1a` failure removes egress for healthy AZ-b nodes. Single-AZ RDS
means recovery is restore-from-PITR: RPO ≈ 5 min, RTO ≈ 20 min.

These are **consciously accepted risks with recorded costs and triggers**. That is what
separates a lean architecture from a cheap one — a cheap architecture has the same single NAT
Gateway and finds out during an AZ event.

**Revisit if:** budget increases; first AZ-related incident; first paying-customer SLA.

---

## ADR-005 — Four repositories; Jenkins is CI-only with zero cluster credentials

**Date:** 2026-08-26 · **Status:** Accepted

**Context.** The existing `Jenkinsfile` performs deployment directly (`kubectl set image`,
migration Jobs, `rollout undo`) using long-lived AWS access keys — contradicting the intended
Jenkins-as-CI / Argo-CD-as-CD split.

**Decision.** Two application repos, one Terraform repo, one GitOps repo. Jenkins builds,
scans, tests, pushes to ECR via IRSA, and commits an image tag to `plateng-gitops`. That
commit is its only handoff.

**Alternatives.** Monorepo (causes CI feedback loops and makes every app commit a potential
deploy). Argo CD Image Updater (convenient, but the desired state changes with no commit to
point at, breaking git-as-source-of-truth).

**Consequences.** Deployed state becomes a pure function of a git commit — the actual reason
GitOps won. Rollback is `git revert`. A compromised Jenkins cannot reach the cluster. Cost:
four repositories to maintain, and a bot credential scoped to the GitOps repo.

---

## ADR-006 — One cluster, two namespaces

**Date:** 2026-08-26 · **Status:** Accepted · ⚠ **Known weakness**

**Decision.** `weysure-stage` and `weysure-prod` as namespaces in a single EKS cluster.

**Consequences.** A second cluster would add $73/month control plane plus nodes, which the
budget cannot carry. Namespace isolation is weaker than cluster isolation: a bad Kyverno
policy, a failed control-plane upgrade, or node exhaustion affects both environments.
Mitigated by `ResourceQuota`, default-deny `NetworkPolicy`, separate Argo CD projects with
distinct RBAC, and stricter policy enforcement for prod.

**Revisit if:** stage causes a prod incident, or the first paying-customer SLA.

---

## ADR-007 — HashiCorp Vault OSS in-cluster with AWS KMS auto-unseal

**Date:** 2026-08-26 · **Status:** Accepted

**Alternatives.** AWS Secrets Manager alone (~$10/mo, zero operational burden, but **cannot
issue dynamic database credentials**). HCP Vault (managed, far outside budget).

**Decision.** Vault OSS, Raft integrated storage, AWS KMS auto-unseal via IRSA.

**Consequences.** The deciding factor is dynamic database credentials: the application
receives a Postgres user valid for one hour, then revoked. There is no standing application
database password anywhere. Cost is ~$2/month (KMS key + 8 GiB EBS) plus ~250m CPU / 512 MiB
of node capacity, and the operational burden of unsealing, upgrades, snapshots, and HA.

**KMS auto-unseal is not optional.** Vault boots sealed; without it, every pod restart
requires a human to enter 3-of-5 Shamir shares — the leading cause of self-hosted Vault
outages.

AWS Secrets Manager is still used, for break-glass only: Vault's recovery keys and the RDS
master password. Vault cannot store its own recovery keys.

**Revisit if:** operational burden outweighs the benefit of dynamic credentials.

---

## ADR-008 — External Secrets Operator rather than Vault Secrets Operator

**Date:** 2026-08-26 · **Status:** Accepted

**Decision.** ESO (CNCF) as the sync layer between Vault and Kubernetes Secrets.

**Consequences.** `ExternalSecret` manifests describe *what secret is wanted*, not *where it
lives*. Migrating to AWS Secrets Manager later changes one `SecretStore` resource; every
application manifest is untouched. VSO would couple every manifest to Vault. Paired with
Reloader, which triggers a rolling restart when a synced Secret changes — without it, pods
keep stale values indefinitely.

---

## ADR-009 — IAM Identity Center (SSO) replaces static IAM user access keys

**Date:** 2026-08-26 · **Status:** Accepted

**Context.** AWS is currently accessed as `arn:aws:iam::767397877316:user/s_user` with
long-lived access keys — the most commonly leaked AWS credential type.

**Decision.** Adopt IAM Identity Center. Engineers authenticate via SSO with MFA and assume a
`PlatformAdmin` role with a 1-hour session. `s_user` access keys are deleted once verified.

**Consequences.** A leaked credential becomes a 60-minute problem instead of a permanent one.
Terraform runs under an assumed role. Free. Requires `aws sso login` at the start of a
session.

---

## ADR-010 — RDS `manage_master_user_password = true`

**Date:** 2026-08-26 · **Status:** Accepted

**Context.** `terraform.tfvars` contained a plaintext `db_password`. The naive fix —
`random_password` — still writes the plaintext into Terraform state, readable by anyone with
access to the state bucket.

**Decision.** Let RDS generate and store the master password in AWS Secrets Manager.

**Consequences.** The master password is never in tfvars, never in state, never in git.
Terraform cannot read it back, which is the point. Vault uses it as the root rotation
credential for its database engine, and the application never sees it at all.
