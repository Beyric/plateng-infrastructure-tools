# Weysure Platform — Master Build Checklist

> **Single source of truth for the whole build.** Updated as part of the work, never
> afterwards. An item is checked only when it is done **and verified**.
>
> **Last reconciled:** 2026-10-09 late (#53/#54/#55 live; `SECRET_KEY` rotated; first superadmin bootstrapped; Sonar gate main/PR only; wallet-origins to rebase onto `c4a8e1d7b3f5`) — handoff: `HANDOFF-master.md` (untracked, projects/)
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
  - [ ] delete the old `weysure-postgres` with a final snapshot once it can start (auto-start 2026-10-13)
- [x] New Dojah sandbox app: app ID, public key, widget IDs *(gitops #66, 2026-10-09)*; API key + webhook secret in Vault, force-synced; all pods verified
- [x] Priority classes: alloy/node-exporter `system-node-critical`, `platform-stateful` for Prometheus/Alertmanager/Jenkins/Loki *(gitops #65, 2026-10-09; [SOP](../sop/2026-10-09-priority-classes.md))* — confirm at next wake
- [x] Developer releases Weysure-API #53 (session revocation, migration `c4a8e1d7b3f5`), #54 (Sonar fix), #55 (double payout, no migration) *(live 2026-10-09: `13b3a5b3a435`, `869a9b812774`)*
- [x] `SECRET_KEY` rotated in Vault (generated by Vault) *(2026-10-09 21:04 UTC; [SOP](../sop/2026-10-09-secret-key-first-superadmin-sonar-gate.md))*
- [x] First superadmin bootstrapped (row via `db-oneoff.sh`, link via `admin_setup_link.py` in an api pod; image `52d5b8308631`) *(2026-10-09; same SOP)*
  - [ ] second superadmin invited from the console
- [x] Sonar gate only on `main` + PRs, both Jenkinsfiles *(developers, `52d5b83`)*
  - [ ] option 2: create `weysure-api-pr` / `weysure-web-pr` (platform), then PR builds switch `projectKey` (developers)
- [ ] Developer release: wallet money origins (card-to-cash PR 2, migration `c3a8e5f1b7d2`, to rebase onto #53's `c4a8e1d7b3f5` with a new ID) — reply sent/pending; pre-merge backfill count; rollback = `ORIGIN_RULES_ENFORCED=false` only
- ⏸ Staging namespace `weysure-stage` — asked for by the developers, **left for now** (Adebayo, 2026-10-02)
- [x] Cost: EKS control-plane logs off (−$51/mo); EKS add-on versions pinned *(infra #41, applied 2026-09-29)*
- [x] Verifier has both replicas: Jenkins CPU request 500m → 150m from measurements *(gitops #53, 2026-09-29)*
- **Scope decision 2026-09-29:** stop building after drills, sleep rehearsal and attaching the verifier to Sonar. Tasks 8 (Vault in Terraform) and the Prometheus/Alertmanager/Argo CD Ingresses of task 7 move to *Deferred follow-ups*. api/web replicas may share a spot node (`ScheduleAnyway` stays).
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
| Alert on `awscni_aws_api_error_count` | The cause has no alert; replicas-missing fires 10 min later | With the next monitoring PR | — |
| CNI warm target (`WARM_IP_TARGET`) | Every node holds a spare block | After node replacement, one change at a time | — |
| `KubeCPUOvercommit` / `KubeMemoryOvercommit` | Fire because Karpenter packs nodes (requests > allocatable minus the largest node); Pending pods are caught by `KubePodNotReady` | **Accepted for now** (Adebayo, 2026-10-05); revisit with the right-sizing work | — |
| Kaniko cache in its own ECR repo | `--cache-repo` shares the app repo; ~$0.50/mo | Cache grows, or ECR cost matters | — |
| Tighter `api-egress` blocked list (all private, link-local, CGNAT) | Needed when merchant webhooks go through the worker | The developers' webhook PR | — |
| Sleep stops RDS? | Saves ≈ $0.40/day; made the platform un-wakeable on 2026-10-08 | Before the next sleep | — |
| SonarQube evictions: Karpenter consolidation / spot moves the single Sonar pod (3× on 2026-10-09; Weysure PR-38 #1 failed). Option: `karpenter.sh/do-not-disrupt` on the pod | Parked by Adebayo 2026-10-09 | Builds failing on `Failed to connect` to Sonar again | — |
| Stable internal DNS name for the database | Endpoint change touched chart + Vault + Terraform | Next database change | — |

## Resolved questions

| # | Question | Answer |
|---|---|---|
| 1 | Domain and DNS | `beyrictech.com` · Namecheap registrar · **Cloudflare DNS** · `weysure.` and `weysure-api.` *(ADR-011)* |
| 2 | Live users / real money | **No** — pre-launch. Migration risk drops from severe to low |
| 3 | SonarQube | **Self-hosted in-cluster** with its own PostgreSQL *(ADR-013)* |

**Open questions: none currently blocking.**
