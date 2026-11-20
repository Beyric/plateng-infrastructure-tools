# SOP — nightly encrypted off-AWS database backup (Google Drive)

**Shipped:** gitops [#108](https://github.com/Beyric/plateng-gitops/pull/108) (branch `feature/prod-db-offsite-backup`) — **open, not merged, not live** · this docs PR ·
**Kind:** new CronJob + one-shot role Job + ExternalSecret + NetworkPolicy + alert (no image change, no migration) · **Cost delta:** ~$0 (Drive space only)
Runbook: [DB_OFFSITE_BACKUP.md](../runbooks/DB_OFFSITE_BACKUP.md) · proof log: [evidence/2026-11-20-db-offsite-backup-proof.txt](../evidence/2026-11-20-db-offsite-backup-proof.txt)

**Status: built and proven locally; live only after Adebayo writes Vault `secret/weysure/backup` and merges #108.**

## Why

Nothing was copied off AWS. The owner (2026-11-20) wants a daily copy he holds outside AWS (Google Drive) so he can migrate to another cloud at any time without losing
data, ahead of real money going through prod. RDS snapshots (7 days, PITR) stay as the fast in-AWS recovery path; this is the exit path.

## How, and the decisions

| Decision | Choice | Rejected / why |
|---|---|---|
| Dump | `pg_dump --format=custom --compress=6 --no-owner --no-privileges` as read-only role `weysure_backup` | physical backup (not portable across providers); zstd (not every `pg_restore` has it) |
| Encryption | `age` to the owner's **public** key; plaintext is a pipe, only ciphertext touches the emptyDir | symmetric encryption (key would live in the cluster); rclone `crypt` (same reason) |
| Tools | no custom image: official `postgres` image + age release binary verified against a **pinned sha256** (amd64 + arm64) + official `rclone` image; two stages in one pod over an emptyDir | custom ECR image (needs Terraform repo, build job, push: more steps, no repo convention for tool images); unverified third-party age image (it would see the whole plaintext) |
| Scripts | in ConfigMap `weysure-db-backup-scripts`, so the tested text is the running text | inline in the CronJob |
| Drive | own Google OAuth client (rclone's shared one is retiring during 2026), scope `drive.file`, consent screen **published** (Testing expires grants in 7 days); folder made by rclone | service account (cannot write to personal My Drive); full `drive` scope (bigger blast radius) |
| Retention | `daily/` 30 days, `monthly/` first object per calendar month, 366 days; pruning only after size + MD5 verified on Drive; matches only `weysure-*.dump.age` | — |
| DB login | static role `weysure_backup`: SELECT on tables/sequences, default privileges of `weysure_owner` for later tables, `default_transaction_read_only=on`, 3 connections; created by one-shot Job `db-backup-role-v1` as the RDS master (Secrets Manager, Pod Identity `db-bootstrap`) with a self-check | `pg_read_all_data` (relies on RDS granting it to the master: unverifiable); Vault dynamic role (needs new Vault policy + k8s role by hand) |
| Secrets | one Vault path `secret/weysure/backup`, `dataFrom.extract`, per-key `secretKeyRef` | `envFrom`; reusing `weysure/prod` (it is the app's env contract) |
| Network | `db-backup-egress`: 5432 to the VPC, 443 to anything outside it. VPC CNI policy is IP-only and Google's ranges cannot be listed | FQDN allowlist (needs an egress proxy or another CNI) |
| Node | `node-role: system` (always present, like `vault-snapshot`; multi-arch images so arm64 works) | workload spot nodes |
| Alert | `WeysureDbBackupMissing` (warning): 26 h after the last success, or 26 h after CronJob creation if it never succeeded; `for: 30m` | `vector(0)` pattern (always fires); kube `KubeJobFailed` still covers a failed Job |
| Role Job ordering | Argo sync-wave 1, after the ExternalSecret is Ready | — |

## What's involved

| Path (plateng-gitops) | What |
|---|---|
| `projects/weysure/environments/prod/backup/db-backup-cronjob.yaml` | ServiceAccount `weysure-db-backup` + CronJob (`30 2 * * *` UTC, Forbid, deadline 1 h, backoff 1) |
| `…/backup/scripts-configmap.yaml` | `dump-encrypt.sh`, `upload-retain.sh` (age version + hashes live here) |
| `…/backup/db-backup-role-v1-job.yaml` | one-shot role + grants + self-check |
| `…/backup/externalsecret.yaml` | `weysure-backup` ← Vault `weysure/backup` |
| `…/network/allow.yaml` | `db-backup-egress` |
| `platform/monitoring/alerts.yaml`, `tests/prometheus-rules-test.sh` | group `beyric.backup`, 4 promtool scenarios |

Images (digest-pinned): `postgres:16.16-alpine3.23`, `rclone/rclone:1.75.2`, `aws-cli:2.22.35` (role Job only; same as the other db Jobs). age `v1.3.2`.
Vault: new path `secret/weysure/backup` (keys in the runbook); no policy change. Database: role `weysure_backup`. Argo: synced by existing app `weysure-prod` (recurse).
Success line: `BACKUP_OK object=daily/… bytes=… sha256=… md5=… daily_kept=… monthly_kept=…`.

## Verification

| Check | Evidence |
|---|---|
| Role Job, restore, retention, failure cases, alert logic | **proven locally**: see the runbook table and the evidence log (restore into a second fresh Postgres 16: 16/16 checks identical, 80,301 rows) |
| Repo checks | pre-commit all pass; kubeconform strict 0 invalid; Kyverno CLI v1.19.1: 18 pass / 0 fail; promtool: OK |
| **Not exercised** | real Google Drive upload; role Job on real RDS; live admission, ESO sync, Argo order; Slack delivery. First live run (runbook step E) is the test |

## Operate / roll back

- Operate: runbook (setup, restore, troubleshooting, rotation). Quarterly restore test, with the Vault/RDS drills ([RESTORE_DRILL.md](../runbooks/RESTORE_DRILL.md)).
- Roll back: revert #108 (Argo prunes everything). Role `weysure_backup` stays (read-only, harmless); Drive files stay.

## Follow-ups

- [ ] Owner steps: key pair, Google OAuth client + `rclone config`, `vault kv put`, merge, first manual run, first restore test.
- [ ] **Database only.** Add an encrypted export of Vault `secret/weysure/*` (the S3 Vault snapshot is AWS-KMS-encrypted, unreadable elsewhere) and note Cloudinary uploads, for a complete exit.
- [ ] Build a small image (postgres client + age + rclone) in ECR to drop the runtime age download.
- [ ] Name-based egress allowlist (egress proxy or FQDN-aware CNI) for this pod.
- [ ] Raise `activeDeadlineSeconds` / `emptyDir.sizeLimit` when the dump nears 5 GiB or 1 h.
- [ ] Confirm the alert reaches `#beyric-alerts-warning` (never seen firing).
