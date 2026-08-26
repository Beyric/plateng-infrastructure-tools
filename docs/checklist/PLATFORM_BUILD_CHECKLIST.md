# Weysure Platform — Master Build Checklist

> **Single source of truth for the whole build.** Updated as part of the work, never
> afterwards. An item is checked only when it is done **and verified**.
>
> **Last reconciled:** 2026-08-26

## Snapshot

| Status | Count |
|---|---|
| ✅ Complete | 0 / 11 phases |
| 🔵 In progress | 1 — Phase 0 (design approved, not started) |
| ⚪ Planned | 10 |
| 💰 Current AWS spend | **$0** — nothing applied |

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
  - [ ] `.gitignore` covering `*.tfvars`, `*.tfstate*`, `.terraform/`, `.env*`, `*.pem`
  - [ ] Initialise `plateng-gitops` with its directory skeleton
  - [ ] Branch protection on all four repos — require PR review, block force-push *(Finding ⑫)*
  - [ ] `CODEOWNERS` on both platform repos
- [ ] **Secret hygiene** *(Finding ①)*
  - [ ] Remove `db_password` from `terraform.tfvars` before any commit
  - [ ] Gitleaks pre-commit hook installed locally
  - [ ] Gitleaks scan across all four repos, including full history
- [ ] **Terraform migration** *(Finding ②)*
  - [ ] Move `~/Documents/plateng-infra/weysure-infrastructure` into `projects/weysure/`
  - [ ] Extract shared modules to `modules/`
  - [ ] `terraform fmt` + `terraform validate` clean
  - [ ] `tflint` and `checkov` (or `tfsec`) baseline recorded
- [ ] **AWS identity** *(Finding ⑭ / ADR-009)*
  - [ ] Enable IAM Identity Center
  - [ ] Create `PlatformAdmin` permission set; assign to engineer
  - [ ] Configure `aws sso` profile; verify `aws sts get-caller-identity`
  - [ ] Point Terraform backend + provider at the assumed role
  - [ ] **Delete `s_user` static access keys** once verified
- [ ] **Cost guardrails**
  - [ ] AWS Budget at $250/mo with alerts at 50 / 80 / 100%
  - [ ] Cost Explorer enabled; tagging convention agreed
- [ ] **State backend**
  - [x] Bucket `victor-terraform-state-2026` — versioning ✅, public access blocked ✅
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
- [ ] Node group `platform` — 1 × m6i.large ON_DEMAND, labelled + tainted
- [ ] Node group `workload` — 1–3 × m6i.large SPOT, labelled + tainted
- [ ] AWS Node Termination Handler
- [ ] Cluster Autoscaler with IRSA
- [ ] ECR set to `IMMUTABLE`; lifecycle policy *(Finding ⑪)*
- [ ] S3 Gateway VPC Endpoint
- [ ] `kubectx` / `kubens` contexts configured; k9s verified
- [ ] SOP · diagram · Well-Architected delta · **rollback plan rehearsed**

## Phase 2 — Cluster baseline ⚪

*Exit criteria: a real HTTPS URL serves a test workload.*

- [ ] `gp3` StorageClass as default; **test PVC binds**
- [ ] metrics-server
- [ ] Domain registered / delegated; Route 53 hosted zone *(Open question 1)*
- [ ] Traefik via Helm, behind an NLB
- [ ] cert-manager + `ClusterIssuer` (Let's Encrypt, DNS-01 via IRSA)
- [ ] **Staging issuer first** — Let's Encrypt production has hard rate limits
- [ ] external-dns with IRSA
- [ ] End-to-end: test workload reachable over HTTPS with a valid certificate
- [ ] SOP · diagram · Well-Architected delta

## Phase 3 — Data layer ⚪

*Exit criteria: application runs on RDS; restore drill completed.*

- [ ] RDS with `manage_master_user_password = true` *(ADR-010)*
- [ ] Automated backups, PITR, 7-day retention
- [ ] Redis deployed with a PVC
- [ ] **Migration rehearsal** — dump, restore, verify against a non-prod target
- [ ] Row-count and checksum verification per table
- [ ] Alembic head parity confirmed against the live database
- [ ] Maintenance window agreed; write freeze procedure documented
- [ ] Cutover executed; `DATABASE_URL` flipped
- [ ] Supabase retained **read-only** for rollback
- [ ] **Restore drill from PITR — timed, RTO recorded**
- [ ] Backend cleanup: delete dead Supabase code paths, drop `supabase==2.15.2`
- [ ] SOP · runbook `DATABASE_RECOVERY.md` · diagram · Well-Architected delta

## Phase 4 — Secrets ⚪

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

## Phase 5 — GitOps ⚪

- [ ] `plateng-gitops` skeleton: `bootstrap/`, `platform/`, `projects/weysure/`
- [ ] Argo CD installed (documented manual bootstrap) and **self-managing**
- [ ] App-of-apps root reconciling all platform components
- [ ] Argo CD projects + RBAC separating stage and prod
- [ ] Drift detection set to **alert, not auto-heal** initially
- [ ] **`git revert` rollback demonstrated end to end**
- [ ] `argocd` CLI installed locally
- [ ] SOP · runbook `ARGOCD_FAILURE.md` · workflow `GITOPS_WORKFLOW.md` · diagram

## Phase 6 — CI ⚪

- [ ] Jenkins controller on the `platform` node group; ephemeral agents on spot
- [ ] IRSA role for ECR push — **no AWS access keys anywhere** *(Finding ⑦)*
- [ ] GitHub App (scoped) for the GitOps tag commit
- [ ] Gitleaks stage *(Finding ⑦)*
- [ ] SonarQube stage + quality gate *(Open question 3)*
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

- [ ] CloudFront distributions for frontend and API *(ADR-002 latency mitigation)*
- [ ] WAF in front of CloudFront
- [ ] Multi-arch (ARM64) image builds, prerequisite for Graviton
- [ ] Renovate / Dependabot for dependency and chart updates
- [ ] Terraform Cloud or Atlantis for plan-on-PR
- [ ] Secrets rotation schedule and automation
- [ ] Chaos experiments (node kill, AZ isolation)

## Deferred follow-ups — known, non-blocking

| Item | Why deferred | Revisit trigger | ADR |
|---|---|---|---|
| Linkerd service mesh | ~40% of the on-demand node in sidecar overhead | Node capacity increase | ADR-004 |
| Karpenter | Learn node groups first | Phase 10 cost review | ADR-003 |
| Multi-AZ NAT Gateway | +$33/mo | Budget increase or first AZ incident | ADR-004 |
| Multi-AZ RDS | Doubles instance cost | First paying-customer SLA | ADR-004 |
| Separate prod cluster | +$73/mo + nodes | Stage causes a prod incident | ADR-006 |
| 3-replica Vault HA | Node capacity | Node capacity increase | ADR-007 |
| EKS Pod Identity (over IRSA) | Helm chart support still favours IRSA | Ecosystem maturity | — |

## Open questions — blocking

| # | Question | Blocks |
|---|---|---|
| 1 | Which domain, and where is it registered? No Route 53 zone exists. | Phase 2 |
| 2 | Live users and real money today, or pre-launch? Changes migration window and rollback posture. | Phase 3 |
| 3 | SonarQube self-hosted (~1 vCPU / 2 GiB + a database) or SonarCloud SaaS? | Phase 6 |
