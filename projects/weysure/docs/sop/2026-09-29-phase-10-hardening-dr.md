# SOP — Phase 10: Hardening and disaster recovery

**Shipped:** 2026-09-23 → 2026-09-29 · **PRs:** infra #35 (spec), #36–#42 · gitops #50–#53 ·
**Cost delta:** **−$51/mo** (control-plane logs off); run-rate **$13.57 → ≈$11.9/day**; asleep ≈ $4.5–5/day ·
Spec: [2026-09-23-phase-10-hardening-dr](../specs/2026-09-23-phase-10-hardening-dr.md) · Plan:
[2026-09-23-phase-10-hardening-dr](../plans/2026-09-23-phase-10-hardening-dr.md) · Runbooks:
[RESTORE_DRILL](../runbooks/RESTORE_DRILL.md), [SLEEP_WAKE](../runbooks/SLEEP_WAKE.md),
[VPC_CNI_MODE_CHANGE](../runbooks/VPC_CNI_MODE_CHANGE.md), [COST_CONTROLS](../runbooks/COST_CONTROLS.md)

**Status: shipped with two items open** — the wake half of sleep/wake has not been run (platform left
asleep 2026-09-29 14:15 UTC on purpose), and the Access verifier is deployed but attached to no host.
Both are recorded in the checklist. Tasks 8 (Vault config in Terraform) and the Prometheus/Alertmanager/
Argo CD Ingresses were **deferred by decision** (ADR-023).

## What shipped

| Piece | Where | Proof |
|---|---|---|
| **Prefix delegation** — system nodes at 110 pods (was 29), `maxPods` via nodeadm, AMI pin kept | infra `main.tf` (#36) | `allocatable.pods = 110` on both; `KubeletTooManyPods` gone |
| **Pod address-block reservations** `.64`–`.239` in both private subnets; old mixed-mode node replaced | infra `vpc-reservations.tf` (#40); `kubectl delete nodeclaim` | `subnet-blocks.sh`: 8 + 3 free blocks; `InsufficientCidrBlocks` errors stopped 12:27 UTC 29 Sept |
| **`scripts/subnet-blocks.sh`** — read-only map of every /28: free, in use, blocked by what; exit 0/1/2 | infra `scripts/` | used to find and to verify the fix |
| **Daily Vault Raft snapshot → S3** (02:00 UTC CronJob, own Argo app, Pod Identity put-only role) + `VaultSnapshotMissing` (> 26 h) | gitops `platform/vault/snapshot/` (#51); infra `vault.tf` (#36) | 3 objects in S3 (manual, scheduled 02:00, pre-sleep); alert inactive |
| **Restore drills**, scripted and run: Vault into a scratch container on the laptop; RDS point-in-time to a second instance, compared from a Job in the cluster, deleted | infra `scripts/drill-*.sh`, `RESTORE_DRILL.md` (#39, #42) | **Vault PASS 41 s · RDS PASS, RPO 261 s, RTO 13 min** |
| **CloudTrail** (all regions, 90 d, private bucket) + **KMS key-deletion alarm** → SNS | infra `cloudtrail.tf`, `vault.tf` (#36) | CloudTrail gave the root cause on 29 Sept |
| **Sleep/wake v3** — pause Argo from `root` down and prove it held; snapshot first; healthchecks pause; poll EC2 to 0 | infra `scripts/platform-*.sh` (#37) | **sleep PASS, 21 min, 0 instances** · wake not run |
| **Cloudflare Access** in front of jenkins/sonar (active), apps for prometheus/alertmanager/argocd; GitHub webhook bypass scoped to `/github-webhook/` | Cloudflare console (by hand) | `/login` → 302; `/github-webhook/` → 405/400 from Jenkins; traversal paths → 302 |
| **Access token verifier** `edge-auth/access-verify` ×2 — stdlib Python, 26 tests, image by digest, NetworkPolicy in-from-Traefik only; one `forwardAuth` Middleware per namespace | gitops `platform/edge-auth/` (#52) | real Cloudflare keys loaded; no token → 401; **not attached to any Ingress** |
| **Hygiene** — Karpenter pricing series dropped (225 k → 199 k), LBC diff ignored, Vault `RollingUpdate` + Reloader on its config, Access-aware probes | gitops #50 | Argo 0 OutOfSync at rest |
| **Cost** — EKS control-plane logs off; **EKS add-on versions pinned**; Jenkins CPU request 500m → 150m from measurements | infra `main.tf` (#41); gitops #53 | logging `enabled: false`; plan for logs showed only the logs once pinned; verifier 2/2 |
| Docs — 4 runbooks new or rewritten, checklist reconciled, `PLATFORM_OVERVIEW.md` (untracked) rewritten with journeys, incidents, self-test | infra `docs/` | — |

## How it was reached — the loops

| # | Symptom | Cause | Fix / rule |
|---|---|---|---|
| 1 | Node roll for prefix delegation failed `PodEvictionFailure`; **Vault down 39 min** | CNI mode changed on running nodes in the same apply as the roll; old node could not give out addresses; Vault's volume is zonal so it could only go to that node | forced drain, re-apply; **rule:** cordon old nodes first, blue/green node groups (`VPC_CNI_MODE_CHANGE.md`) |
| 2 | Snapshot Job `invalid role name` | the Vault role from the night of loop 1 was never created (Vault was down); the PR said "already done" | role created, run again; **a prerequisite is done when its output was read** |
| 3 | `CronJob not found` right after merge | Argo had not created the app yet (two-step: `root` → app) | wait for the resource before acting on it |
| 4 | Sleep v2 would have been reverted | `root` (selfHeal) owns the child Applications and restores their `automated` | pause `root` first; verify the pause for 45 s before scaling anything |
| 5 | `vault-0` did not restart after #50 | only the StatefulSet's strategy and annotation changed, not the pod template | expected; Reloader now handles config changes |
| 6 | Drill script: Python f-string quoting; comparison died silently when databases differed | this Mac's Python; busybox `diff` output format | both caught by local tests before the PR — **test with dummy data first** |
| 7 | api/web on 1 replica for 170 min; critical alert unread for 2 h 40 min; same alert had fired 24 Sept and resolved | new node got no /28: **144 free addresses, 0 free blocks** (CloudTrail `InsufficientCidrBlocks`) | reservations, node replaced; **a resolved critical alert still needs a cause** |
| 8 | Verifier's second replica Pending | system node **100 % requested, 12 % used**; Jenkins 500m for 3m of use | measure requests; Jenkins 150m |
| 9 | Plan for "logs off" showed **7 to change**, incl. the VPC CNI add-on | add-ons unpinned (`most_recent = true`) | pinned all five; **read the plan, not its last line** |
| 10 | `grep -E` failed in Adebayo's shell | zsh aliases `grep` to ripgrep | commands in runbooks use `command grep` or no grep |

## Findings

**㊺ — CNI mode changes hit every running node at once** (23 Sept), and **with prefix delegation, count
free blocks, not free addresses** (29 Sept, proven). Record, correction and procedure in
`VPC_CNI_MODE_CHANGE.md`. The 23 Sept write-up first called fragmentation "not supported"; six days
later it was the proven cause in the same subnet. *"Not proven" is not "ruled out".*

**㊻ — System nodes are full on requests, empty on usage.** 1930 m of 1930 m requested, 145 m used
(p95, 6 days). Requests were chart defaults; nobody measured. Jenkins fixed; Vault (250 m for 3 m),
Karpenter, Kyverno are follow-ups, one restart each.

**㊼ — EKS add-ons followed "most recent".** Any apply touching the cluster could have upgraded the
VPC CNI without a decision. Pinned. Same rule as the AMI.

**㊽ — Control-plane logs were 13 % of the bill.** 3.5 GB/day to CloudWatch, read by nobody, on by
module default. Found only by reading Cost Explorer by *usage type*. Monthly habit in `COST_CONTROLS.md`.

**㊾ — A critical alert resolved by itself and was closed by nobody** (24 Sept, 48 min). The cause
came back five days later for 170 min. `ALERTS.md` now says: if `DeploymentReplicasMissing` resolves
on its own, find the cause before closing.

## Measured

| What | Value |
|---|---|
| RDS RPO / RTO | 261 s / 13 min (drill instance deleted after) |
| Vault restore | 41 s; snapshot 687 min old at the time |
| Sleep to 0 instances | 21 min; spot nodes gone in 1 min, RDS stopped in 8, system nodes in 17 |
| Node drain 29 Sept (old node replaced) | 0 failed external probes; Redis down ~2 min |
| Prometheus head series | 225 k → 199 k after the Karpenter drop |
| System node CPU, p95 over 6 days | 145 m and 151 m of 1930 m |
| Cost run-rate | $13.57/day (22–28 Sept) → ≈ $11.9 with logs off; asleep ≈ $4.5–5 |

## Deferred (ADR-023)

Wake rehearsal (next session) · attach the verifier to Sonar, then Jenkins with the `/github-webhook/`
exemption · Ingresses for Prometheus, Alertmanager, Argo CD · Vault config in Terraform (`vault`
provider) · larger node subnets (a /24 has 14 usable blocks; 5 nodes need 10–13) · alert on the CNI's
`awscni_aws_api_error_count` · Blackbox 2 replicas + `absent(probe_success)` · PDBs
`unhealthyPodEvictionPolicy: AlwaysAllow` (done for the verifier only) · right-size Vault, Karpenter,
Kyverno requests · database cut-over rehearsal · `audit` control-plane log back on before go-live ·
Savings Plan · SLOs · developer items (`hide_input_in_errors`, orphaned Cloudinary file, Sentry) ·
`/app/uploads` emptyDir removal and migration Job `envFrom` (developer handover item 3).

## Verification

`subnet-blocks.sh` → `RESULT: ok` · 3 snapshots in S3, `VaultSnapshotMissing` inactive · drill logs
in `RESTORE_DRILL.md` · sleep: 0 instances, RDS stopped, 5 apps paused with policies saved, 10
volumes kept · `aws eks describe-cluster … logging` all types `enabled: false` · verifier 2/2, one per
system node, `/readyz` 200, no token → 401 · Argo 32/32 Synced+Healthy before sleep.

## Rollback

Each piece is its own PR; revert and (for infra) apply. Reservations: deleting them frees nothing
in use and blocks nothing. Snapshot CronJob: Argo prunes it, S3 objects stay 30 days. Verifier:
delete `bootstrap/apps/edge-auth.yaml`; nothing references its Middlewares. Logs: revert restores
logging from that moment; the gap is not backfilled. Sleep: `platform-wake.sh` from any state.
