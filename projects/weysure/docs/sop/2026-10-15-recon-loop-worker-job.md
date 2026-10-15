# SOP — Weysure-API #68 (wallet reconciliation as one worker job) live; alerts follow it

**Shipped:** gitops #76 (step 1: flags on `api-worker`, `WalletLotDrift` reads `api-worker`) merged, worker reloaded
18:32 UTC → #68 merged 18:37:54 UTC (`92500e3`, `7249abf`; same tree as the approved `4a5ca24`) → image `7249abff973c`,
all four workloads Ready 19:07:30 UTC → gitops #77 `WalletReconciliationMissing` · **Kind:** developer release (no
migration) plus two monitoring/config gitops PRs · **Cost delta:** $0 (`api-scheduler` scale-down later saves one pod)
· Developers' notes: `weysure/docs/platform-note-2026-10-13-recon-loop.md`, `platform-note-2026-10-15-68-live.md`; our
reply: `platform-reply-2026-10-15-68-go.md`

## Why

The wallet reconciliation ran as an asyncio loop inside the web app: one copy per gunicorn worker of every pod where the
flag was on (prod: 2 copies in `api-scheduler`). It logged nothing on a clean run, so a dead loop was invisible.

## How

| Piece | Change |
|---|---|
| #68 | Loop removed from `app/main.py`. New recurring job `wallet.reconciliation` (one row, `SKIP LOCKED`, requeues itself every `WALLET_RECONCILIATION_INTERVAL_MINUTES`); a startup sweep seeds it when the flag is on. One INFO line per run. The shutdown hook is gone (closes the `CancelledError` follow-up from #69) |
| gitops #76 (before #68) | `api-worker` env: flag `true`, interval 30, cooldown 60 (the old worker image ignored them). `WalletLotDrift` selector `api\|api-scheduler` → `+api-worker`: **found in review**, otherwise the drift alert would have gone blind after #68 |
| gitops #77 (after #68) | `WalletReconciliationMissing`: no `wallet reconciliation: ` line on `api-worker` for 75 min (2 intervals + slack) → warning. Couldn't ship earlier: it would have fired before the line existed |
| `api-scheduler` | Kept, flag still `true`, so rollback is a one-step image revert. It now runs no loop |

## Verification

| Check | Result |
|---|---|
| Merged = approved | `git diff 4a5ca24 7249abf` empty |
| Step 1 | `api-worker-config` 3 keys; worker env shows them (restarted 18:32 UTC); ruler loaded the new `WalletLotDrift` query (`inactive`/`ok`) |
| Rollout | api ×2, api-scheduler, api-worker on `7249abff973c`, Ready 19:07:30 UTC, 0 restarts |
| First run | `19:05:52 wallet reconciliation: 1 users, 0 mismatches` on `api-worker`; 0 reconciliation lines on `api` / `api-scheduler` |
| Job table (counts, `db-oneoff.sh 7249abff973c read`) | exactly one `pending` row, `run_at` 19:35:52 UTC (= +30 min) |
| Startup | only `PAYSTACK_SECRET_KEY is not set to a live key` (expected since the 10-15 key rotation); 0 ERROR/Traceback |
| Alert tests | `loki-rules-wallet-test.sh`: 10 scenarios + delivery PASS (Loki 3.6.11) |

## Operate / roll back

- Stop the check without a deploy: set the worker flag `false` (gitops); the job ends at its next run.
- Roll back #68: first cancel the job (`UPDATE jobs SET status='cancelled', completed_at=now() WHERE kind='wallet.reconciliation' AND status IN ('pending','paused')` via `db-oneoff.sh <tag> write`), then revert the image to `28e48768d0cd`. `api-scheduler` restarts the old loop (flag still `true` there).
- Runbook: `runbooks/ALERTS.md#walletreconciliationmissing`.

## Follow-ups

1. **~2026-10-18:** scale `api-scheduler` to 0 (gitops), and remove it a few days later along with its ConfigMap keys.
2. Alert cooldown stays in process memory (per worker pod). Fine with one worker; revisit if the worker scales out.
