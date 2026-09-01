# Weysure Platform — Master Build Checklist

> **Single source of truth for the whole build.** Updated as part of the work, never
> afterwards. An item is checked only when it is done **and verified**.
>
> **Last reconciled:** 2026-08-26 (revised: Karpenter, Cloudflare, SonarQube)
>
> **Presentable version:** [Weysure Platform Blueprint](https://claude.ai/code/artifact/41d69692-4940-4751-8a21-0e46c8ba1bae)

## Snapshot

| Status | Count |
|---|---|
| ✅ Complete | 3 / 11 phases — 0, 1, 2 |
| 🔵 In progress | 1 — Phase 0 (design approved, not started) |
| ❓ Blocking questions | **0** — all three resolved |
| ⚪ Planned | 10 |
| 💰 Current AWS spend | **~$178/mo** — cluster live |
| 📐 Projected steady-state | **$240–270/mo** |
| 📊 Diagrams | 10, all render-verified with `mmdc` |

**Legend:** ⚪ planned · 🔵 in progress · ✅ complete · ⚠ blocked · ⏸ deferred

**Stage discipline:** every phase runs `brainstorm → plan → spec → implement`. No `terraform
apply`, no cluster mutation, and no production deploy without explicit approval.

---

## Phase 0 — Foundations & guardrails 🔵

*Exit criteria: repos governed, secrets purged, SSO live, $0 spent.*

- [ ] **Repository hygiene**
  - [x] `Beyric/plateng-infrastructure-tools` created
  - [x] `Beyric/plateng-gitops` created
  - [x] Design spec, architecture diagrams, ADRs, and this checklist committed
  - [x] `.gitignore` covering `*.tfvars`, `*.tfstate*`, `.terraform/`, `.env*`, `*.pem`
  - [x] Initialise `plateng-gitops` with its directory skeleton
  - [x] Branch protection on all four repos — require PR review, block force-push *(Finding ⑫)*
  - [x] `CODEOWNERS` on both platform repos
- [ ] **Secret hygiene** *(Finding ①)*
  - [x] Remove `db_password` from `terraform.tfvars` before any commit
  - [x] Gitleaks pre-commit hook installed locally
  - [x] Gitleaks scan across all four repos, including full history
- [ ] **Terraform migration** *(Finding ②)*
  - [x] Move `~/Documents/plateng-infra/weysure-infrastructure` into `projects/weysure/`
  - [x] Extract shared modules to `modules/`
  - [x] `terraform fmt` + `terraform validate` clean
  - [ ] `tflint` and `checkov` (or `tfsec`) baseline recorded
- [ ] **AWS identity** *(Finding ⑭ / ADR-009)*
  - [x] Enable IAM Identity Center
  - [ ] Create `PlatformAdmin` permission set; assign to engineer
  - [x] Configure `aws sso` profile; verify `aws sts get-caller-identity`
  - [ ] Point Terraform backend + provider at the assumed role
  - [ ] **Delete `s_user` static access keys** once verified
- [ ] **Cost guardrails**
  - [x] AWS Budget at $250/mo with alerts at 50 / 80 / 100%
  - [ ] Cost Explorer enabled; tagging convention agreed
- [ ] **State backend**
  - [x] Bucket `beyric-tfstate-767397877316` — versioning ✅, public access blocked ✅
  - [ ] Confirm `use_lockfile` behaviour on Terraform 1.15
  - [ ] Restrict bucket policy to the `PlatformAdmin` role
- [ ] SOP written · diagram updated · Well-Architected delta recorded

## Phase 1 — Network & cluster ⚪

*Exit criteria: `kubectl get nodes` returns Ready nodes, from a second identity.*

- [ ] VPC module reviewed; subnet tags verified for ELB discovery
- [ ] `terraform plan` reviewed **line by line** before any apply
- [ ] EKS cluster 1.31 applied
- [ ] `access_config { authentication_mode = "API_AND_CONFIG_MAP" }` *(Finding ④)*
- [ ] `aws_eks_access_entry` for `PlatformAdmin` + a read-only role
- [ ] **Verify cluster access from a second identity before proceeding**
- [ ] EKS add-ons: `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver` *(Finding ⑤)*
- [ ] `aws_iam_openid_connect_provider` — IRSA foundation *(Finding ⑤)*
- [ ] Node group `system` — 1–2 × m6i.large ON_DEMAND, labelled + tainted
- [x] **Karpenter** installed *(ADR-012)*
  - [ ] IRSA role + node instance profile
  - [ ] SQS interruption queue + EventBridge rules (replaces Node Termination Handler)
  - [ ] `EC2NodeClass` — AMI family, subnet + security-group selectors, **userData setting `vm.max_map_count = 262144`** for SonarQube *(ADR-013)*
  - [ ] `NodePool` — spot-first, families `m6i m7i m6a m5 c6i r6i`, consolidation enabled, disruption budget
  - [x] **Verify:** a test deployment provisions a node, then consolidates away on delete
- [ ] ECR set to `IMMUTABLE`; lifecycle policy *(Finding ⑪)*
- [ ] S3 Gateway VPC Endpoint
- [ ] `kubectx` / `kubens` contexts configured; k9s verified
- [ ] SOP · diagram · Well-Architected delta · **rollback plan rehearsed**

## Phase 2 — GitOps bootstrap ⚪

- [x] `gp3` StorageClass as default; **test PVC binds**
- [x] metrics-server
- [ ] `plateng-gitops` skeleton: `bootstrap/`, `platform/`, `projects/weysure/`
- [x] Argo CD installed (documented manual bootstrap) and **self-managing**
- [x] App-of-apps root reconciling all platform components
- [ ] Argo CD projects + RBAC separating stage and prod
- [ ] Drift detection set to **alert, not auto-heal** initially
- [ ] **`git revert` rollback demonstrated end to end**
- [ ] `argocd` CLI installed locally
- [ ] SOP · runbook `ARGOCD_FAILURE.md` · workflow `GITOPS_WORKFLOW.md` · diagram

## Phase 3 — Secrets ⚪

*Exit criteria: application authenticates to Postgres with 1-hour Vault-issued credentials.*

- [ ] KMS key for auto-unseal; IRSA role for the Vault ServiceAccount
- [ ] Vault deployed (Raft, single replica)
- [ ] **Initialise once**; recovery keys → AWS Secrets Manager; **root token revoked**
- [ ] Break-glass admin created and tested
- [ ] Kubernetes auth method; least-privilege policies
- [ ] KV v2 populated with static application secrets
- [ ] **Database secrets engine** issuing 1-hour Postgres users
- [ ] External Secrets Operator + `SecretStore` + `ExternalSecret`s
- [ ] Reloader; **verified by rotating a secret and observing the restart**
- [ ] Raft snapshot CronJob → S3 via IRSA
- [ ] **Snapshot restore drill**
- [ ] Argo CD bootstrap git credential rotated
- [ ] Config/secret split: non-secret `.env` keys → ConfigMap in git
- [ ] SOP · runbooks `VAULT_FAILURE.md`, `SECRETS_ROTATION.md` · diagram

## Phase 4 — Ingress & TLS ⚪

*Exit criteria: a real HTTPS URL serves a test workload.*

- [ ] **Cloudflare zone for `beyrictech.com`**; delegate nameservers from Namecheap *(ADR-011)*
- [ ] Cloudflare API token (scoped: Zone.DNS edit only) read **from Vault** via ExternalSecret — no hand-created Secret
- [ ] Traefik via Helm, behind an NLB
- [ ] **NLB security group restricted to Cloudflare published IP ranges**
- [ ] Traefik configured to honour `CF-Connecting-IP` (else rate limiting sees one address)
- [ ] cert-manager + `ClusterIssuer` — Let's Encrypt, **DNS-01 via Cloudflare**
- [ ] **Staging issuer first** — Let's Encrypt production has hard rate limits
- [ ] external-dns with the **Cloudflare provider**
- [ ] Cloudflare TLS mode set to **Full (strict)** — never Flexible
- [ ] DNS records: `weysure`, `weysure-api`, `weysure-stage`, `weysure-api-stage`
- [ ] End-to-end: test workload reachable over HTTPS with a valid certificate
- [ ] SOP · diagram · Well-Architected delta

## Phase 5 — Data layer ⚪

*Exit criteria: application runs on RDS; restore drill completed.*

> **The Supabase database is empty / throwaway** (ADR-001 amendment). There is nothing to migrate — the 47
> Alembic revisions build the schema from scratch, which is the same path every fresh dev
> environment already exercises. No dump, no cutover window, no rollback window.

- [ ] RDS with `manage_master_user_password = true` *(ADR-010)*
- [ ] Automated backups, PITR, 7-day retention
- [ ] Redis deployed with a PVC
- [ ] **Schema build** — `alembic upgrade head` against the empty RDS instance (47 revisions)
- [ ] Verify every table, index and constraint the models expect actually exists
- [ ] `DATABASE_URL` pointed at RDS, credentials issued by Vault *(ADR-007)*
- [ ] Application smoke test against RDS
- [ ] **Restore drill from PITR — timed, RTO recorded**
- [ ] Supabase project decommissioned once RDS is observed healthy
- [ ] Backend cleanup: delete dead Supabase code paths, drop `supabase==2.15.2`
- [ ] SOP · runbook `DATABASE_RECOVERY.md` · diagram · Well-Architected delta

## Phase 6 — CI ⚪

- [ ] Jenkins controller on the `platform` node group; ephemeral agents on spot
- [ ] IRSA role for ECR push — **no AWS access keys anywhere** *(Finding ⑦)*
- [ ] GitHub App (scoped) for the GitOps tag commit
- [ ] Gitleaks stage *(Finding ⑦)*
- [ ] **SonarQube self-hosted** *(ADR-013)*
  - [ ] In-cluster PostgreSQL + PVC
  - [ ] PVCs for SonarQube data and extensions
  - [ ] **`vm.max_map_count = 262144` confirmed on the host** — SonarQube crash-loops without it
  - [ ] File-descriptor limit raised (`nofile` ≈ 131072)
  - [ ] Quality gate wired into the pipeline as a blocking stage
- [ ] Test stage with coverage reporting
- [ ] Trivy image scan stage
- [ ] Build tagged by **git SHA only** — never `:latest` *(Finding ⑪)*
- [ ] **Remove the non-existent `weysure-worker` stage** *(Finding ⑧)*
- [ ] **Remove all `kubectl` usage from the Jenkinsfile** *(Finding ⑦)*
- [ ] Frontend pipeline
- [ ] SOP · runbooks · workflow `CI_CD_WORKFLOW.md` · diagram

## Phase 7 — Application delivery ⚪

- [ ] Helm chart for `weysure-api`
- [ ] Frontend Dockerfile + `output: "standalone"` *(Finding ⑩)*
- [ ] Helm chart for `weysure-web`
- [ ] Liveness / readiness / startup probes
- [ ] Resource requests and limits from measured usage
- [ ] HPA and PodDisruptionBudget
- [ ] **Migrations as an Argo CD PreSync hook; removed from container start** *(Finding ⑨)*
- [ ] `api_scheduler` deployed as a single-replica Deployment
- [ ] Stage deploy verified, then prod
- [ ] SOP · runbooks `PROD_RELEASE.md`, `DEPLOYMENT_ROLLBACK.md` · diagram

## Phase 8 — Policy ⚪

- [ ] Kyverno installed; **audit mode before enforce**
- [ ] Baseline policies: no `:latest`, require limits, non-root, read-only rootfs, drop caps
- [ ] Default-deny NetworkPolicies per namespace
- [ ] ResourceQuota + LimitRange per namespace
- [ ] Policy exceptions documented with rationale
- [ ] SOP · diagram · Well-Architected delta

## Phase 9 — Observability ⚪

- [ ] kube-prometheus-stack with persistent storage
- [ ] Grafana with IRSA + persistent dashboards
- [ ] Alertmanager routing (email / Slack)
- [ ] Blackbox exporter probing public endpoints
- [ ] FastAPI `/metrics` instrumentation
- [ ] RED dashboards (app) + USE dashboards (nodes)
- [ ] Alert rules: pod crashloop, node pressure, certificate expiry, RDS storage, Vault sealed, Argo CD out-of-sync
- [ ] **Alerts tested by inducing real failures**
- [ ] Log aggregation decision + implementation
- [ ] SOP · runbooks `INCIDENT_RESPONSE.md`, `ONCALL.md` · diagram

## Phase 10 — Production readiness ⚪

- [ ] Full DR drill: rebuild from Terraform + restore data, timed
- [ ] SLOs and error budgets defined
- [ ] Load test; capacity re-derived from real numbers
- [ ] **Cost review:** Karpenter · NAT instance · Graviton · reserved capacity
- [ ] Reliability review: multi-AZ NAT, multi-AZ RDS, 3-replica Vault, second cluster
- [ ] Security review: full Well-Architected pass
- [ ] Runbook completeness audit
- [ ] Linkerd evaluation *(ADR-004)*
- [ ] SOP · final architecture diagram · complete Well-Architected review

---

## Backlog — identified, not yet scheduled

- [x] ~~CloudFront distributions~~ — superseded by Cloudflare free edge *(ADR-011)*
- [x] ~~WAF~~ — included in the Cloudflare free plan *(ADR-011)*
- [ ] Multi-arch (ARM64) image builds, prerequisite for Graviton
- [ ] Renovate / Dependabot for dependency and chart updates
- [ ] Terraform Cloud or Atlantis for plan-on-PR
- [ ] Secrets rotation schedule and automation
- [ ] Chaos experiments (node kill, AZ isolation)

## Deferred follow-ups — known, non-blocking

| Item | Why deferred | Revisit trigger | ADR |
|---|---|---|---|
| Linkerd service mesh | ~40% of the on-demand node in sidecar overhead | Node capacity increase | ADR-004 |
| Multi-AZ NAT Gateway | +$33/mo | Budget increase or first AZ incident | ADR-004 |
| Multi-AZ RDS | Doubles instance cost | First paying-customer SLA | ADR-004 |
| Separate prod cluster | +$73/mo + nodes | Stage causes a prod incident | ADR-006 |
| 3-replica Vault HA | Node capacity | Node capacity increase | ADR-007 |
| EKS Pod Identity (over IRSA) | Helm chart support still favours IRSA | Ecosystem maturity | — |

## Resolved questions

| # | Question | Answer |
|---|---|---|
| 1 | Domain and DNS | `beyrictech.com` · Namecheap registrar · **Cloudflare DNS** · `weysure.` and `weysure-api.` *(ADR-011)* |
| 2 | Live users / real money | **No** — pre-launch. Migration risk drops from severe to low |
| 3 | SonarQube | **Self-hosted in-cluster** with its own PostgreSQL *(ADR-013)* |

**Open questions: none currently blocking.**
