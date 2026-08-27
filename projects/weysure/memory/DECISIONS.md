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
mitigated by Cloudflare edge TLS termination for both frontend and API (see ADR-011), plus
Redis caching.
The Supabase→RDS cutover becomes cross-region, so a maintenance window replaces logical
replication. `us-east-1` also has AWS's most publicised large-scale outage history.

**Revisit if:** measured p95 latency degrades the escrow flow, or a second region is
justified.

---

## ADR-003 — One managed `system` node group; Karpenter provisions everything else

**Date:** 2026-08-26 · **Status:** Accepted · *(revised same day — see ADR-012)*

**Context.** Budget ceiling is $150–250/month. The EKS control plane consumes $73 of that
before any workload runs. Capacity analysis showed the platform stack needs ~4.5–6 vCPU and
13–17 GiB of requests; the originally configured `2 × t3.medium` provides ~3.5 vCPU / 6.4 GiB.

**Decision.** A single managed `system` node group — 1–2 × `m6i.large` on-demand — hosting
Karpenter itself, CoreDNS, and the control-plane-like platform components (Argo CD, Vault,
Traefik, cert-manager). **Karpenter provisions all other capacity** as spot-first NodePools
(ADR-012), replacing the originally planned static `workload` node group.

**Alternatives.** All on-demand (~$140/mo compute, over budget). All spot (Vault and Argo CD
subject to 2-minute reclaim). Karpenter (better economics, but obscures the primitives being
learned).

**Consequences.** Spot is 65–70% cheaper for reclaim-tolerant workloads. Requires node
labels, `nodeAffinity`, taints and `PodDisruptionBudget`s; Karpenter handles spot interruption
natively via an SQS queue, replacing the AWS Node Termination Handler and the Cluster
Autoscaler.

**On instance family — why `m6i` and not `t3`.** `t3` is *burstable*: it earns CPU credits
while idle and spends them under load. A `t3.medium` sustains only **20% of a vCPU** once
credits are exhausted (`t3.large`, 30%). Kubernetes nodes run many small always-on
controllers plus bursty work — Prometheus scrapes, SonarQube analysis, image builds — which
drains credits and then throttles. The failure presents as *unexplained slowness*, not an
error, which makes it expensive to diagnose. `m6i` is fixed-performance: 2 vCPU means 2 vCPU,
always. Under Karpenter the NodePool permits a *family set* (`m6i`, `m7i`, `m6a`, `m5`, `c6i`,
`r6i`) so Karpenter selects the cheapest instance that fits the pending pods.

**Revisit if:** budget increases, or at the Phase 10 cost review (Karpenter, Graviton).

---

## ADR-004 — Deferred scope: Linkerd, multi-AZ NAT, multi-AZ RDS

**Date:** 2026-08-26 · **Status:** Accepted

**Decision.** Defer all three, each with an explicit revisit trigger. *(Karpenter was
originally in this list; superseded by ADR-012, which brings it into scope.)*

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

---

## ADR-011 — Cloudflare for DNS and edge; Route 53 and CloudFront not used

**Date:** 2026-08-26 · **Status:** Accepted · **Supersedes** the CloudFront element of ADR-002

**Context.** `beyrictech.com` is registered at Namecheap, with authoritative DNS to be
delegated to Cloudflare. Production hostnames are `weysure.beyrictech.com` and
`weysure-api.beyrictech.com`. The account has no Route 53 hosted zone.

**Decision.** Delegate nameservers from Namecheap to Cloudflare. Use Cloudflare for DNS, CDN,
WAF and DDoS protection. `external-dns` and `cert-manager` use the Cloudflare provider with a
scoped API token stored in Vault. Route 53 and CloudFront are not used.

**Alternatives.** Route 53 + CloudFront (native AWS, IRSA-authenticated, but ~$0.50/mo for
the zone plus CloudFront request and transfer charges, and no free WAF). Namecheap DNS
directly (no CDN, no `external-dns` support, no WAF).

**Consequences.** Cloudflare's **free** plan terminates TLS at a Lagos PoP — materially better
for West African users than CloudFront, at zero cost — and this is the primary mitigation for
the `us-east-1` latency accepted in ADR-002. The NLB is never publicly exposed: its security
group admits only Cloudflare's published IP ranges, which is a security gain as much as a
performance one. Origin TLS uses **Full (strict)** against a real Let's Encrypt certificate —
never Flexible, which would leave the AWS-side leg unencrypted.

Costs: one IRSA role is replaced by a Cloudflare API token, which is a credential to store
and rotate rather than a role to assume. DNS availability now depends on Cloudflare.
Cloudflare's proxy also masks client IPs unless `CF-Connecting-IP` is honoured — Traefik must
be configured for it, or rate limiting will see one address.

**Revisit if:** a hard requirement emerges for AWS-native edge (e.g. Shield Advanced, or
signed URLs tied to CloudFront).

---

## ADR-012 — Adopt Karpenter for node provisioning

**Date:** 2026-08-26 · **Status:** Accepted · **Supersedes** the deferral in ADR-004

**Context.** The original plan used two static managed node groups and deferred Karpenter to a
Phase 10 optimisation, on the reasoning that node groups, taints and the Cluster Autoscaler
should be learned first. Two things changed that calculus: Karpenter is now the mainstream
approach in industry, and self-hosting SonarQube (ADR-013) adds a workload that is heavy but
*bursty* — exactly the shape static node groups handle worst.

**Decision.** Adopt Karpenter. A minimal managed `system` node group hosts Karpenter itself
and the control-plane-like platform components; Karpenter provisions all remaining capacity
through spot-first NodePools with consolidation enabled.

**Alternatives.** Static managed node groups + Cluster Autoscaler (simpler, but pays for idle
capacity and cannot right-size to the pending pod). EKS Auto Mode (lowest operational burden,
but carries a management-fee premium and hides the mechanics).

**Consequences.** Karpenter bin-packs pending pods onto the cheapest instance that fits, and
*consolidates* — terminating underutilised nodes and repacking. For a budget-constrained
cluster with a bursty CI workload this typically saves 20–40% against static groups, and it is
what makes self-hosted SonarQube affordable at all. It also replaces both the Cluster
Autoscaler and the AWS Node Termination Handler: spot interruption is handled natively via an
SQS queue.

**The chicken-and-egg is real and is why a managed node group remains.** Karpenter is a
Kubernetes controller and cannot provision the node it runs on. The `system` node group exists
solely to break that cycle. At `min_size = 1` Karpenter is briefly unavailable if that node is
lost — roughly 3–5 minutes while the managed node group replaces it; existing nodes are
unaffected. `min_size = 2` removes this at +$70/mo, and is the first thing to buy with a
budget increase.

Additional moving parts: an `EC2NodeClass` (AMI family, subnet and security-group selectors,
instance profile), one or more `NodePool` resources with disruption budgets, an IRSA role, and
the SQS interruption queue with its EventBridge rules.

**Revisit if:** operational complexity outweighs the savings, or EKS Auto Mode becomes
cost-competitive.

---

## ADR-013 — Self-host SonarQube in-cluster

**Date:** 2026-08-26 · **Status:** Accepted

**Decision.** Run SonarQube Community Build in-cluster with a dedicated in-cluster PostgreSQL,
rather than using SonarCloud.

**Alternatives.** SonarCloud (SaaS, zero operational burden, free for public repositories —
but these repositories are private, which is a paid tier).

**Consequences.** This is the single heaviest addition to the platform. SonarQube embeds
Elasticsearch and realistically needs ~1 vCPU / 3 GiB requested and ~2 vCPU / 4 GiB limit,
plus a PostgreSQL instance and persistent volumes for data and extensions. It pushes the
monthly cost to the top of the $150–250 band; Karpenter's consolidation (ADR-012) is what
keeps it viable, since SonarQube is idle between analyses.

**Two operational gotchas that must be handled at provisioning time, not discovered later:**

1. Embedded Elasticsearch requires `vm.max_map_count = 262144` on the **host**. On EKS this is
   set through the Karpenter `EC2NodeClass` userData or a privileged init container — it is not
   a pod-level setting, and SonarQube crash-loops without it.
2. It also requires a raised file-descriptor limit (`nofile` ≈ 131072).

Its PostgreSQL runs in-cluster rather than on RDS deliberately: `db.t4g.micro` has 1 GiB of
memory and cannot host both the application and SonarQube, and SonarQube's data is analysis
history — losing it costs re-analysis, not money.

**Revisit if:** cluster capacity becomes constrained, or SonarCloud's pricing changes.

---

## ADR-014 — Phase order: GitOps and Secrets before Ingress

**Date:** 2026-08-26 · **Status:** Accepted · **Corrects** the phase plan in the original spec

**Context.** The original phase plan installed Traefik, cert-manager and external-dns in Phase 2
but Argo CD in Phase 5, contradicting the bootstrap ordering in ARCHITECTURE.md diagram 7. Left
alone it would have meant installing three platform components imperatively with `helm install`
and retrofitting them into Argo CD three phases later.

**Decision.** Argo CD lands immediately after the cluster (Phase 2), Vault and ESO next
(Phase 3), ingress and TLS after that (Phase 4), data layer fifth.

**Consequences.** Every platform component after Phase 2 is installed *by* Argo CD, so no
component is ever adopted retroactively. Because Vault is usable through `kubectl port-forward`
and needs no ingress, placing it before Traefik means the Cloudflare API token required by
external-dns and cert-manager is read from Vault rather than hand-created — reducing the count
of manual bootstrap secrets from three to one.

The one remaining hand-created secret is Argo CD's git credential, which is irreducible: Vault
is installed by Argo CD, so it cannot supply the credential Argo CD needs to find Vault.

**Revisit if:** a future component genuinely requires ingress before secrets are available.
