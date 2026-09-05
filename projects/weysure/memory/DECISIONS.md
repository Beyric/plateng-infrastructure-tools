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
Supabase cannot provide.

> **Amended 2026-08-27 — the Supabase database is empty / throwaway.** Confirmed with Adebayo
> against the question that actually matters: not "is this data valuable?" but "has anything
> outside this database already acted on a row?" Nothing has — no Paystack transaction
> reference in their ledger, no acknowledged webhook, no email a real person received. So there
> is nothing to preserve and no external record to reconcile against. This collapses the
> "migration" into a provisioning step: create RDS, run `alembic upgrade head` (47 revisions),
> point `DATABASE_URL` at it. No `pg_dump`, no `pg_restore`, no checksum verification, no
> maintenance window, no dual-running, no rollback window.
>
> This is the cheapest moment this migration will ever have. Every row added from here makes it
> more expensive, and the cost is not linear — it is the difference between a schema build and
> a cutover with an audit trail. The same move after launch would need a write freeze, verified
> row counts, and a rehearsed rollback, because an escrow ledger's counterparties keep their own
> records and those survive dropping your tables.

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

---

## ADR-015 — Rename the Terraform state bucket to `beyric-tfstate-767397877316`

**Date:** 2026-08-27 · **Status:** Accepted · **Supersedes** the bucket named in ADR-010's context

**Context.** State lived in `victor-terraform-state-2026`, which already served three projects
via key prefixes (`devops-lab/`, `luran/`, `weysure/`). Two weaknesses: `victor-` is
personally scoped for what is now organisation infrastructure, and `2026` encodes nothing —
it reads as stale from January 2027 onward and invites "is there a 2027 bucket?" forever.

**Decision.** `beyric-tfstate-767397877316`. Organisation prefix, purpose, account id.

**Alternatives.** Keep the existing name (zero work, permanent ambiguity). A random suffix
(unique, but tells a reader nothing).

**Consequences.** S3 bucket names are globally unique across **every AWS customer**, not just
your account — which is why suffixes exist at all. The account id guarantees availability and
documents ownership in the name, so anyone reading a backend block knows which account holds
the state without opening a console.

**The timing is the whole argument.** The old bucket contained exactly one state file
describing **zero** resources — a lab VPC applied and then destroyed, serial 9. Neither Luran
nor Weysure had ever been applied. So this is a create, not a migration: no
`terraform init -migrate-state`, no state surgery, no risk. That property expires the moment
Phase 1 applies, after which state becomes the only record mapping real infrastructure to
configuration, and moving it becomes a careful operation rather than a rename.

The old bucket is left in place, holding a zero-resource lab state. Delete it once Phase 1 has
applied successfully against the new one.

**Revisit if:** never, realistically — but any rename after Phase 1 requires
`terraform init -migrate-state` and a verified state pull first.

---

## ADR-016 — SSO profiles are named for the account, not the project

**Date:** 2026-08-27 · **Status:** Accepted · **Corrects** an error in the Phase 0 plan

**Context.** The plan originally specified an AWS CLI profile named `weysure-sso`. Adebayo
challenged it: *"what if I want to use it for another project? I'll have to create another
SSO?"* He was right, and the naming was wrong.

**Decision.** Name profiles `<organisation>-<permission-set>`. This one is **`beyric-admin`**.

**Why the original was wrong.** An SSO profile authenticates to an **AWS account** through a
**permission set**. It is not project-scoped. One profile serves every project in that account
— Weysure, Luran, and anything built later. Naming it after a project implies a profile per
project, which would be both redundant and misleading.

**Consequences.** A second AWS account becomes `<that-org>-admin`, and every command states
which account it touches. The `[sso-session]` block is reusable: one session per Identity
Center instance, with multiple `[profile]` blocks selecting different accounts and roles
beneath it — which is the actual scaling model, and the shape the config already has.

**Related, deferred.** The permission set in use is the AWS-managed `AdministratorAccess`
(`*:*`) with a 1-hour session duration. The session duration is the control that matters for
ADR-009 and it is correct. Narrowing the permissions themselves belongs to the Phase 10
least-privilege review, not here.

---

## ADR-017 — AWS credentials come from the environment; no `profile` in Terraform

**Date:** 2026-08-27 · **Status:** Accepted · **Refines** ADR-016

**Context.** The migrated configuration carried `profile = "personal"` from the original code.
Task 4 renamed it to `beyric-admin` in the backend and provider blocks, and review caught that
renaming it was solving the wrong problem.

**Decision.** No `profile` argument in any Terraform file. Credentials resolve through the
standard AWS credential chain.

**Why the rename was insufficient.** A hardcoded `profile` requires every machine that ever runs
the configuration to have a named profile spelled exactly that way in `~/.aws/config`. That is
true of one laptop and false of everything else:

| Where | How credentials arrive | Works with a hardcoded profile? |
|---|---|---|
| Laptop | `AWS_PROFILE=beyric-admin` + `aws sso login` | Yes |
| **Jenkins (Phase 6)** | **IRSA — ServiceAccount assumes an IAM role** | **No — there is no `~/.aws/config`** |
| Break-glass | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | No — the profile takes precedence |
| A second engineer | their own profile naming | Only if they match the name exactly |

**Consequences.** The configuration becomes identical in every context, and the credential chain
resolves each one. This is a precondition for ADR-005 — Jenkins holding no static credentials —
so the hardcode would have surfaced as a Phase 6 failure with a confusing error, months after it
was introduced.

The cost is one piece of required environment: `AWS_PROFILE` must be exported before
`terraform init`. Documented in `projects/weysure/terraform/README.md`. Forgetting it produces a
clear "no valid credential sources" error rather than silent misbehaviour, which is the right
failure mode.

**General principle.** Configuration should name *what* it needs, not *where a particular
machine keeps it*. A `profile` is a local lookup key, not a property of the infrastructure.

**Revisit if:** never — this is the standard pattern.

---

## ADR-018 — The cluster is named for the organisation, not the product

**Date:** 2026-09-02 · **Status:** Accepted · **Corrects** an error in ADR-006's implementation

**Context.** ADR-006 decided one cluster hosting multiple environments as namespaces. The
implementation named it `local.cluster_name = "${var.project}-${var.environment}"`, producing
**`weysure-prod`**. Adebayo caught the contradiction while asking whether a second product would
need its own Vault: if Luran shares this cluster, a cluster called `weysure-prod` is simply
wrong, and it is wrong in the same way the budget named `weysure-platform-monthly` was wrong
for an account-wide budget.

**Decision.** The cluster is **`beyric-prod`** — organisation plus environment. Products are
namespaces within it.

**Why this could not be deferred.** An EKS cluster cannot be renamed. The name is an identifier,
not an attribute: it appears in the cluster ARN, the OIDC issuer URL, every access entry, the
Karpenter `karpenter.sh/discovery` tags, the node group name, the KMS alias, the snapshot
bucket, and every IAM role. Changing it is destroy-and-recreate.

| | Now | After anything real depends on it |
|---|---|---|
| Cost | ~25 minutes; the cluster holds nothing | Migrate Vault data, re-issue certificates, rebuild CI, redeploy every workload |

This is the fourth instance of the same pattern in this build — the state bucket rename, the ECR
immutability flip, the database migration, and now this. Each was nearly free at the moment it
was noticed and would have become expensive the moment something real depended on it.
Infrastructure decisions have a cost curve that is flat and then vertical, and the inflection is
the arrival of real dependents.

**Alternatives.** A cluster per product (correct isolation, but +$73/month control plane each,
which the budget does not carry — and ADR-006 already rejected it). Keeping the name and sharing
anyway (free, and misleads every future reader — the "temporary" name nobody ever fixes).

**Consequences.** Everything derived from the cluster name changes with it, so the rename is
mechanical rather than fiddly. The Vault instance is destroyed and re-initialised, which
invalidates the recovery keys stored minutes earlier under
`platform/vault/recovery-keys` — that secret is overwritten after the rebuild.

Naming convention going forward, consistent with ADR-015 and ADR-016:

| Thing | Scope | Example |
|---|---|---|
| AWS account resources | organisation | `beyric-tfstate-767397877316` |
| SSO profile | account + permission set | `beyric-admin` |
| Cluster | organisation + environment | `beyric-prod` |
| Budget | account | `aws-account-total-monthly` |
| Namespace | product + environment | `weysure-prod`, `luran-prod` |
| Vault KV path | product | `secret/weysure/*`, `secret/luran/*` |

**Revisit if:** a product needs hard isolation that namespaces cannot provide — a compliance
boundary, or a noisy-neighbour problem quotas fail to contain.

---

## ADR-019 — ExternalSecrets use `dataFrom.extract`; one Vault path per consumer

**Date:** 2026-09-04 · **Status:** Accepted · **Proposed by:** Adebayo

**Context.** ExternalSecrets were written with `data[]`, enumerating each key and remapping
it (`secretKey: jenkins-admin-user ← property: admin_user`). Adebayo challenged this: a new
key in Vault requires a manifest edit before it is available, and the mapping is boilerplate
that exists only because the manifest was teaching Vault the chart's key names.

**Decision.** `dataFrom.extract` by default. Consumers reference Vault's key names directly.
Retroactively applied to the Cloudflare token (Phase 4) and used for all CI secrets (Phase 6).

**Why the pushback did not win, and what it bought.** Two objections were real and became
guardrails rather than reasons to refuse:

- `extract` is *allow-by-default* — every key at a path reaches every Secret reading it. The
  first draft of Phase 6 had two ExternalSecrets on `platform/jenkins`; under `extract` the
  webhook Secret would have carried the admin password. **Rule: one Vault path, one consumer.**
- Removal is *silent* — a deleted Vault key vanishes from the Secret without an error, and the
  pod fails on its next restart. Reloader restarts on change so it fails immediately; Phase 9
  alerts on `Ready=False`. **Rule: deleting a Vault key is a change to a running workload.**

The "no manifest edit" benefit is smaller than it first appears — a new key does nothing
until a consumer references it, and that reference is a manifest edit — except with
`envFrom`, where it is exactly as large as claimed. **Rule: `envFrom` only on app-owned paths.**

**Consequences.** Less boilerplate; the store stays chart-agnostic; the consumer adapts to the
store's naming, which is the right direction. In exchange, path scoping becomes a design
decision that has to be made deliberately, and the convention document carries the rules.

**Revisit if:** a path genuinely needs to serve multiple consumers with different subsets —
that is the `data[]` case, and it should be rare.
