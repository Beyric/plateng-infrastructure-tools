# SOP — Admin identity API release (Weysure-API #61, migration `b7d2e9a41c63`)

**Shipped:** 2026-10-10 20:11 UTC · **PR:** Weysure-API #61 (merge `f990527`, image `f99052762224`) · **Cost delta:** $0 ·
Related: developers' note `weysure/docs/platform-note-2026-10-10-admin-identity-api.md`, our reply
`platform-reply-2026-10-10-admin-identity-api.md`, previous release [withdrawal re-check](2026-10-10-withdrawal-recheck-release.md)

**Status: shipped and verified in production.** Alembic head `b7d2e9a41c63`; post-rollout count 0; 0 errors.
First release in three to merge only after "platform ready".

## What shipped (developers)

| Piece | Where |
|---|---|
| Migration `b7d2e9a41c63` (parent `9f1d6a2b8e47`, single head): `kyc_records.reviewed_by_admin_id` / `review_decision` / `review_reason` / `reviewed_at`, `users.identity_set_by_admin_id` (FKs `ON DELETE SET NULL`), `admin_audit_logs.admin_id` nullable, two indexes, backfill from `admin_audit_logs` | `app/alembic/versions/b7d2e9a41c63_admin_identity_api.py` |
| System audit rows (`admin_id IS NULL`) for automatic withdrawal refunds (worker, webhook) | `app/services/admin_audit.py`, `app/worker/handlers/withdrawals.py` |
| JSON log lines from `api-worker`: `{"event": "withdrawal_unresolved", ...}` (ERROR), `{"event": "withdrawal_refunded_by_recheck", ...}` (WARNING) | live capture `docs/fe-integration-guide-captures/admin-identity/11-log-unresolved.json` |
| Admin identity endpoints (review history, admin-set tier marker) | `docs/fe-integration-guide-admin-identity.md` |

## How (platform review, key decisions)

| Point | Finding |
|---|---|
| Expand-only | nullable columns, dropped NOT NULL, indexes, FKs on small tables; normal PreSync step, no window |
| Backfill | `admin_audit_logs.details` is `Text`, so `json.loads` parses it (a JSON column would have made every row a silent skip) |
| Env / secrets / egress | none |
| **Rollback (correction to the developers' note)** | The note said "image revert is safe". In our pipeline an old image's PreSync `alembic upgrade head` fails on a database at an unknown newer revision (proven 2026-10-05). Real order: downgrade with the **new** image, then revert the image ([DEPLOYMENT_ROLLBACK](../runbooks/DEPLOYMENT_ROLLBACK.md)). The downgrade refuses once a system audit row exists, so after the first automatic refund rollback is **fix-forward only** (accepted: pre-launch, small blast radius) |
| Lock timeout | `app/alembic/env.py` sets no `lock_timeout`; suggested 5 s to the developers (non-blocking) |

## Verification (2026-10-10)

| Check | Result |
|---|---|
| Merge → promote | merged 19:49:54 UTC → `f99052762224` in `images.yaml` 20:07:58 |
| Migration (Loki, container `migrate`) | `Running upgrade 9f1d6a2b8e47 -> b7d2e9a41c63, Admin identity API…` |
| `db-oneoff.sh f99052762224 alembic "current"` | `b7d2e9a41c63 (head)` |
| Post-rollout count (reviews resolved on an old pod during the roll; developers' query) | **0**, so the idempotent UPDATE was not needed |
| Pods | api ×2, api-scheduler, api-worker on the tag by 20:11:46, 0 restarts |
| Errors since 20:07 (api, api-scheduler, api-worker) | none; `jobs_stats` `"dead": 0` |
| Argo / sites | weysure-api, -prod, -web Synced/Healthy; web, api `/`, `/api/v1/health` 200 |

Seen during the roll (not errors): surge pods hit `FailedCreate … exceeded quota: weysure-prod … limits.cpu=8`, so the
rollout ran one-out-one-in (~2 min slower); first-boot startup-probe timeouts, then healthy. Quota is a deferred
follow-up in the checklist.

## Operate / roll back

- Before the first system audit row: `scripts/db-oneoff.sh f99052762224 alembic "downgrade 9f1d6a2b8e47"` (quiet
  window), then revert the promote commit.
- After it: fix forward, or ask the developers to export/reassign the system rows first (their downgrade refuses).
- System rows count: `SELECT count(*) FROM admin_audit_logs WHERE admin_id IS NULL` (PII-free).

## Follow-ups

- Loki alerts `WithdrawalUnresolved` (critical) / `WithdrawalRefundedByRecheck` (warning) on the new log lines (gitops).
- Quota surge headroom in `weysure-prod` (checklist, deferred).
