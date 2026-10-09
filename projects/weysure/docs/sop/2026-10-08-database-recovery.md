# SOP — Database recovery after a failed wake (2026-10-08)

**Shipped:** 2026-10-08 · **PRs:** gitops #64 (dbHost) · infra #53 (Terraform import), #54 (scripts, runbooks),
#55 (this: clean-up + SOP) · Vault `database/config/weysure` by hand ·
**Cost delta:** ≈ $0 (db.t3.micro ≈ db.t4g.micro); the old instance costs ≈ $2–3/mo (storage) until deleted ·
Runbooks: [SLEEP_WAKE](../runbooks/SLEEP_WAKE.md) → *RDS cannot start*, [RESTORE_DRILL](../runbooks/RESTORE_DRILL.md)
→ *Real recovery — source instance cannot start*

**Status: recovered and reconciled.** API back 13:01 UTC; Terraform `No changes` 14:30 UTC. Open: delete the old
instance once it can start (AWS auto-starts it 2026-10-13).

## What happened

| UTC | Event |
|---|---|
| 2026-10-06 23:22 | Platform asleep (sleep v3): apps at 0, then RDS `weysure-postgres` stopped |
| 2026-10-08 ~10:00 | Wake v4. Step 1: `StartDBInstance` → **`InsufficientDBInstanceCapacity`** (db.t4g.micro, us-east-1a). The script printed the old status and continued; step 6 waited for a database that was not starting |
| | The PreSync migration Job could not reach the DB → Argo never started api/scheduler/worker (no crash loops) |
| 10:11 → 12:07 | 24 start attempts, 5 min apart: all refused |
| 12:20 | Restore as db.t4g.micro: refused — "no Availability Zones with sufficient capacity" |
| 12:22 | Restore (point-in-time, latest = 2026-10-06 23:09:30) as **`weysure-postgres-v2`, db.t3.micro** → accepted; us-east-1b; available 12:55 |
| 12:59 | Vault `connection_url` → v2 (`verify_connection` passed); test credential minted; gitops #64 merged |
| 13:00 | `weysure-api` was still retrying the old commit's failed sync; operation terminated; new commit synced |
| **13:01** | **API back**: migration no-op, 4 pods, 0 errors |
| 13:16–13:20 | Clean-up: failed snapshot Jobs removed, fresh Vault snapshot; `alloy`/`node-exporter` Pending on a 99 %-requested system node → cordon, move one pod, uncordon; all alerts clear |
| 14:13 | Weysure-API PR 3 (#46) merged and rolled out on v2 (migration `e7b2d4a9c1f6`) |
| 14:20–14:30 | Terraform: old instance `state rm`, v2 imported (two targeted applies), `No changes` |

**Data loss:** none expected — restore point 23:09:30, the sleep had scaled the apps to 0 before stopping RDS.
**Outage:** ≈ 3 h (2 h waiting for AWS capacity).

## Why

A stopped RDS instance keeps only its EBS volume; AWS terminates the host. Starting asks for a new host of
**that class in that AZ** (the volume is zonal). db.t4g.micro was exhausted in both our AZs. A stopped instance
cannot be modified (AWS docs), so its class could not be changed and it could not be renamed or have deletion
protection removed. The only way out was a copy under a new name, in a class with capacity.

## How — decisions

| Decision | Why | Rejected |
|---|---|---|
| Restore a copy (point-in-time), keep the old instance | the old disk is the original; keep it until v2 is proven | deleting the old instance (impossible while stopped, and unsafe) |
| **db.t3.micro**, no `--availability-zone` | same size/price, different hardware pool; let RDS pick an AZ with capacity | db.t4g.small (+$12/mo) as fallback, not needed |
| Vault first, then gitops | pods ask Vault for credentials; Vault must already mint them on v2 | gitops first (pods would get credentials on the stopped DB) |
| Vault partial update of `connection_url` | keeps the rotated `vault` password — **tested on Vault 1.20.4 in Docker first** (irreversible if wrong) | rewriting the whole config (needs a password nobody knows) |
| Terminate the stuck Argo operation | a retrying operation blocks every newer commit | waiting |
| Terraform: `state rm` + `import` block, rehearsed on a **copy of the state** first | config still described the old instance; renaming `identifier` alone = destroy/create | `terraform apply` with only the identifier changed |
| Pin `db_subnet_group_name` / `parameter_group_name` | the module names them after `identifier`; renaming would replace both while the old instance still uses them | — |
| Two targeted applies (`-target=module.rds`, then full) | the new master-secret ARN was `null` at plan time → IAM policies with `Resource: [null]` | one apply (fails half-way) |

## What's involved

- AWS: RDS `weysure-postgres-v2` (db.t3.micro, us-east-1b, encrypted with the same KMS key, deletion protection,
  7-day backups, PI, logs, autoscaling to 50 GB, managed master secret `rds!db-f174bb4b…`); old `weysure-postgres` stopped.
- Vault: `database/config/weysure` → `connection_url` host `weysure-postgres-v2…` (user `vault` unchanged).
- gitops: `projects/weysure/environments/prod/apps/api/values.yaml` `vaultAgent.dbHost` (#64).
- infra Terraform: `rds.tf` (identifier, pinned group names), `variables.tf` (`db_instance_class` = db.t3.micro);
  `rds-recovery-import.tf` added (#53) and removed (#55).
- infra scripts: `platform-sleep.sh`, `platform-wake.sh` (step 1 retries capacity errors 20 min, then stops), drills (#54).

## Verification

| Check | Result |
|---|---|
| v2 settings vs old | engine 16.13, KMS key, SG, parameter group, subnet group identical |
| Vault | write with `verify_connection` = Success; `database/creds/weysure-app` minted `v-userpass-weysure-…` |
| App | sites 200; migration Job completed; 4 pods, 0 errors; worker sweeps + `jobs_stats` normal |
| `db-oneoff.sh read` on v2 | enum owners `weysure_owner` (also cleared PR 3) |
| Wake step 1 fix | 5 scenarios against a fake `aws`: correct |
| Terraform | rehearsal on a state copy = real plan; after both applies and after removing the import block: **No changes** |
| Monitoring | all alerts clear; RDS alarms now watch v2 |

## Operate / roll back

- Back to the old instance (only if v2 were wrong): needs the old instance running; Vault `connection_url` and
  `dbHost` back, Terraform reverse import. Not expected.
- Next time a start is refused: SLEEP_WAKE.md → *RDS cannot start*.

## Follow-ups

- [ ] **Delete the old instance** once it can start (≤ 2026-10-13 auto-start): compare with v2 (drill comparison),
      `--no-deletion-protection`, delete **with a final snapshot**. It is no longer in Terraform state.
- [ ] Decide whether sleep stops RDS at all (saves ≈ $0.40/day; caused today).
- [x] `priorityClassName: system-node-critical` for `alloy` and `node-exporter` (DaemonSet race at wake) — gitops #65, [SOP](2026-10-09-priority-classes.md).
- [ ] Stable internal DNS name for the database (next swap = one record).
- [ ] Watcher scripts: test their exit condition (two missed "rolled out" today).
