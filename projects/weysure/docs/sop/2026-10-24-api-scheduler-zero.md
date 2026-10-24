# SOP — `api-scheduler` stopped (`replicas: 0`)

**Shipped:** plateng-gitops [#89](https://github.com/Beyric/plateng-gitops/pull/89), merged 2026-10-24 (`4091931`), synced 13:36 UTC ·
**Kind:** prod values · **Cost delta:** frees 120m CPU / 416Mi of requests, 0.6 CPU of limits

**Status: live and verified 2026-10-24 13:36 UTC.**

## Why

`api-scheduler` existed to run the wallet reconciliation loop in the API lifespan. Weysure-API #68 (live 2026-10-15) moved that loop into
`api-worker` as the `wallet.reconciliation` job. Since then the pod has been an idle second copy of the API with no Service. The
developers confirmed this (`weysure/docs/platform-note-2026-10-24-scheduler-overlap.md`) when we asked about two schedulers overlapping
during a roll.

## Verified before the change

| Claim | Evidence |
|---|---|
| No timer in the API | `app/main.py` on `main` (and Train 1b, per the developers) has no loop or timer |
| Only the worker reads `WALLET_RECONCILIATION_SCHEDULER_ENABLED` | `git grep`: `app/worker/handlers/wallet_reconciliation.py` only |
| Worker overlap is safe | claim `FOR UPDATE SKIP LOCKED` (`app/worker/runner.py`) + partial unique index `uq_jobs_live_dedupe_key` |
| Worker does the work | Loki: `wallet reconciliation: 4 users, 0 mismatches` every 30 min (13:14 UTC) |
| Scheduler idle | Loki 24 h: no requests; only boot lines and `[FLAGS]` (the 16 "reconcil" hits were the flag name in that line) |
| Alerting unaffected | `WalletLotDrift` selects `container=~"api|api-scheduler|api-worker"` |

## What changed

`projects/weysure/environments/prod/apps/api/values.yaml`: `api-scheduler.replicas: 1 → 0` (+ comment). `charts/beyric-app/tests/render-test.sh`
asserts it renders 0. Rendered diff: that single line.

## Verification

Argo `weysure-api` on `4091931`, Synced/Healthy; Deployment `api-scheduler` 0 desired / 0 pods; quota `limits.cpu` 4300m/10, `requests.cpu`
910m/4; Argo 32/32; `weysure.com` 200, `api.weysure.com/api/v1/health` 200.

## Operate / roll back

- Roll back: `replicas: 1` (revert #89). The pod starts on the current image; the Deployment and `api-scheduler-config` ConfigMap stay.
- Do not scale it with `kubectl`: `selfHeal` is off, so the next sync would undo it. Stop and start it in git.

## Follow-ups

- Remove the `api-scheduler` component (Deployment, ConfigMap, NetworkPolicy selector entries, the alert's container regex, the quota
  comment) once Train 1b and Train 2 are live. The developers will flag anything in the trains that relies on it.
