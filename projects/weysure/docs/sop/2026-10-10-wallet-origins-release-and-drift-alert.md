# SOP — Wallet origins release (verified after the fact) and the `WalletLotDrift` alert

**Shipped:** 2026-10-09 23:52 UTC (app) · 2026-10-10 10:35 UTC (alert) · **PRs:** Weysure-API wallet origins
(main `3504876`, image `3504876c3164`) · gitops #67 (`f465fcd`) · **Cost delta:** $0 ·
Related: developers' notes `weysure/docs/platform-note-2026-10-09-wallet-origins.md`,
`platform-note-2026-10-10-wallet-origins-drift.md`; runbook [ALERTS § WalletLotDrift](../runbooks/ALERTS.md#walletlotdrift)

**Status: shipped and verified in production.** Lots tracked, rules not enforced (`ORIGIN_RULES_ENFORCED=false`);
drift 0; alert loaded and inactive.

## What shipped

| Piece | Where | Owner |
|---|---|---|
| Origin lots (`wallet_lots`) + backfill, migration `9f1d6a2b8e47` (parent `c4a8e1d7b3f5`, single head) | Weysure-API | developers |
| Reconciliation logs `{"event": "wallet_lot_drift", "users": N}` on drift | `app/services/wallet_reconciliation_service.py:221` | developers |
| Loki ruler alert `WalletLotDrift` (critical) | gitops `platform/monitoring/loki-rules-wallet.yaml` | platform |
| Docker end-to-end test (real Loki 3.6.11 + Alertmanager, 5 scenarios) | gitops `platform/monitoring/tests/loki-rules-wallet-test.sh` | platform |
| `ORIGIN_RULES_ENFORCED: "false"` written out (code default is also `False`) | gitops `projects/weysure/environments/prod/apps/api/values.yaml` (`commonEnv`) | platform |
| Runbook section with the PII-free triage query | [ALERTS.md](../runbooks/ALERTS.md#walletlotdrift) | platform |

## Why

Wallet origins splits each wallet balance into lots by where the money came from, so that later only *earned* money
can be cashed out. If lots stop adding up to `wallet_balance`, switching enforcement on would block or allow the wrong
withdrawals. The developers log drift; the platform turns that log line into a page.

## How (key decisions)

- **Rollback = the flag, never an image revert.** A new migration makes an image-only revert fail at PreSync (proven
  2026-10-05). Writing the env var out makes both switch-on and rollback a one-line diff.
- **Alert on the log line, not a DB query in Prometheus** (same reasoning as the jobs alerts, 2026-10-05): no DB
  credential in the monitoring stack.
- **`container=~"api|api-scheduler"`**: the scheduler runs it every 30 min, an admin can run it by hand from the api.
- **`max(max_over_time(… | unwrap users [35m])) > 0`, no `for:`**: one line is a full SQL scan, a confirmed finding.
  `max` not `sum`, because two runs in a window report the same users. `max()` also drops stream labels, so the scheduler
  and api firing together give **one** page (the test asserts this).
- *Known gap:* if reconciliation stops running, the alert is silent (no "missing" rule). Accepted.

## The release, as it actually happened

| UTC | Event |
|---|---|
| 10-09 23:45 | Jenkins promoted `3504876c3164` (developers merged **before** the platform's "ready"; the agreed hold was for the count + alert) |
| 23:49:33 | PreSync `weysure-api-db-migrate` started → **Succeeded** |
| 23:52:54 | Argo `weysure-api` sync Succeeded; last pod (scheduler) up 23:58:48 |
| 10-10 10:27 | Drift check (below): 0 |
| 10:28 | gitops #67 merged (by a developer account, `innocent98`) |
| 10:35 | Argo synced `f465fcd`; api ×2, scheduler, worker rolled (same image), 0 restarts |

The pre-merge backfill count could no longer be run; the post-merge drift query replaces it and is the stronger check
(it proves lots = balances instead of predicting how many users the backfill touches).

## Verification

| Check | Result |
|---|---|
| Migration hook | Argo sync result: Job `weysure-api-db-migrate` Succeeded |
| Pods | 4 on `3504876c3164`, 0 restarts; Argo 32/32 Synced/Healthy; only `Watchdog` firing; sites 200 |
| Logs since 23:40 | 0 `wallet_lot_drift` lines; only rollout `SIGTERM`s as ERROR |
| **Drift** (`db-oneoff.sh 3504876c3164 read`, window 23:49–00:00) | `drifted 0, active_in_window 0, no_activity_in_window 0` → first clean run |
| Rule tests | wallet 6/6 PASS (drift→firing(3), api→firing(1), clean/expired 50m/other event→inactive, AM one critical); jobs 6/6 PASS |
| CI-equivalent | `render-test.sh` OK; `pre-commit` all hooks pass |
| Live ruler | `WalletLotDrift=inactive health=ok`, evaluated 10:35:23 |
| Env | `ORIGIN_RULES_ENFORCED=false` in ConfigMaps `api-config`, `api-scheduler-config`, `api-worker-config` (via `envFrom`) |

## Operate / roll back

- **Alert fires:** follow [ALERTS § WalletLotDrift](../runbooks/ALERTS.md#walletlotdrift). Never `repair_wallets`, never
  edit `wallet_lots`.
- **Switch enforcement on** (later): web PR 7 live + drift 0 → set `ORIGIN_RULES_ENFORCED: "true"` in gitops api values.
  Roll back by setting it to `"false"` again.
- **Remove the alert:** revert gitops #67 (the env value equals the code default, so behaviour does not change).

## Follow-ups

- **Process:** developers merged the release before the platform's go-ahead, and merged platform PR #67 themselves.
  Agree with them that platform PRs are merged by Adebayo, and that a note's "HOLD" ends only with an explicit
  "platform ready".
- **For developers:** gunicorn `--max-requests` (~1030 + jitter) recycles an api-scheduler worker every ~2 h 45 min
  (≈ 1000 kubelet probes); each new worker calls `start_background_jobs`, and with `WEB_CONCURRENCY=2` each pod runs
  **two** reconciliation schedulers. Harmless now (notification cooldown), but scheduled work should run in one process.
- Flag-on is a separate change, with its own note.
