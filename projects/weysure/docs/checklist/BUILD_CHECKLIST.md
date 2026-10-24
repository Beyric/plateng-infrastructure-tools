# Weysure Platform — Master Build Checklist

> **Single source of truth for the whole build.** Updated as part of the work, never
> afterwards. An item is checked only when it is done **and verified**.
>
> **Last reconciled:** 2026-10-22 15:20 WAT (HIGH-1 hotfix #119 live `250636ecc649`, proven 200 → ban → 403) · earlier: 2026-10-22 00:40 WAT (Sonar `-pr` fix A1 + B1 platform part live: gate `weysure-pr`, credential `sonar-pr-admin-token` gitops #87) · earlier: 2026-10-21 20:00 WAT (Train 1a #118 + fix #120 live `d23e9b09321d`, alembic head `f2b8d6a4c1e7`; `-pr` Sonar reopen hole + SCM-off coverage found) · earlier: 2026-10-21 13:25 WAT (Sonar PR gate proven for API: base scan + lock #102, SCM off #110; CVE hotfix #117 live `570e48eb4c67`) · earlier: 2026-10-20 14:25 WAT (logging follow-ups #91 + #99 live `89883d393492`; Jenkins `lockable-resources` for the Sonar PR base scan, gitops #84) · earlier: 2026-10-19 12:50 WAT (idempotent Build & push live: API #90 `7770cf806803`, web #57 `3106a37bdb8e`, both proven) · earlier: 2026-10-17 23:10 WAT (chargebacks #79 live `a9e66abf2ebb`, off, alembic head `a7e3c9b25d14`) · earlier: 2026-10-17 16:10 WAT (Tier-2 withdrawals #88 live `681ce3b37762`, alembic head `e1a7c4d9b3f2`; Argo root loop fixed, gitops #83) · earlier: 2026-10-16 21:55 WAT (logging #78 live `d8c04502febf`, no migration; web #54 live `e5c5074d4a25`) · earlier: 2026-10-16 19:15 WAT (deal invites #75 live `af04c821c325`, flag off, alembic head `c8e1f4a7b2d9`; #77/#80 live `31c03c9ce8ca`) · earlier: 2026-10-16 12:05 WAT (ADR-024 repaired with `minDomains: 2`, gitops #82; #70 closed; #75 platform prep gitops #80/#81) · earlier: 2026-10-16 10:45 WAT (admin hardening #70 live `38b579b34f51`, no migration) · earlier: 2026-10-15 15:45 WAT (Paystack webhook-key trust #69 live `28e48768d0cd`, LIVE key emptied, Loki alerts gitops #74) · earlier: 2026-10-15 13:40 WAT (refund to source #67 live, flag off, alembic head `d4b7f2a91c68`) · earlier: 2026-10-13 18:50 WAT (risk holds #64 live, flags off, alembic head `58f3a1c7e0b9`) · earlier: 2026-10-13 15:40 WAT (Traefik NLB-only, gitops #71; real client IP live, Weysure-API #66) · earlier: 2026-10-13 13:20 WAT (web #48 7c live; ORIGIN_RULES_ENFORCED on, gitops #72; Weysure-API #65 live) · earlier: 2026-10-13 09:45 WAT (api/web hard spread live, gitops #70) · earlier: 2026-10-13 01:35 WAT (NLB Cloudflare-only live, gitops #69; old RDS deleted with final snapshot) · previous: 2026-10-12 14:30 WAT (Weysure-API #63 admin follow-ups live, #62 identity UX live `e120fd364ce7`, alembic head `c9a4e1b7d230`; 2nd superadmin verified; Resend email live (Vault v11); web #47 live `0456c8424250`; open: old RDS deletion 13 Oct, email sender switch) — handoff: `HANDOFF-master.md` (untracked, projects/)
>
> **Presentable version:** [Weysure Platform Blueprint](https://claude.ai/code/artifact/41d69692-4940-4751-8a21-0e46c8ba1bae)

## Snapshot

| Status | Count |
|---|---|
| ✅ Complete | 10 / 11 phases — 0–9 and Phase 5's restore drill (done in 10) · Phase 10 shipped with 1 item open (wake v4 rehearsal) |
| 🔵 In progress | 1 — Phase 10 (hardening/DR) · platform awake since 2026-10-01 22:01 UTC; supporting the developers' releases |
| ❓ Blocking questions | **0** — all three resolved |
| ⚪ Planned | 10 |
| 💰 Current AWS spend | **~$407/mo run-rate** ($13.57/day, 22–28 Sept, Cost Explorer; $356 once control-plane logs are off) — was ~$750/mo on extended support; Graviton and the legacy NLB removal are in; Savings Plan is the next lever |
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
- [x] Raft snapshot CronJob → S3 via Pod Identity; first snapshot in S3, `VaultSnapshotMissing` alert *(gitops #51, 2026-09-28)*
- [x] **Snapshot restore drill** *(Phase 10 task 5, 2026-09-29: PASS)*
- [ ] Argo CD bootstrap git credential rotated
- [ ] Config/secret split: non-secret `.env` keys → ConfigMap in git
- [ ] SOP · runbooks `VAULT_FAILURE.md`, `SECRETS_ROTATION.md` · diagram

## Phase 4 — Ingress & TLS ⚪

*Exit criteria: a real HTTPS URL serves a test workload.*

- [ ] **Cloudflare zone for `beyrictech.com`**; delegate nameservers from Namecheap *(ADR-011)*
- [ ] Cloudflare API token (scoped: Zone.DNS edit only) read **from Vault** via ExternalSecret — no hand-created Secret
- [ ] Traefik via Helm, behind an NLB
- [x] **NLB security group restricted to Cloudflare published IP ranges** — built late: was `0.0.0.0/0` until 2026-10-13 00:24 UTC *(gitops #69; [SOP](../sop/2026-10-13-nlb-cloudflare-only-and-old-rds-deleted.md))*
  - [x] Traefik entrypoints reachable only from the NLB subnets (NetworkPolicy `traefik-ingress-from-nlb`, gitops #71, live 2026-10-13 12:19 UTC; pod test 301 → 000)
- [x] Real client IP honoured: the API reads `CF-Connecting-IP` from trusted peers only (Weysure-API #66, `TRUSTED_PROXY_CIDRS` in gitops #72), verified 2026-10-13 14:34 UTC: audit row `public-ipv4`, 0 `10.x` *(429 redaction not yet observed)*
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
- [x] **Restore drill from PITR — timed, RTO recorded** *(Phase 10 task 5, 2026-09-29: RTO 13 min)*
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

## Phase 8 — Policy, cost and edge ✅ *(2026-09-19 · [SOP](../sop/2026-09-19-phase-8-policy-cost-edge.md); Enforce 2026-09-21)*

- [x] **EKS 1.31 → 1.36** in five hops; control plane out of extended support (−$365/mo) *(2026-09-14 · [SOP](../sop/2026-09-14-eks-upgrade-1.36.md))*
- [x] Traefik HA: 2 replicas on system nodes + PDB *(Finding ㊳, gitops #27)*
- [x] **AWS Load Balancer Controller** owns the NLB — pod-IP targets, readiness gates; drain measured at 0 non-200 *(Finding ㊴, infra #26, gitops #29–#30)*
- [x] Legacy NLB, target groups and open NodePort SG rules deleted *(2026-09-19)*
- [x] `upgradePolicy.supportType`: keep EXTENDED + alert 60 days before 2027-08-02 *(decision D3; alert → Phase 9)*
- [x] System nodes → 2× m7g.large Graviton, x86 group removed (−$28/mo) *(infra #26, #27)*
- [x] Redis `do-not-disrupt` + hardened to the namespace baseline *(gitops #28, #33)*
- [x] Kyverno installed, 8 baseline policies in **Audit**; `weysure-prod` 183 pass / 0 fail *(gitops #28, #29, #33)*
- [x] **Kyverno Enforce in `weysure-prod`** — 2026-09-21; bad pod denied, good pod passes, other namespaces Audit *(gitops #38)*
- [x] Default-deny NetworkPolicies in `weysure-prod` with explicit allows *(gitops #31, #32)*
- [x] ResourceQuota + LimitRange in `weysure-prod`
- [x] Policy exceptions documented with rationale (`db-grants-v2`)
- [x] SOP · runbook `LOAD_BALANCER_CUTOVER.md` · Well-Architected delta
- [x] Stale Vault database leases cleaned up — 5 roles dropped, 5 leases revoked *(Finding ㊶, gitops #34)*
- ⏸ Savings Plan (after Phase 9) · `ami_release_version` pin (Phase 10) · platform charts' requests/limits

## Phase 9 — Observability ✅ *(2026-09-23 · [SOP](../sop/2026-09-23-phase-9-observability.md))*

- [x] kube-prometheus-stack on the system nodes; 7 d / 15 GB, expandable *(gitops #39)*
- [x] Alertmanager → Slack (critical/warning), config rendered by ESO from Vault; test alert received
- [x] Every platform component scraped (57 targets, 0 down) *(gitops #41)*
- [x] Blackbox: external through Cloudflare (browser UA) + internal to the Services; TLS expiry *(gitops #42)*
- [x] 18 platform alerts with runbook links; **drill: web down → critical Slack in 3 min, resolved** *(gitops #43, #44; infra #32)*
- [x] Dead-man's switch: Watchdog → healthchecks.io *(gitops #45)*
- [x] Loki on S3 (pod identity) + Alloy (stdout **and** stderr) — developer item 5 answered *(infra #31; gitops #46–#48)*
- [x] Grafana behind Cloudflare Access with JWT validation at the origin; Admin/Viewer by email *(gitops #40)*
- [x] Weysure service dashboard + 8 community boards *(gitops #49)*
- [x] RDS CloudWatch alarms → SNS; sleep silences Alertmanager *(infra #31, #32)*
- [x] System node AMI pinned — patching is a deliberate PR *(infra #31)*
- [x] Prefix delegation: system nodes at 110 pods *(infra #36, 2026-09-24; Finding ㊺)*
- [x] Drop Karpenter pricing-table series: 225k → <200k series *(gitops #50, 2026-09-28)*
- ⏸ Tracing · app metrics/Sentry (developers) · Access forward-auth for Prometheus/Alertmanager/Jenkins/Sonar · SNS→Slack · healthchecks pause on sleep

## Phase 10 — Production readiness 🔵 *([spec](../specs/2026-09-23-phase-10-hardening-dr.md) · [plan](../plans/2026-09-23-phase-10-hardening-dr.md))*

- [x] 1 · Prefix delegation + max-pods 110 on system nodes *(infra #36; repaired by infra #40)*
- [x] 2 · Hygiene: Karpenter series drop, LBC diff ignored, Vault restart-on-config, Access-aware probes *(gitops #50)*
- [x] 3 · Vault snapshot identity, KMS deletion alarm, CloudTrail *(infra #36)*
- [x] 4 · Vault snapshot CronJob + `VaultSnapshotMissing`; first snapshot verified in S3 *(gitops #51, 2026-09-28)*
- [x] 5 · Restore drill: scripts + [RESTORE_DRILL.md](../runbooks/RESTORE_DRILL.md); run once
  - [x] `drill-vault-restore.sh` — tested end to end on dummy data: pass + 3 failure cases
  - [x] `drill-rds-restore.sh` — comparison tested on local Postgres 16 (5 cases); Job accepted by the API server and Kyverno (dry run)
  - [x] **Vault drill run on the production snapshot: PASS, 41 s** *(2026-09-29)*
  - [x] **RDS drill run: PASS, RPO 261 s, RTO 13 min** *(2026-09-29)*
- [x] 6 · Cloudflare Access apps + GitHub webhook bypass scoped to `/github-webhook/` *(console, 2026-09-27)*
- [x] 7 · forward-auth: verifier built *(gitops #52)*; **SonarQube attached 2026-10-02** *(gitops #56)*: direct-to-NLB 200 → 401, in-cluster Jenkins path unaffected
  - [x] real Access token accepted *(156 requests 200/304 with real tokens, 2026-10-02)*
  - ⏸ Jenkins (needs the `/github-webhook/` exemption), Prometheus/Alertmanager/Argo CD Ingresses — deferred, ADR-023
- ⏸ 8 · Vault config in Terraform (`vault` provider), plan = 0 changes *(deferred 2026-09-29)*
- [ ] 9 · Sleep/wake: pause `root` first, snapshot before sleep, healthchecks pause
  - [x] scripts rewritten; every read and patch dry-run against the live cluster
  - [x] healthchecks API key stored in Vault *(2026-09-28, 32 chars)*
  - [x] **sleep rehearsed: 0 instances in 21 min** *(2026-09-29)*
  - [x] **wake run for the first time 2026-10-01: failed, three bugs found, recovered by hand to all green**
  - [x] wake v4: Vault priority class *(gitops #54)*, wait for the secret store, re-sync failed apps, clean failed snapshot Jobs *(infra, this PR)*
  - [ ] wake v4 rehearsed
- [x] Finding ㊺, second occurrence (2026-09-29): cause proven, prefix reservations in both private subnets, `scripts/subnet-blocks.sh` *(infra, this PR)*
  - [x] reservations applied *(2026-09-29 12:10 UTC, 8 added)*
  - [x] node `ip-10-0-4-83` replaced; `subnet-blocks.sh`: 8 free blocks in 1a, 3 in 1b; address errors stopped 12:27 UTC
- [x] Finding ㊺ written up: [VPC_CNI_MODE_CHANGE.md](../runbooks/VPC_CNI_MODE_CHANGE.md), with incident record *(2026-09-28)*
- [x] Developer handover items 1 and 3 closed: `/tmp` only, migration Job without app secrets *(gitops #55, 2026-10-01)*
- [x] KYC secrets for the developers' phases 2–3 *(developer note 2026-10-02)*
  - [x] `KYC_FINGERPRINT_KEY` generated in Vault, snapshot taken, break-glass copy in Secrets Manager *(infra #45)*
  - [x] `TERMII_API_KEY`, `DOJAH_API_KEY`, `DOJAH_WEBHOOK_SECRET` in Vault *(verified in the pod by length, 2026-10-02)*
  - [x] 14 non-secret values in the API ConfigMap *(gitops #57; KYC P2 live 2026-10-02, P3 Weysure-API #36 live 2026-10-03)*
- [x] `ENVIRONMENT=prelaunch` — #36's guard refuses `production` with Dojah sandbox; render test rejects fake-provider envs *(gitops #58, 2026-10-03)*
- [x] ECR: PR/branch images (`*-b*`) expire after 7 days on both repos; lifecycle preview proved 0 main SHAs selected *(infra #46, 2026-10-03)*
- [x] **api-worker** (Postgres jobs queue) — [SOP](../sop/2026-10-05-api-worker-and-log-alerts.md)
  - [x] chart: exec probes, per-component Vault restart command; worker prepared off *(gitops #59)*
  - [x] Vault role `weysure-api` binds `api-worker` *(2026-10-04)*
  - [x] Loki ruler → Alertmanager; `JobsQueueLagging`, `JobsDeadIncreased` + Docker end-to-end test *(gitops #60, infra #47)*
  - [x] switched on after Weysure-API #43 was promoted; `JobsStatsMissing` *(gitops #61, 2026-10-05)*
  - [x] restart-on-first-render bug fixed: anchored pattern, 0 restarts *(gitops #62)*
  - [x] sleep stops api-worker *(infra #48)*
  - [x] rollback tooling for money-job releases: `scripts/db-oneoff.sh`, runbook corrected (any migration blocks an image-only revert) *(infra #50)*; `replicas: 0` honoured *(gitops #63)*
  - [x] `db-oneoff.sh` first real run in prod (read-only): Vault `weysure-migrate`, NetworkPolicy to RDS, Kyverno all passed; `jobs` empty, as expected *(2026-10-05 16:29 UTC)*
- [x] Developer releases on the worker: PR 2 auto-release (Weysure-API #44, 2026-10-05) and PR 3 delivery deadline (#46, 2026-10-08) rolled out and verified; PR 3 migration tested up/down/up as a non-superuser; rollback commands in DEPLOYMENT_ROLLBACK.md
- [x] **Database recovery 2026-10-08** — [SOP](../sop/2026-10-08-database-recovery.md)
  - [x] wake: RDS start refused (`InsufficientDBInstanceCapacity`, db.t4g.micro, every AZ, 2 h)
  - [x] point-in-time restore as `weysure-postgres-v2` (db.t3.micro, us-east-1b); Vault + gitops #64 cut over; API back 13:01 UTC
  - [x] Terraform: old instance out of state, v2 imported, `No changes` *(infra #53, #55)*
  - [x] scripts on v2; wake step 1 stops on a failed start; runbooks *(infra #54)*
  - [x] old `weysure-postgres` deleted 2026-10-13; final snapshot `weysure-postgres-final-2026-10-13` available *([SOP](../sop/2026-10-13-nlb-cloudflare-only-and-old-rds-deleted.md))*
- [x] New Dojah sandbox app: app ID, public key, widget IDs *(gitops #66, 2026-10-09)*; API key + webhook secret in Vault, force-synced; all pods verified
- [x] Priority classes: alloy/node-exporter `system-node-critical`, `platform-stateful` for Prometheus/Alertmanager/Jenkins/Loki *(gitops #65, 2026-10-09; [SOP](../sop/2026-10-09-priority-classes.md))* — confirm at next wake
- [x] Developer releases Weysure-API #53 (session revocation, migration `c4a8e1d7b3f5`), #54 (Sonar fix), #55 (double payout, no migration) *(live 2026-10-09: `13b3a5b3a435`, `869a9b812774`)*
- [x] `SECRET_KEY` rotated in Vault (generated by Vault) *(2026-10-09 21:04 UTC; [SOP](../sop/2026-10-09-secret-key-first-superadmin-sonar-gate.md))*
- [x] First superadmin bootstrapped (row via `db-oneoff.sh`, link via `admin_setup_link.py` in an api pod; image `52d5b8308631`) *(2026-10-09; same SOP)*
  - [x] second superadmin: invited as Admin, promoted via Edit → Super Admin; 2 active superadmins verified *(2026-10-12)*
- [x] Sonar gate only on `main` + PRs, both Jenkinsfiles *(developers, `52d5b83`)*
  - [x] option 2, platform: `weysure-api-pr` / `weysure-web-pr` created with main's gate, profiles, visibility, new code *(2026-10-10, `scripts/sonar-pr-projects.sh`)*
  - [ ] option 2, developers: PR builds switch `projectKey` to `*-pr` + `sonar.projectVersion=$CHANGE_ID`; first PR build passes
- [x] Developer release: wallet money origins (card-to-cash PR 2, migration `9f1d6a2b8e47`, image `3504876c3164`, live 2026-10-09 23:52 UTC) — [SOP](../sop/2026-10-10-wallet-origins-release-and-drift-alert.md)
  - [x] rollout verified after the fact (developers merged before "platform ready"): PreSync Succeeded, 4 pods, 0 errors
  - [x] post-merge drift check via `db-oneoff.sh`: **0** (replaces the pre-merge count) *(2026-10-10 10:27 UTC)*
  - [x] `WalletLotDrift` Loki alert + Docker test; `ORIGIN_RULES_ENFORCED: "false"` explicit *(gitops #67, live 10:35 UTC)*; runbook ALERTS § WalletLotDrift
  - [x] flag on (`ORIGIN_RULES_ENFORCED: "true"`) *(gitops #72, live 2026-10-13 11:51 UTC, after web #48 `4b9e2223c440` and 24 h drift 0; developers' smoke test passed; [SOP](../sop/2026-10-13-web-7c-and-origin-rules-on.md))*
  - [x] web #48 (7c wallet split) live 11:22 UTC; Weysure-API #65 (log PII) live 11:51 UTC, unannounced, inside the flag rollout
- [x] Developer release: risk holds (Weysure-API #64, migration `58f3a1c7e0b9`, image `f9cf2e8d6a3f`, live 2026-10-13 15:54 UTC, all flags off) — [SOP](../sop/2026-10-13-risk-holds-release.md)
- [x] Developer release: refund to source (Weysure-API #67, migration `d4b7f2a91c68`, image `acdae7fd271c`, live 2026-10-13 23:38 UTC, flag off) — [SOP](../sop/2026-10-14-refund-to-source-release.md)
  - [ ] Loki alerts `source_refund_orphan`/`_conflict` (page), `_unresolved`/`_stale`/`_over_taken` (ticket) — before the flag
  - [ ] developers' test-mode `refund.*` capture received — before the flag
  - [ ] `REFUND_TO_SOURCE_ENABLED=true` (gitops `commonEnv`)
  - [ ] stage 1 capture (Vault `RISK_SIGNAL_HASH_KEY`, privacy clause, web credentials change) · [ ] stage 2 shadow (Loki alerts first) · [ ] IP signal · [ ] enforce
- [x] Developer release: withdrawal re-check (Weysure-API #60, no migration, image `ef17d9fe9ff2`, live 2026-10-10 15:22 UTC) — [SOP](../sop/2026-10-10-withdrawal-recheck-release.md)
  - [x] rollout verified after the fact (merged before "platform ready"): 4 pods on tag, 0 restarts, 0 errors, 0 dead jobs
  - [x] startup sweep `ensure_withdrawal_rechecks`: 0 scheduled, so no automatic refund (replaces the pre-merge count)
  - [x] Loki alerts `WithdrawalUnresolved` (critical) / `WithdrawalRefundedByRecheck` (warning) + Docker test (5 scenarios PASS) *(gitops #68, live 20:41 UTC: ruler inactive/ok)*; runbook ALERTS § WithdrawalUnresolved
- [x] Developer release: admin identity API (Weysure-API #61, migration `b7d2e9a41c63`, image `f99052762224`, live 2026-10-10 20:11 UTC) — [SOP](../sop/2026-10-10-admin-identity-release.md)
  - [x] merged after "platform ready" (19:49 UTC); migration ran in PreSync, `alembic current` = `b7d2e9a41c63 (head)`, 4 pods on tag, 0 restarts, 0 errors
  - [x] post-rollout read-only count of reviews resolved on an old pod = **0** (`db-oneoff` 20:18 UTC); UPDATE not needed
  - [x] rollback documented: downgrade with the new image, then image revert; fix-forward only after the first system audit row (accepted)
- [x] Developer release: admin API follow-ups (Weysure-API #63, migration `c9a4e1b7d230`, image `fd482c787ca5`, live 2026-10-12 13:14 UTC) — [SOP](../sop/2026-10-12-admin-followups-release.md)
  - [x] merged after "platform ready" (12:50 UTC); migration ran in PreSync, `alembic current` = `c9a4e1b7d230 (head)`, 4 pods on tag, 0 restarts, 0 errors
  - [x] reply corrected the developers' retry claim (migration Job `backoffLimit: 0`: lock-timeout failure = manual re-sync); prod `DATABASE_URL` has no `options=`
- [x] Developer release: identity UX (Weysure-API #62, no migration, image `e120fd364ce7`, live 2026-10-12 14:37 UTC) — [SOP](../sop/2026-10-12-identity-ux-release.md)
  - [x] merged after #63 verified (14:13 UTC); rebase checked with `git range-diff` (no code change); 4 pods on tag, 0 restarts, 0 errors
  - [x] web #47 (identity dialog reminder, notices in the bell): merged 15:05 UTC, promoted `0456c8424250` 15:14, both web pods on tag, sites 200, 32/32 Argo healthy *(2026-10-12; frontend only, no platform change)*
  - [x] `IDENTITY_RELEASE_ENABLED` **not** set in prod (Adebayo, 2026-10-12): release identity answers 403 on prelaunch
  - [x] API email moved to **Resend**, From `support@weysure.com` (Vault v11, 2026-10-12 14:27 UTC; test reset DKIM/SPF pass) — [SOP](../sop/2026-10-12-resend-email-switch.md). Applied ahead of web #47 (process note in SOP)
- [x] api/web replicas never share a node: hostname spread `DoNotSchedule` for api and web *(gitops #70, live 2026-10-13 08:37 UTC; ADR-024; [SOP](../sop/2026-10-13-api-web-hard-spread.md))*: api and web each on 2 nodes, 0 Pending, sites 200
  - [x] **Repaired 2026-10-16:** consolidation had packed all replicas onto one workload node; `minDomains: 2` (gitops #82, live 10:58 UTC) *([SOP](../sop/2026-10-16-adr024-min-domains.md))*
  - [ ] Confirm steady state settles to 2 workload nodes after the Jenkins build node goes
- [x] SonarQube + sonar-postgres `karpenter.sh/do-not-disrupt` via chart values *(gitops [#85](https://github.com/Beyric/plateng-gitops/pull/85), merged 2026-10-20 17:05 UTC `2609e16`; [SOP](../sop/2026-10-20-sonarqube-do-not-disrupt.md))*: consolidation moved Sonar mid-scan, PR-107 #1 `Connection refused` 16:40:45 UTC
  - [x] Rendered + server dry run + pre-commit green locally
  - [x] Live 17:08 UTC: both pods `DND=true` and Ready on `ip-10-0-4-35`; `DisruptionBlocked … Pod=sonarqube/sonar-postgres-0` seen
  - [x] **No `terminationGracePeriod`** (Adebayo, 2026-10-20, option A): with `al2023@latest` it would let AMI drift force-kill Sonar. Drains of do-not-disrupt nodes are finished by hand
  - [ ] `KarpenterNodeStuckDraining` alert (taint `karpenter.sh/disrupted` > 1h) + promtool test *(gitops [#86](https://github.com/Beyric/plateng-gitops/pull/86) open)*; runbook section added
  - [ ] Before 2026-11-15 ~12:10 UTC: `ip-10-0-4-18` (redis-0) expires — expect the alert, finish the drain per runbook
- ⏸ Staging namespace `weysure-stage` — asked for by the developers, **left for now** (Adebayo, 2026-10-02)
- [x] Cost: EKS control-plane logs off (−$51/mo); EKS add-on versions pinned *(infra #41, applied 2026-09-29)*
- [x] Verifier has both replicas: Jenkins CPU request 500m → 150m from measurements *(gitops #53, 2026-09-29)*
- **Scope decision 2026-09-29:** stop building after drills, sleep rehearsal and attaching the verifier to Sonar. Tasks 8 (Vault in Terraform) and the Prometheus/Alertmanager/Argo CD Ingresses of task 7 move to *Deferred follow-ups*. api/web replicas may share a spot node (`ScheduleAnyway` stays). **Reversed 2026-10-13 for api/web (ADR-024).**
- [x] 10 · SOP [2026-09-29-phase-10-hardening-dr](../sop/2026-09-29-phase-10-hardening-dr.md) · overview · checklist *(2026-09-30; wake + verifier attach stay open above)* · ADR-023 scope freeze

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

- [x] **Login tokens in logs** — Alloy redacts JWTs in all namespaces (gitops #79); `SECRET_KEY` rotated 2026-10-15 22:12 UTC to void the 367 stored tokens *([SOP](../sop/2026-10-15-jwt-in-logs-redaction.md))*
  - [ ] Developers: Weysure-API#76 (API-side redaction, token out of the URL, shorter token lifetime)
  - [ ] Loki tripwire alert on JWT-shaped strings

- [x] **Wallet reconciliation as one worker job** — Weysure-API #68 live 2026-10-15 19:07 UTC (`7249abff973c`); gitops #76 (worker flags + `WalletLotDrift` reads api-worker), #77 (`WalletReconciliationMissing`) *([SOP](../sop/2026-10-15-recon-loop-worker-job.md))*
  - [ ] Scale `api-scheduler` to 0 (~2026-10-18), then remove it

- [ ] 🔵 **Domain cutover to `weysure.com` / `api.weysure.com`** (live on the new hosts 2026-10-15; soak until ≈10-29) (tools stay on beyrictech.com) — *[plan](../plans/2026-10-15-domain-cutover-weysure-com.md)*
  - [x] Read-only checks (DNS, mail, CAA, origin, chart, settings) — 2026-10-15
  - [x] Dashboard checks §2: parking records replaced, Full (strict), token covers weysure.com, no rules to mirror, no mobile app
  - [x] Phase A: DNS, chart `extraHosts` (gitops #75), staging cert proof, both hosts served — 2026-10-15
  - [x] Phase A5: `www` → apex 301 (Cloudflare rule) — verified 2026-10-15 (path and query kept)
  - [x] Phase B1+B4: API settings, CORS for both origins, probes — gitops #78, 2026-10-15
  - [x] Phase B2: web #51 live (`a0d4e7b4adfe`) · B3: Paystack/Dojah URLs → `api.weysure.com` · ₦500 test top-up end to end — 2026-10-15
  - [x] Phase C1: `weysure.beyrictech.com` → `weysure.com` 301 — 2026-10-15
  - [ ] Phase C2/C3 (≈ 2026-10-29): retire `weysure-api.beyrictech.com` after 14 days without traffic; CORS → only `weysure.com`; drop old names from `extraHosts`/probes/docs

- [x] **Paystack webhook-key trust** — Weysure-API #69 live 2026-10-15 14:13 UTC (`28e48768d0cd`); Vault LIVE placeholder emptied; look-back clean; test top-up verified *([SOP](../sop/2026-10-15-paystack-webhook-key-trust.md))*
  - [x] Loki alerts `PaystackWebhook*` — gitops #74 merged; ruler loaded, 3 rules ok
  - [x] Test key rolled 2026-10-15 ~16:35 UTC (no `sk_test_a3e6` match; rolled anyway): SECRET new `sk_test_`, TEST empty; api/worker/scheduler reloaded 16:39–16:45 UTC
  - [ ] **Launch gate:** `PAYSTACK_SECRET_KEY` = `sk_live_`; TEST empty or prod's own key; no `[CONFIG] Paystack` warning
- [x] **Admin hardening** — Weysure-API #70 live 2026-10-16 09:37 UTC (`38b579b34f51`, same tree as approved `360e994`); no migration; OpenAPI shows `AdminStatusUpdate`/`AdminManage` *([SOP](../sop/2026-10-16-admin-hardening-release.md))*
  - [x] Review (Opus, permission checks + row locks): GO at `360e994`
  - [x] Refused actions in prod: 422 + 409 `SELF_ACTION` (Traefik), 2026-10-16 10:38 UTC — closed
- [x] **Deal invites** — Weysure-API #75 live 2026-10-16 17:24 UTC (`af04c821c325`), flag off, alembic head `c8e1f4a7b2d9` *([release SOP](../sop/2026-10-16-deal-invites-release.md), [prep SOP](../sop/2026-10-16-deal-invites-platform-prep.md))*
  - [x] Invite-token log redaction by path (Alloy, gitops #80) + Docker test; live 10:27 UTC
  - [x] Migrate Job deadline 900 s (gitops #81; applies at #75's sync — check then)
  - [x] `statement_timeout` on the migrate identity = 0 (verified, no change)
  - [x] Review (Opus) on `469a94b`: no blockers; 4 should-fixes folded in; go for `926f347`
  - [x] Release: Job deadline 900 on the Job, `indisvalid = true`, flag off, worker on the same image (3 builds: timeout, immutable tag, Replay)
  - [ ] **Flag-on** (separate go): web `/invite/[token]` + `Referrer-Policy: no-referrer`, `RiskHoldSettings` row, one invite per direction end to end
- [x] **Logging: no diagnose, token redaction** — Weysure-API #78 live 2026-10-16 20:47 UTC (`d8c04502febf`), no migration; 4 commits patch-identical to approved `6cf4f1c` *([SOP](../sop/2026-10-16-logging-redaction-release.md))*
  - [x] Review: tests 17/17; gunicorn+UvicornWorker probe REDACTED; loguru `└` lines 35 → 0; alert substrings unchanged
  - [x] Live: fake non-JWT `?token=` probe raw before → `token=REDACTED` after; 0 unredacted `token=` from `api*`; 0 × 5xx
  - [x] Jenkinsfile timeout 45 (main #64 took 29 min 58 s)
  - [ ] Developers' follow-ups: `args`-preserving filter (dev uvicorn), app-frame location, `log.exception` text audit, #76 part 2 (token out of URL)
- [x] **Web #54 contact "Where we are" card** — live 2026-10-16 19:15 UTC (`e5c5074d4a25`, go for `6e25a6e`, merged tree identical); static content; rollback web `a0d4e7b4adfe`
- [x] **Withdrawals need Tier 2** — Weysure-API #88 live 2026-10-16 23:03 UTC (`681ce3b37762`), migration `e1a7c4d9b3f2` (data-only), tree == approved `b64cd73` *([SOP](../sop/2026-10-16-withdraw-tier2-release.md))*
  - [x] Review (money path): gate in `open_withdrawal`, every transfer site traced, 924 tests; prod counts: 0 pending below T2, 1 user
  - [x] Live: Job log, `alembic current` + `out_30d` T1 0 (Adebayo), OpenAPI `reason_codes`, 0 × 5xx
  - [ ] Developers' end-to-end: Tier-1 → 403 `KYC_TIER_REQUIRED` (JSON body with `code`, so larger than the 30 B `HTTPBearer` 403), Tier-2 withdraws (times → Traefik)
  - [ ] Developers' follow-up: Tier-2 re-check in `approve_withdrawal` + worker retries
- [x] **Argo `root` OutOfSync loop fixed** — plateng-gitops #83 (`752c917`, 2026-10-17 14:53 UTC) + hand-applied `root-app.yaml`: root ignores Argo's own `pre-delete-finalizer*` on child apps; 32/32 Synced *([SOP](../sop/2026-10-17-argo-root-predelete-finalizers.md))*
- [x] **Card chargebacks (off)** — Weysure-API #79 live 2026-10-17 21:58 UTC (`a9e66abf2ebb`), migration `a7e3c9b25d14` (expand-only), tree == approved `44f62bf` *([SOP](../sop/2026-10-17-chargebacks-release.md))*
  - [x] Review (2 Opus reviewers + lead verification): R1–R4 required and fixed (off stops money, bank-retry freeze, ledger order, revert/downgrade guard)
  - [x] Live: migrate log, `alembic current` (Adebayo), OpenAPI 217 schemas / 9 chargeback paths, off sweeps `0 job(s)`, 0 × 5xx
  - [ ] **`enforce` gate:** developers' E1–E7; real upload host in `commonEnv`; Paystack `charge.dispute.*` webhook events (Adebayo); platform Loki alerts on chargeback lines
- [x] **Idempotent Build & push (CI)** — Weysure-API #90 live 2026-10-18 00:17 UTC (`7770cf806803`, tree == approved `b0190ac`), web #57 live 2026-10-19 11:38 UTC (`3106a37bdb8e`, tree == approved `9378e77`); Jenkinsfile only *([SOP](../sop/2026-10-19-idempotent-build-push.md))*
  - [x] Review: tip guard + no-op promote required before skipping the push; revision label checked on reuse (missing = fail); tip lookup with `github-app`
  - [x] API proof: #68 builds + labels + promotes; #69 re-run skips, no gitops commit; #70 Replay of #67 refuses the unlabelled image
  - [x] Web proof: #52 builds + labels + promotes; #53 re-run skips, no gitops commit
  - [ ] First UNSTABLE "not main's tip" build seen (next overtaken main build)
- [x] **Logging follow-ups (#78)** — Weysure-API #91 + #99 live 2026-10-20 12:59 UTC (`89883d393492`), no migration; trees == approved `e85db3c` / `069be23` *([SOP](../sop/2026-10-20-logging-followups-release.md))*
  - [x] Main #71 failed main's gate (S3516) → fix #99; PR-99 gate red on baseline noise (S8410, `pr-98`) → GO by exception, main #72 gate PASSED
  - [x] Live: WS probe `refresh_token`/`id_token%3D` raw → REDACTED; OpenAPI withdraw 400–500; 0 × 5xx; reconciliation `1 users, 0 mismatches` (`:53`)
- [x] **Train 1a (first release train)** — Weysure-API #118 (11 PRs, merge commit `45bb5fd`) + fix-forward #120 (`d23e9b0`) live 2026-10-21 18:29 UTC (`d23e9b09321d`); migration `f2b8d6a4c1e7` *([SOP](../sop/2026-10-21-train-1a-release.md))*
  - [x] Structure verified at `8604b24`: 11 PR heads = merge 2nd parents, integration commits = table + doc + main merges, Jenkinsfile = main, one Alembic head
  - [x] PR-118 #1: 3707 passed, SCM off, gate PASSED, Trivy 0; prod case-collision read `0` groups (Adebayo)
  - [x] Main #76 red (S3776 `request_withdrawal` 17 > 15, from #95) → nothing promoted → fix #120 reviewed for behaviour → main #77 green
  - [x] Live: migrate log + `alembic current` = `f2b8d6a4c1e7` (Adebayo), 4 pods on tag, `[FLAGS]` = gitops, sites 200, Argo 32/32
  - [ ] Loki rules on the new log lines (developers' note §3); M-1 #114 before refund flag-on; `WS_ALLOW_URL_TOKEN=false` after web #56
- [x] **HIGH-1 hotfix (Weysure-API #119)** — banned/inactive developers' API keys no longer authenticate; merge commit `250636e` live 2026-10-22 ≈12:45 UTC (`250636ecc649`), no migration *([SOP](../sop/2026-10-22-high1-api-key-hotfix.md))*
  - [x] Opus-level review of `eabe006` (allowlist ACTIVE/PENDING_KYC + verified, fail closed); head `03654c6` = merge of main, reviewed files byte-identical
  - [x] PR-119 #3: 3716 passed, Trivy CRITICAL 0; main #78: 3716 passed, main Sonar gate PASSED
  - [x] Live: 4 pods on tag; throwaway developer key `GET /api/v1/public/escrow` 200 → ban → 403 (same body); account left banned
  - [ ] Developers merge `main` into `release/2026-10-2-api`; Train 2's #119 diff vs `main` must be empty
- [ ] **Sonar PR gate vs `main` (base scan + lock + SCM off)** *([SOP](../sop/2026-10-20-sonar-pr-base-scan.md))* — API proven 2026-10-21; web SCM off pending
  - [x] Platform: `lockable-resources` in Jenkins (gitops #84, restart 13:06 UTC 2026-10-20, plugin 1576)
  - [x] Platform: SonarQube + sonar-postgres `do-not-disrupt` (gitops #85, 2026-10-20 17:05 UTC)
  - [x] Weysure-API #102 (`2be8fd2`) base scan + lock + `chown`; #110 (`e5c43cd`) SCM off in `-pr` scans
  - [x] Weysure web #60 (`d71f3a7`) base scan + lock + `chown`
  - [x] API proof: clean PR-110 #1 PASSED; never-seen planted issue PR-111 #2 FAILED (New issues 1); main #75 keeps SCM
  - [ ] Web: SCM off in `-pr` scans, then proof with a fresh planted issue
  - [x] Web #61 (`d912f71`) proof run: planted #62 → New issues 2 (exactly the planted ones) ✓; but #61 alone FAILS: with SCM off all lines are new code → coverage on new code = whole repo (63%)
  - [ ] **A1** (decided 2026-10-21 23:45 WAT): separate `-pr` quality gate + changed-line coverage in PR builds
    - [x] Platform: gate `weysure-pr` (New issues > 0 only, not default) — **created 2026-10-24** (the 10-22 tick was wrong: never created, every B1 build got select 404; [SOP correction](../sop/2026-10-22-sonar-pr-admin-credential.md)); selected per build by B1
    - [ ] Developers: changed-line coverage in PR builds (API `diff-cover` ≥80%, web `scripts/coverage-new-code.sh`) — Train 2
  - [ ] **Reopen hole → B1** (decided 2026-10-21 23:45 WAT): shared `-pr` project reopens a previously seen issue with its old date (PR-118 passed with S3776) → PR builds delete + recreate the `-pr` project and select `weysure-pr` under the lock
    - [x] Platform: SonarQube user `jenkins-sonar-pr` (Create Projects; Administer on `-pr` projects / projects it creates), 90-day user token in Vault `secret/platform/jenkins` `sonar_pr_admin_token` *(Adebayo, 2026-10-22)*
    - [x] Platform: Jenkins credential `sonar-pr-admin-token` (gitops [#87](https://github.com/Beyric/plateng-gitops/pull/87), `92aaf4d`; live 2026-10-21 23:36 UTC; [SOP](../sop/2026-10-22-sonar-pr-admin-credential.md))
    - [ ] Developers: Jenkinsfile (API + web) delete + create + gate-select before the base scan; fail closed on API errors and on no merge base
      - [x] API #121 `78323f6` / #122: proven 2026-10-24 (PR-121 #4 PASSED; PR-122 #4 FAILED `new_violations` 1 = planted S1481; fail-closed proven by the select-404 runs); GO sent — merge pending
      - [ ] Web #63/#64: PR-64 #4 FAILED with 345 (base scan in hidden `.base-scan` analyses only `tests/`+`e2e/`); developers rename the worktree, re-prove
    - [ ] Proof: re-planted previously-seen issue FAILS (New issues 1); clean candidate PASSES — API ✓, web pending
    - [ ] Rotate the `jenkins-sonar-pr` token before expiry (≈ 2027-01-19)

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
| Database cut-over rehearsal (restore → rename → Terraform import) | Needs downtime; the drill proves the data, not the switch | Before go-live | — |
| PDBs: `unhealthyPodEvictionPolicy: AlwaysAllow` | Found by Finding ㊺; not blocking | Before the next node roll | — |
| Blackbox 2 replicas + `absent(probe_success)` alert | Found by Finding ㊺; probes were blind for 30 min | Before go-live | — |
| Replace node `ip-10-0-4-83` | Holds 7 scattered addresses, blocks 6 blocks | **Now** — right after the reservations are applied | — |
| **Larger subnets for nodes** (two /20, blue/green node groups) | A /24 has 14 usable /28 blocks; repaired with reservations for now | **Before go-live**, or `scripts/subnet-blocks.sh` exit 1 | — |
| **#67 flag-on gate (from #88):** needs-attention card refund below Tier 2 has no admin resolution (bank retry refused) — developers add "credit back to wallet" | Flag off in prod; no source refunds run | Before `REFUND_TO_SOURCE_ENABLED=true` | — |
| #69 follow-ups: verify 401/403 → 503; escrow re-verify; shutdown `CancelledError`; `/topup/verify` 404 after credit | Non-blocking; sent to developers 2026-10-15 | Before go-live | — |
| Merge enforcement: promote PRs (or GitHub Team branch protection) | Org on GitHub Free: no branch protection on private repos; process only while building (decided 2026-10-16) | **Before go-live** | — |
| #70 follow-ups: audit row in the same transaction; API `lock_timeout` on admin paths; mutual superadmin `reset-password` lockout | Non-blocking; sent to developers 2026-10-16 | Before go-live | — |
| Alert on `awscni_aws_api_error_count` | The cause has no alert; replicas-missing fires 10 min later | With the next monitoring PR | — |
| CNI warm target (`WARM_IP_TARGET`) | Every node holds a spare block | After node replacement, one change at a time | — |
| `KubeCPUOvercommit` / `KubeMemoryOvercommit` | Fire because Karpenter packs nodes (requests > allocatable minus the largest node); Pending pods are caught by `KubePodNotReady` | **Accepted for now** (Adebayo, 2026-10-05); revisit with the right-sizing work | — |
| ResourceQuota `limits.cpu=8` in `weysure-prod` leaves no surge room (seen on almost every roll; 2026-10-16 #70 and #82 rolls, and Argo now shows `Degraded` ~1 min from the `ReplicaFailure`; earlier: #63 rollout 2026-10-12 13:13, api-worker): during the #61 rollout (2026-10-10 20:08–20:12) api/api-worker surge pods hit `FailedCreate … exceeded quota` and the roll ran one-out-one-in (~2 min slower, briefly 1 api replica) | Rollout still completes; no errors | Right-sizing work, or before api replicas > 2 (quota headroom of one pod's limits, or `maxSurge: 0`) | — |
| Kaniko cache in its own ECR repo | `--cache-repo` shares the app repo; ~$0.50/mo | Cache grows, or ECR cost matters | — |
| Tighter `api-egress` blocked list (all private, link-local, CGNAT) | Needed when merchant webhooks go through the worker | The developers' webhook PR | — |
| Sleep stops RDS? | Saves ≈ $0.40/day; made the platform un-wakeable on 2026-10-08 | Before the next sleep | — |
| `jenkins` namespace has no NetworkPolicy: agents run developers' PR code with open egress/ingress inside the cluster | Not yet designed (agents need GitHub, ECR, Sonar, the API server) | Before any secret reaches PR builds — **trigger met 2026-10-22**: `sonar-pr-admin-token` (B1) is bound in PR builds (blast radius: `-pr` Sonar projects only); `sonar-token` already was | — |
| No deploy hold: developers merged Weysure-API #65 during a platform rollout (2026-10-13) | Process | Next unannounced merge | — |
| SonarQube evictions: **consolidation** part fixed by gitops #85 (see Phase 10); **spot interruption / expiry** can still move Sonar | Forced disruptions ignore `do-not-disrupt` | Builds failing on `Connection refused` to Sonar after #85 is live → on-demand CI NodePool or scanner retry | — |
| NodePool has no `terminationGracePeriod` **by decision** (2026-10-20, option A): an expiring node hosting a `do-not-disrupt` pod waits for a person (alert `KarpenterNodeStuckDraining`, runbook) | With `al2023@latest`, a grace period lets drift force-kill Sonar/redis on every AMI release | Option C: pin the AMI alias to a version (drift only when we bump it), then add `terminationGracePeriod` | — |
| Stable internal DNS name for the database | Endpoint change touched chart + Vault + Terraform | Next database change | — |
| Two reconciliation schedulers per api-scheduler pod (gunicorn `--max-requests` recycles a worker ~every 2 h 45 min; each worker starts the scheduler; `WEB_CONCURRENCY=2`) | Harmless while the notification cooldown dedups | Developers move scheduled work to one process, or drift/notification noise | — |
| No "reconciliation stopped" alert (`WalletLotDrift` is silent if the scheduler stops) — **trigger passed: flag went on 2026-10-13 without it** | Needs a positive per-run log line (asked of developers 2026-10-13) | When the per-run line ships | — |

## Resolved questions

| # | Question | Answer |
|---|---|---|
| 1 | Domain and DNS | `beyrictech.com` · Namecheap registrar · **Cloudflare DNS** · `weysure.` and `weysure-api.` *(ADR-011)* |
| 2 | Live users / real money | **No** — pre-launch. Migration risk drops from severe to low |
| 3 | SonarQube | **Self-hosted in-cluster** with its own PostgreSQL *(ADR-013)* |

**Open questions: none currently blocking.**
