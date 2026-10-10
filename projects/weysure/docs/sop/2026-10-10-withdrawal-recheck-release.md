# SOP — Withdrawal re-check release (Weysure-API #60), verified after the fact

**Shipped:** 2026-10-10 15:22 UTC · **PR:** Weysure-API #60 (merge `ef17d9f`, image `ef17d9fe9ff2`, promote gitops
`c48fe3d`) · **Cost delta:** $0 · Related: developers' note `weysure/docs/platform-note-2026-10-10-withdrawal-recheck.md`,
our reply `platform-reply-2026-10-10-withdrawal-recheck.md`

**Status: shipped and verified in production.** No migration (head stays `9f1d6a2b8e47`); the startup sweep found
nothing to settle; 0 dead jobs.

## What shipped (developers)

| Piece | Where |
|---|---|
| `POST /wallet/withdraw` commits the debit and the withdrawal **before** calling Paystack | `app/services/user_withdrawal.py` |
| New worker job kind `withdrawal.recheck` (first look after 10 min, admin alert after 3 attempts, max 10) | `app/worker/handlers/withdrawals.py`, `app/services/withdrawal_transfer.py:46` |
| Startup sweep `ensure_withdrawal_rechecks`: schedules a re-check for old `FAILED` withdrawals whose debit is still `PENDING` | `app/worker/__main__.py` |
| Setting `WITHDRAWAL_RECHECK_DELAY_SECONDS` (default 600; app refuses to start below 100) | `app/core/config.py`; **not set** in prod values |
| In-app admin notifications `withdrawal_unresolved` (critical), `withdrawal_refunded_by_recheck` (high) | `admin_notifications.type` |

## Why

The old withdraw path held one transaction across the Paystack call. If anything failed after Paystack accepted the
transfer, the debit was rolled back while the money had still been sent. The fix makes the debit durable first and lets a
worker settle "unknown outcome" withdrawals by asking Paystack.

## How (platform side, key decisions)

- **Platform review before merge:** no migration, no new env/secrets/egress, `api-worker` shares the api tag, dead
  `withdrawal.recheck` jobs are already covered by our Loki `JobsDeadIncreased`.
- **Merged before "platform ready"** (15:00 UTC, third time in a row). The pre-merge count (stranded `FAILED` withdrawals
  with a pending debit) existed to prevent a double payment if support had already paid someone back by hand.
- **Replaced the pre-merge count with evidence of what happened** (same decision as wallet origins, 10-10): the worker's
  startup sweep logged `0 job(s) scheduled`, so it settled and refunded nothing. A DB count after the fact was not
  needed.
- **Alerting:** the two notifications are in-app only in #60. We asked for JSON log lines; they ship in #61
  (`{"event": "withdrawal_unresolved", ...}` ERROR, `withdrawal_refunded_by_recheck` WARNING, from `api-worker`).
  The Loki alerts come after #61 is live.

## Verification (2026-10-10, ~19:40 UTC)

| Check | Result |
|---|---|
| Promote | `ef17d9fe9ff2` in `images.yaml` 15:18 UTC |
| Pods | api ×2, api-scheduler, api-worker on `ef17d9fe9ff2`, started 15:21–15:23, 0 restarts |
| Startup sweep (Loki, api-worker) | `[WORKER] startup sweep ensure_withdrawal_rechecks: 0 job(s) scheduled` at 15:22:22 |
| Dead jobs | 200 `jobs_stats` lines since rollout, all `"dead": 0`; no `JobsDeadIncreased` |
| Errors (api, api-scheduler, api-worker) | none; only gunicorn `[INFO] Error while closing socket [Errno 9]` (benign, worker recycle) |
| Alerts | only `Watchdog` |
| Argo / sites | 32/32 Synced/Healthy; `weysure.beyrictech.com` 200, `weysure-api…/api/v1/health` 200 |

## Operate / roll back

- **Rollback = image revert** of the promote commit (no migration). Rows written by the new code are valid for the old
  code. Since 2026-10-10 20:11 UTC #61 (migration `b7d2e9a41c63`) is live, so an image revert to `ef17d9fe9ff2`
  alone no longer works; see [the #61 SOP](2026-10-10-admin-identity-release.md#operate--roll-back).
- Never re-send a transfer from the Paystack dashboard for a `needs_attention` withdrawal; match by reference
  `wys_withdraw_<withdrawal_id>` (lowercase).
- Off switch: `JOBS_DISABLED_KINDS` is read by the worker (`jobs_stats` shows `disabled_kinds: []`), but it is **not**
  set in any gitops values today; adding it is a values change on `api-worker`.

## Follow-ups

- ~~Loki alerts on the new log lines~~ done: `WithdrawalUnresolved` / `WithdrawalRefundedByRecheck` (gitops #68, live 2026-10-10 20:41 UTC).
- Process: developers merge only after an explicit "platform ready" (HANDOFF §5 item 3).
