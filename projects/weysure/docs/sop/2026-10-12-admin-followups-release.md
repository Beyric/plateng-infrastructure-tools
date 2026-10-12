# SOP — Admin API follow-ups release (Weysure-API #63, migration `c9a4e1b7d230`)

**Shipped:** 2026-10-12 13:14 UTC · **PR:** Weysure-API #63 (merge `fd482c7`, image `fd482c787ca5`) · **Cost delta:** $0 ·
Related: developers' note `weysure/docs/platform-note-2026-10-10-admin-api-followups.md`, our reply
`platform-reply-2026-10-12-admin-api-followups.md`, previous release [admin identity](2026-10-10-admin-identity-release.md)

**Status: shipped and verified in production.** Alembic head `c9a4e1b7d230`; 0 errors. Second release in a row merged
only after "platform ready", and the first with an agreed order for the next ones (#63 → #62 → web #47).

## What shipped (developers)

| Piece | Where |
|---|---|
| Migration `c9a4e1b7d230` (parent `b7d2e9a41c63`, single head): new table `admin_notification_states` (per-admin `read_at` / `dismissed_at`, FKs `ON DELETE CASCADE` to `admin_notifications` and `admins`, composite PK, index on `admin_id`). Expand-only, no backfill | `app/alembic/versions/c9a4e1b7d230_admin_notification_states.py` |
| **`lock_timeout` 5 s for every online migration** (our 10-10 suggestion): `-c lock_timeout=5000` appended to any `options=` in `DATABASE_URL` | `app/alembic/env.py` |
| Downgrade safe with data: folds per-admin state back into `is_read`, deletes shared rows every active admin dismissed, then drops | same migration |
| App-only: per-admin notifications, 422 on bad admin filters, deal history, dispute refund ledger type `refund` | `docs/fe-integration-guide-admin-followups.md` (Weysure-API) |

## How (platform review, key decisions)

| Point | Finding |
|---|---|
| Expand-only / locks | `CREATE TABLE` + two FKs: short `SHARE ROW EXCLUSIVE` on two small tables; normal PreSync step, no window |
| `options=` in prod `DATABASE_URL` (developers' question) | none: the chart's Vault Agent template renders `postgresql://…@host:port/db?sslmode=…` (`plateng-gitops charts/beyric-app/templates/_helpers.tpl:31`). Answered from git; the Secret was not read |
| **Retry (correction to the developers' note)** | The note said a failed Job is retried. Our migration Job has `backoffLimit: 0` (`charts/beyric-app/templates/migration-job.yaml:14`, on purpose) and Argo does not retry a failed sync of the same commit, so a `lock timeout` failure = PreSync fails, old pods keep serving, **we re-sync by hand** |
| Rollback | not an image revert once the migration ran (PreSync on an unknown newer revision fails); downgrade with the new image first. Unlike #61, the downgrade does not refuse, so a real undo path exists |
| Release order | one at a time, migration release alone: #63 → verify → #62 (no migration) → web #47 |

## Verification (2026-10-12)

| Check | Result |
|---|---|
| Merge → promote | merged 12:50:47 UTC → `6f5d203 promote fd482c787ca5` 13:09:31 (~19 min) |
| Migration (Loki, container `migrate`) | `Running upgrade b7d2e9a41c63 -> c9a4e1b7d230, Per-admin read and dismissed state…`; Job `weysure-api-db-migrate` succeeded |
| `db-oneoff.sh fd482c787ca5 alembic "current"` | `c9a4e1b7d230 (head)` (13:21 UTC) |
| Pods | api ×2, api-scheduler, api-worker on the tag by 13:14:58, Ready, 0 restarts |
| Errors since 13:10 (api, api-scheduler, api-worker) | none (only gunicorn INFO `Error while closing socket` from old pods shutting down: normal) |
| Argo / sites | 32/32 Synced/Healthy 13:16; web and `/api/v1/health` 200 |

Seen during the window (not caused by the release):

- **Quota again:** api-worker surge pods `FailedCreate … exceeded quota: weysure-prod … limits` from 13:13:12, so the
  roll ran one-out-one-in. Second release in a row; deferred item now has two data points.
- **Spot interruption at ~12:43 UTC** (before the merge): node `ip-10-0-4-17` reclaimed. One web replica moved instantly;
  `redis-0` took ~1 min (`FailedAttachVolume`: EBS volume still attached to the dead node). Afterwards every api pod and
  both web replicas sat on one spot node (`ip-10-0-3-32`), which is the accepted 09-29 risk but at its worst case.
- **Web #46** (tests only) merged 13:01 and promoted 13:11 inside the watch window (`b890f520dd11`, rolled 13:15). No
  runtime change, but two promotes at once muddy the evidence: ask developers to hold unrelated merges during a
  migration rollout.

## Operate / roll back

- `scripts/db-oneoff.sh fd482c787ca5 alembic "downgrade b7d2e9a41c63"` (quiet window; per-admin dismissals that not every
  admin made may reappear), then revert the promote commit `6f5d203`. Order and commands: [DEPLOYMENT_ROLLBACK](../runbooks/DEPLOYMENT_ROLLBACK.md).
- PreSync failed with `lock timeout` / `canceling statement due to lock timeout`: nothing changed (transactional DDL).
  Find the holder in Loki/RDS, wait for it to finish, then re-sync `weysure-api` (terminate a stuck retry first, handoff §7).

## Follow-ups

- Weysure-API #62 (identity UX, no migration) then web #47: next in the agreed order. `IDENTITY_RELEASE_ENABLED` stays
  unset in prod (Adebayo, 2026-10-12); `EMAILS_FROM_EMAIL` switch is a separate change after the developers confirm the
  SMTP account and an MX for `weysure.com`.
- Quota surge headroom; topology spread for api/web across nodes (checklist, deferred).
