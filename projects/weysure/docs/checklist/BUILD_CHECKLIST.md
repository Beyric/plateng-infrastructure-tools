# Weysure Platform — Master Build Checklist

> **Single source of truth for the whole build.** Updated as part of the work, never
> afterwards. An item is checked only when it is done **and verified**.
>
> **Last reconciled:** 2026-09-09 (Phase 6 complete)
>
> **Presentable version:** [Weysure Platform Blueprint](https://claude.ai/code/artifact/41d69692-4940-4751-8a21-0e46c8ba1bae)

## Snapshot

| Status | Count |
|---|---|
| ✅ Complete | 7 / 11 phases — 0, 1, 2, 3, 4, 6, 7 · Phase 5 core done, restore drill deferred to 10 |
| 🔵 In progress | 1 — Phase 8 (everything shipped; Kyverno Enforce on 2026-09-23 closes it) |
| ❓ Blocking questions | **0** — all three resolved |
| ⚪ Planned | 10 |
| 💰 Current AWS spend | **~$385/mo run-rate** ($12.5–13.8/day, 2026-09-18) — was ~$750/mo on extended support; Graviton and the legacy NLB removal are in; Savings Plan is the next lever |
| 📐 Projected steady-state | **$300–320/mo** floor for this architecture (2 on-demand system nodes, NAT, RDS); ~$270 with a Savings Plan |
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
  - [x] Move `~/Documents/beyric/projects/plateng-infra/weysure-infrastructure` into `projects/weysure/`
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

- [x] RDS with `manage_master_user_password = true` *(ADR-010)*
- [x] Automated backups, PITR, 7-day retention
- [x] Redis deployed with a PVC
- [ ] **Schema build** — `alembic upgrade head` against the empty RDS instance (47 revisions)
- [ ] Verify every table, index and constraint the models expect actually exists
- [ ] `DATABASE_URL` pointed at RDS, credentials issued by Vault *(ADR-007)*
- [ ] Application smoke test against RDS
- [ ] **Restore drill from PITR — timed, RTO recorded**
- [ ] Supabase project decommissioned once RDS is observed healthy
- [ ] Backend cleanup: delete dead Supabase code paths, drop `supabase==2.15.2`
- [ ] SOP · runbook `DATABASE_RECOVERY.md` · diagram · Well-Architected delta

## Phase 6 — CI ✅ *(2026-09-09 · [SOP](../sop/2026-09-09-phase-6-ci.md))*

- [x] Jenkins controller on the system node group; ephemeral agents on spot *(gitops #11)*
- [x] Pod identity for ECR push — **no AWS access keys anywhere** *(Finding ⑦, infra `ci.tf`)*
- [x] GitHub App (scoped) for the GitOps tag commit *(ADR-020, Finding ㉗)*
- [x] Gitleaks stage *(Finding ⑦)* — first runs found 46 + 28 issues; hygiene PRs API #6, web #2
- [x] **SonarQube self-hosted** *(ADR-013)*
  - [x] In-cluster PostgreSQL + PVC
  - [x] PVCs for SonarQube data and extensions
  - [x] `vm.max_map_count` / `nofile` — set by the chart's init container on the node
  - [x] Quality gate wired into the pipeline as a blocking stage *(gitops #12 for the token)*
- [x] Test stage — pytest against Postgres 16 + Redis 8.2 sidecars, junit *(API #8, #9; gitops #13)*
  - [ ] Coverage reporting → Phase 7
- [x] Trivy image scan stage — CRITICAL, `--ignore-unfixed`; three real CVEs caught *(web #4, #6; API #10)*
- [x] Build tagged by **git SHA only** — never `:latest` *(Finding ⑪)*
- [x] **Removed the non-existent `weysure-worker` stage** *(Finding ⑧)*
- [x] **No `kubectl` in either Jenkinsfile** *(Finding ⑦)*
- [x] Frontend pipeline *(web #1)*
- [x] Promote → `images.yaml` on gitops `main`: `ca1f4d9` (api), `b62ccd9` (web) by `beyric-ci[bot]`
- [x] SOP · Findings ㉕–㉚ · ADR-020
- [ ] runbook `GITHUB_ACTIONS_FAILURE.md` → renamed `JENKINS_FAILURE.md`, Phase 10 · workflow `CI_CD_WORKFLOW.md` · diagram

## Phase 7 — Application delivery ✅ *(2026-09-13 · [SOP](../sop/2026-09-14-phase-7-app-delivery.md))*

- [x] Library chart `beyric-app` for every Beyric service; `weysure-api` and `weysure-web` are values files *(ADR spec D1; gitops #14)*
- [x] Frontend Dockerfile + `output: "standalone"` *(Finding ⑩, web #1; runtime hardened web #6)*
- [x] Liveness / readiness / startup probes on `/api/v1/health` and `/`
- [x] Resource requests and limits (initial; tighten from metrics in Phase 9)
- [x] HPA 2→4 and PodDisruptionBudget `minAvailable 1` for api and web
- [x] **Migrations as an Argo CD PreSync hook; removed from container start** *(Finding ⑨, Weysure-API #11)*
- [x] `api-scheduler` deployed as a single-replica Deployment
- [x] Vault Agent sidecar: per-pod dynamic `DATABASE_URL`, no standing DB password *(ADR-021)*
- [x] PostgreSQL 16 role layout: `weysure_owner` / `weysure_app` groups *(Finding ㉜, gitops #20–#22)*
- [x] Prod verified: both hosts 200 with TLS; 48 migrations applied from empty; pod deletion test
- [ ] Zero-downtime rollout measured across a real promote (probe over the whole rollout)
- [ ] 24 h Vault credential rotation observed end to end
- [ ] Paystack webhook URL set in the Paystack dashboard
- [x] SOP · runbooks `PROD_RELEASE.md`, `DEPLOYMENT_ROLLBACK.md`, `VAULT_CONFIG.md` · diagram · developer hand-over
- ⏸ Staging environment (prod only, Adebayo 2026-09-09)

## Phase 8 — Policy, cost and edge 🔵 *(2026-09-19 · [SOP](../sop/2026-09-19-phase-8-policy-cost-edge.md) — Enforce pending)*

- [x] **EKS 1.31 → 1.36** in five hops; control plane out of extended support (−$365/mo) *(2026-09-14 · [SOP](../sop/2026-09-14-eks-upgrade-1.36.md))*
- [x] Traefik HA: 2 replicas on system nodes + PDB *(Finding ㊳, gitops #27)*
- [x] **AWS Load Balancer Controller** owns the NLB — pod-IP targets, readiness gates; drain measured at 0 non-200 *(Finding ㊴, infra #26, gitops #29–#30)*
- [x] Legacy NLB, target groups and open NodePort SG rules deleted *(2026-09-19)*
- [x] `upgradePolicy.supportType`: keep EXTENDED + alert 60 days before 2027-08-02 *(decision D3; alert → Phase 9)*
- [x] System nodes → 2× m7g.large Graviton, x86 group removed (−$28/mo) *(infra #26, #27)*
- [x] Redis `do-not-disrupt` + hardened to the namespace baseline *(gitops #28, #33)*
- [x] Kyverno installed, 8 baseline policies in **Audit**; `weysure-prod` 183 pass / 0 fail *(gitops #28, #29, #33)*
- [ ] **Kyverno Enforce in `weysure-prod`** — 2026-09-23 after the audit window
- [x] Default-deny NetworkPolicies in `weysure-prod` with explicit allows *(gitops #31, #32)*
- [x] ResourceQuota + LimitRange in `weysure-prod`
- [x] Policy exceptions documented with rationale (`db-grants-v2`)
- [x] SOP · runbook `LOAD_BALANCER_CUTOVER.md` · Well-Architected delta
- [ ] Stale Vault database leases cleaned up *(Finding ㊶)*
- ⏸ Savings Plan (after Phase 9) · `ami_release_version` pin (Phase 10) · platform charts' requests/limits

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
