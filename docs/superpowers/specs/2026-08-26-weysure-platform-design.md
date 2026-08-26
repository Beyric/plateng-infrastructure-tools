# Design Spec — Weysure Production Platform on AWS

| | |
|---|---|
| **Date** | 2026-08-26 |
| **Status** | Draft — awaiting review |
| **Stage** | `brainstorm` → **`spec`** → `plan` → `implement` |
| **Scope** | Greenfield production platform: AWS account → EKS → GitOps → CI → application delivery |
| **Architecture diagrams** | [`docs/architecture/ARCHITECTURE.md`](../../architecture/ARCHITECTURE.md) |
| **Build checklist** | [`docs/checklist/PLATFORM_BUILD_CHECKLIST.md`](../../checklist/PLATFORM_BUILD_CHECKLIST.md) |
| **Decision records** | [`memory/DECISIONS.md`](../../../memory/DECISIONS.md) |

---

## 1. Problem statement

Weysure is an escrow and wallet platform: a FastAPI backend (`innocent98/Weysure-API`) and a
Next.js frontend (`innocent98/Weysure`), currently running against a Supabase-hosted Postgres
in `eu-central-1`. There is **no deployed infrastructure** — no cluster, no CI, no CD, no
observability. Terraform exists locally but has never been applied and is not under version
control.

The goal is a **production-grade platform** on AWS: reproducible, observable, secure by
default, and deployable through GitOps — built in phases small enough to understand, verify,
and defend.

### Goals

- Every piece of infrastructure defined as code, reviewed through pull requests.
- Deployed state is a pure function of a git commit; rollback is `git revert`.
- No standing database password anywhere in the system.
- CI has zero cluster credentials.
- Observability sufficient to answer "is it healthy?" and "why did it break?" before launch.
- Each phase produces documentation, a diagram, and a rehearsed rollback.

### Non-goals (this spec)

- Application feature work, beyond removing dead Supabase code paths.
- Multi-region or multi-cluster topology.
- Service mesh (Linkerd) — deferred with a stated revisit trigger.
- SOC2 / PCI compliance programmes.

---

## 2. Current state assessment

All findings below were verified by direct inspection, not inferred. Evidence is cited so any
claim can be re-derived.

### AWS account

| Check | Result |
|---|---|
| EKS clusters | none |
| VPCs | default `172.31.0.0/16` only |
| Route 53 hosted zones | none |
| Terraform state bucket `victor-terraform-state-2026` | exists; **versioning enabled**, **public access fully blocked** |
| State key `weysure/infrastructure/` | empty — never applied |
| Identity | `arn:aws:iam::767397877316:user/s_user` (IAM **user**, static keys) |
| Account MFA | enabled, 6 devices |

The state backend is already correctly hardened.

### Local tooling

`aws 2.35.11`, `terraform 1.15.8`, `kubectl 1.36.3`, `helm 4.2.4`, `docker 29.1.3`,
`kubectx`, `kubens`, `k9s`, `jq`, `gh 2.93.0` — present. Missing: `argocd` CLI.

### Findings

| # | Severity | Finding | Evidence | Resolved in |
|---|---|---|---|---|
| ① | **Critical** | Plaintext database password in `terraform.tfvars` (`db_password = "<redacted>"`). Not yet leaked only because the directory is not a git repo. | `weysure-infrastructure/terraform.tfvars` | Phase 0 + 3 |
| ② | **Critical** | Infrastructure not under version control — no history, review, or rollback. | `git rev-parse` → *not a git repository* | Phase 0 |
| ③ | **Critical** | Terraform provisions RDS in `us-east-1` while the app runs on Supabase in `eu-central-1`. `apply` as written creates a second, empty, `deletion_protection = true` database. | `.env` `DATABASE_URL`, `modules/rds/main.tf` | Phase 3 |
| ④ | **High** | EKS module sets no `access_config` and declares no `aws_eks_access_entry`. Only the creating principal can reach the cluster. Classic lockout. | `modules/eks/main.tf` | Phase 1 |
| ⑤ | **High** | No EKS add-ons (`vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver`) and no `aws_iam_openid_connect_provider`. Without EBS CSI **no PersistentVolume will bind** — Prometheus, Grafana, Vault, Redis all fail. Without IRSA no pod can assume an AWS role. | `modules/eks/main.tf` | Phase 1 |
| ⑥ | Medium | Single NAT Gateway in `public[0]`, one private route table for both AZs. AZ-a failure removes egress for AZ-b nodes. | `modules/vpc/main.tf` | Accepted — Phase 10 |
| ⑦ | Medium | `Jenkinsfile` performs CD (`kubectl set image`, migration Jobs, `rollout undo`) and authenticates with long-lived AWS access keys. No Gitleaks or SonarQube stage. | `Weysure-API/Jenkinsfile` | Phase 6 |
| ⑧ | Medium | `Jenkinsfile` deploys `deployment/weysure-worker` — **there is no Celery in this project**. The real second process is `api_scheduler`. That stage fails every build. | `pyproject.toml`, `docker-compose.yaml` | Phase 6/7 |
| ⑨ | Medium | `boot/docker-run.sh` runs `alembic upgrade head` on every container start. With N replicas that is N concurrent migrations racing per rollout. | `boot/docker-run.sh` | Phase 7 |
| ⑩ | Low | Next.js has no Dockerfile and `next.config.ts` lacks `output: "standalone"`. | `Weysure/next.config.ts` | Phase 7 |
| ⑪ | Medium | ECR is `MUTABLE` and the pipeline pushes `:latest`. "We deployed v1.2.3" stops being verifiable; rollback becomes unreliable. | `main.tf`, `Jenkinsfile` | Phase 1 + 6 |
| ⑫ | Medium | No branch protection on any repository. In GitOps, `plateng-gitops` **is** production. | `gh api …/branches` | Phase 0 |
| ⑬ | *Resolved* | Default branches were inconsistent. Both `Weysure-API` and `Weysure` now default to `main`. | verified 2026-08-26 | — |
| ⑭ | **High** | AWS operated as an IAM user with static access keys. | `aws sts get-caller-identity` | Phase 0 |

### Supabase coupling — verified as data-only

The migration is a **pure data migration**. Authentication was already brought in-house:

- `app/db/models/user.py:50` — `hashed_password = Column(String, nullable=False)`
- `app/core/security.py:11` — `CryptContext(schemes=["bcrypt", "sha256_crypt"])`
- `app/core/security.py:30` — `jwt.encode(to_encode, settings.SECRET_KEY, …)`
- `app/api/v1/endpoints/auth.py:47` — `verify_password(user_in.password, user.hashed_password)`
- `grep 'from app.core.supabase'` → **0 files**; `app/core/supabase.py` is dead code
- 1 residual live call site: `app/api/v1/endpoints/admin.py:176`

No passwords are stranded in a managed `auth.users` schema, and no forced password reset is
required. This is the single largest risk factor that this project does **not** carry.

---

## 3. Decisions

Full rationale in [`memory/DECISIONS.md`](../../../memory/DECISIONS.md).

| ID | Decision |
|---|---|
| ADR-001 | Migrate the application database from Supabase to AWS RDS PostgreSQL |
| ADR-002 | All infrastructure in `us-east-1`, with CloudFront edge mitigation for West African latency |
| ADR-003 | Two managed node groups: `platform` (on-demand) and `workload` (spot) |
| ADR-004 | Defer Linkerd; defer Karpenter; single NAT Gateway; single-AZ RDS |
| ADR-005 | Four repositories; Jenkins is CI-only with zero cluster credentials |
| ADR-006 | One cluster, two namespaces (`weysure-stage`, `weysure-prod`) |
| ADR-007 | HashiCorp Vault OSS in-cluster with AWS KMS auto-unseal |
| ADR-008 | External Secrets Operator rather than Vault Secrets Operator |
| ADR-009 | IAM Identity Center (SSO) replaces static IAM user access keys |
| ADR-010 | RDS `manage_master_user_password = true` — master password never enters Terraform state |

---

## 4. Design

The three design sections are documented with diagrams in
[`ARCHITECTURE.md`](../../architecture/ARCHITECTURE.md). Summarised here.

### 4.1 Compute and network

Two managed node groups. `platform` runs on-demand and hosts anything stateful or
control-plane-like (Argo CD, Vault, Traefik, cert-manager, Jenkins controller). `workload`
runs spot and hosts stateless application replicas, Prometheus, Kyverno, and ephemeral CI
agents. Separation is enforced with node labels, `nodeAffinity`, taints and
`PodDisruptionBudget`s, plus the AWS Node Termination Handler for graceful spot drains.

Instance family is `m6i`, **not `t3`**. Burstable instances throttle to a fraction of a vCPU
once credits are exhausted; Prometheus scraping and CI builds exhaust them reliably, and the
resulting slowdown presents as a mystery rather than an error.

#### Capacity analysis

The originally configured `2 × t3.medium` provides roughly **3.5 vCPU / 6.4 GiB allocatable**.
The platform stack requires approximately **4.5–6 vCPU and 13–17 GiB** of *requests*. Pods
would sit `Pending` on `Insufficient memory`. Note that the Kubernetes scheduler places pods
by **requests**, not observed usage — a cluster can idle at 15% real CPU and still refuse to
schedule.

Roughly 70% of that footprint is platform rather than product. That ratio is normal for a
small platform and is the honest input to "should we run Kubernetes at all?"

#### Cost model — approximately $244/month

| Item | Choice | $/mo |
|---|---|---|
| EKS control plane | fixed, unavoidable | 73 |
| `platform` node group | 1 × m6i.large on-demand | 70 |
| `workload` node group | 1 × m6i.large spot (max 3) | 22 |
| NAT Gateway | 1, single AZ | 33 |
| S3 Gateway VPC Endpoint | **free** — removes NAT charges on image pulls | 0 |
| Network Load Balancer | 1, for Traefik | 18 |
| RDS `db.t4g.micro` + 20 GB gp3 | single-AZ | 14 |
| EBS volumes (PVs) | ~40 GB gp3 | 4 |
| ECR + Route 53 + data transfer | | ~10 |
| **Total** | | **≈ 244** |

Prices are `us-east-1` on-demand and must be re-verified at apply time.

### 4.2 Repositories and GitOps

Four repositories, with one invariant: **the repo Argo CD watches is never the repo
developers push application code to.** Jenkins' entire relationship with the cluster is a
single git commit into `plateng-gitops`. It holds no kubeconfig and no AWS access keys —
ECR push authenticates through IRSA.

| Repository | Role |
|---|---|
| `innocent98/Weysure-API` | Application source, Dockerfile, Jenkinsfile |
| `innocent98/Weysure` | Application source, Dockerfile, Jenkinsfile |
| `Beyric/plateng-infrastructure-tools` | Terraform — AWS resources. **Not** watched by Argo CD |
| `Beyric/plateng-gitops` | Kubernetes desired state. Argo CD watches only this |

Both platform repos are scoped for multiple projects (`projects/weysure/`) so a second
product does not require restructuring.

Environments are namespaces within one cluster: `weysure-stage` and `weysure-prod`, plus
platform namespaces. Isolation is provided by `ResourceQuota`, default-deny `NetworkPolicy`,
separate Argo CD projects with distinct RBAC, and stricter Kyverno policies for prod.

### 4.3 Identity and secrets

Identity is designed **before** secrets, in four layers: human→AWS via SSO with 1-hour
sessions; human→cluster via declared `aws_eks_access_entry`; pod→AWS via IRSA with one
least-privilege role per ServiceAccount; pod→Vault via the Kubernetes auth method.

Application pods hold **no AWS identity at all** — they obtain database credentials from
Vault, so there is nothing for them to assume.

Vault runs in-cluster on Raft storage with **AWS KMS auto-unseal**. Auto-unseal is not
optional: without it, every pod restart requires a human to enter Shamir key shares, which is
the leading cause of self-hosted Vault outages.

Finding ① is resolved twice over. First, `manage_master_user_password = true` means RDS
generates the master password into AWS Secrets Manager and **Terraform never sees it** — it is
not in state, tfvars, or git. Second, Vault's database secrets engine issues **1-hour Postgres
users** to the application, so there is no standing application password to leak or rotate.

Two manual bootstrap gates are accepted and documented: Argo CD's initial git credential
(rotated once Vault is live) and Vault's one-time initialisation (recovery keys to AWS
Secrets Manager; root token revoked immediately).

---

## 5. Phase plan

Each phase is its own `brainstorm → plan → spec → implement` cycle, and each produces: a
target-state diagram update, a Well-Architected delta, a runbook where relevant, an SOP on
completion, and a rehearsed rollback.

| # | Phase | Exit criteria | Spend |
|---|---|---|---|
| **0** | **Foundations & guardrails** | Both platform repos initialised with branch protection; Terraform migrated into `plateng-infrastructure-tools`; secrets purged; Gitleaks pre-commit active; IAM Identity Center live and `s_user` keys deleted; remote state verified | **$0** |
| **1** | **Network & cluster** | VPC applied; EKS 1.31 reachable; **add-ons installed, IRSA provider created, access entries declared**; `kubectl get nodes` returns Ready nodes from a second identity | first spend |
| **2** | **Cluster baseline** | StorageClass binds a test PVC; metrics-server serving; Traefik reachable via NLB; cert-manager issuing a real Let's Encrypt cert; external-dns writing Route 53 records | + LB |
| **3** | **Data layer** | RDS applied with managed master password; Supabase→RDS migration **rehearsed**, verified, and cut over; Redis running; **restore drill completed** | + DB |
| **4** | **Secrets** | Vault initialised with KMS auto-unseal; policies and Kubernetes auth configured; database engine issuing 1-hour credentials; ESO syncing; Reloader restarting on change; Raft snapshots to S3 | — |
| **5** | **GitOps** | Argo CD self-managing; app-of-apps reconciling all platform components; drift detection alerting; `git revert` rollback demonstrated | — |
| **6** | **CI** | Jenkins on ephemeral agents; Gitleaks, SonarQube, tests, Trivy all gating; image pushed via IRSA; tag commit to `plateng-gitops`; **no cluster credentials anywhere** | — |
| **7** | **Application delivery** | Helm charts for API and web; probes, HPA, PDB, resource limits; migrations as an Argo CD PreSync hook (Finding ⑨); frontend Dockerfile with `output: "standalone"` | — |
| **8** | **Policy** | Kyverno enforcing baseline policies; default-deny NetworkPolicies; ResourceQuota per namespace | — |
| **9** | **Observability** | Prometheus, Grafana, Alertmanager, Blackbox; RED/USE dashboards; alerts routed and **tested by inducing failure** | — |
| **10** | **Production readiness** | DR drill; runbooks complete; SLOs defined; load test; cost review (Karpenter, NAT instance, Graviton) | — |

Two orderings are deliberate and counter-intuitive:

- **Secrets (4) before GitOps (5).** If Argo CD arrives first, a Kubernetes Secret will be
  committed to git to get something working, and it will stay there. Vault first makes the
  wrong thing impossible.
- **GitOps (5) before CI (6).** Jenkins' job is to produce an artifact and update a git
  reference. Built first, it grows `kubectl` calls — exactly as the current `Jenkinsfile` did.

---

## 6. AWS Well-Architected review

The framework has **six** pillars: the original five plus **Sustainability**, added in
December 2021.

| Pillar | Addressed by | Accepted gaps |
|---|---|---|
| **Operational Excellence** | IaC throughout; GitOps with git-as-audit-log; ADRs; runbooks per phase; SOPs on completion | Observability not present until Phase 9 |
| **Security** | Nodes in private subnets only; RDS not publicly accessible; encryption at rest; SSO with 1-hour sessions; IRSA least privilege; **no standing DB password**; CI holds no cluster credentials; Gitleaks + Trivy + SonarQube gating; Kyverno; default-deny NetworkPolicy | Two documented manual bootstrap secrets |
| **Reliability** | Subnets across 2 AZs; managed node group self-healing; on-demand baseline for stateful workloads; PDBs; RDS PITR with **rehearsed** restore; Vault Raft snapshots | **Single NAT Gateway (egress SPOF)**; single-AZ RDS; one cluster for both environments; single-replica Vault |
| **Performance Efficiency** | Non-burstable `m6i` over `t3`; Redis for hot reads; CloudFront edge termination; HPA; capacity modelled against actual requests | Load testing deferred to Phase 10 |
| **Cost Optimization** | Spot for elastic workloads; free S3 gateway endpoint; scale-to-zero CI agents; Linkerd deferred; cost modelled before build | Karpenter, NAT instance, Graviton deferred to Phase 10 |
| **Sustainability** | Spot consumes otherwise-idle capacity; right-sizing over over-provisioning; scale-to-zero CI | Graviton (~60% less energy per unit work) deferred |

The Reliability row names three structural weaknesses. That is intentional: a
Well-Architected review that finds nothing is a review that was not performed.

---

## 7. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Database migration data loss | Low | **Severe** — escrow balances | Rehearse before executing; row-count and checksum verification; Supabase retained read-only for rollback |
| EKS lockout on first apply | Medium | High | Access entries declared in Terraform; verified from a second identity before proceeding |
| Cost overrun | Medium | Medium | Budget alarms in Phase 0; cost reviewed at each phase gate |
| Spot reclaim during a deploy | Medium | Low | On-demand baseline for stateful; PDBs; Node Termination Handler |
| Vault initialisation mishandled | Low | **Severe** — unrecoverable secrets | Runbook; recovery keys to AWS Secrets Manager immediately; root token revoked |
| Stage incident affecting prod | Medium | High | ResourceQuota, NetworkPolicy, separate Argo CD projects; revisit trigger recorded |

---

## 8. Open questions

| # | Question | Blocks |
|---|---|---|
| 1 | Which domain name will the platform use, and where is it registered? No Route 53 hosted zone exists. | Phase 2 |
| 2 | Does the platform currently serve live users and real money, or is this a pre-launch cutover? Changes the migration window and rollback posture. | Phase 3 |
| 3 | Is SonarQube self-hosted in-cluster (adds ~1 vCPU / 2 GiB and a database) or SonarCloud (SaaS, free for private repos on a limited tier)? Materially affects Phase 6 capacity. | Phase 6 |
