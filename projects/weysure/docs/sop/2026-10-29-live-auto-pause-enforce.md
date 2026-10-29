# SOP — live-key auto-pause switched to `enforce`

**Shipped:** gitops [#93](https://github.com/Beyric/plateng-gitops/pull/93) merged 2026-10-29 20:20:36 UTC (squash `98b394e5`, approved head `5d423cef`) →
Argo `weysure-api` Synced/Healthy on `98b394e5` → Reloader restarted api ×2 + api-worker (Ready 20:25 UTC) → first sweep 20:25:09 UTC ·
**Kind:** config change in prod values (`commonEnv`), no image change (`7cd2977636b0`), no migration · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-2x-live-auto-pause-enforce.md`, `platform-reply-2026-10-29-live-auto-pause-enforce.md`,
`platform-sql-2026-10-29-auto-pause-preswitch.sql`. Code: API #128 A5 and [#129](2026-10-29-api-129-a5-min-amount.md).

**Status: live and verified.** Rolls back with one line (below).

## What it does

`LIVE_AUTO_PAUSE_MODE: "enforce"` (was unset = `off`). Every 15 minutes the worker's `live.auto_pause_sweep` looks at developers who are not paused and not an approved business and have a live (production) deal funded in the last 30 days. A developer is paused (live keys refused with `403 LIVE_ACCESS_PAUSED`, test keys keep working, live payouts wait, in-app notice + email, admin notification + audit row) when a rule fires over deals of **₦5,000 or more**: velocity (10 funded in 60 min), refund ratio (≥ 5 funded and ≥ 50% refunded in 30 days), same payer (5 funded from one email in 30 days). Only a superadmin can resume, with a reason; the look-back never reaches before the last resume.

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| **`enforce` straight away, no `shadow`** (Adebayo, 2026-10-29) | the developers' note suggested a week of `shadow`; the read below showed no developer to learn from, and #129 had already closed the review finding (floor on every rule) |
| Counts-only pre-switch read first | proves what the first sweep will do before it does it |
| Read SQL tested on a throwaway Postgres (seeded cases) before Adebayo ran it | a wrong query would print a false 0 |
| Separate change, not part of a release | Reloader restarts api and worker; a roll next to a release makes blame unclear |
| Proved with a `helm template` diff | exactly 2 ConfigMaps (`api-config`, `api-worker-config`) gain the key; 11 other objects unchanged; no Deployment spec change |

## Verification (live, 2026-10-29)

| Check | Evidence |
|---|---|
| Pre-switch read (21:14 WAT, `7cd2977636b0`, `db-oneoff.sh read`) | developers with live deals ≥ ₦5,000 in 30 d, eligible: **0**; would fire at the first sweep: **0** |
| Merge | #93 squash `98b394e5` = GO head `5d423cef`; Argo `weysure-api` Synced Healthy Succeeded on it |
| ConfigMaps | `api-config` and `api-worker-config` both `LIVE_AUTO_PAUSE_MODE=enforce` |
| Pods | api ×2 + api-worker on `7cd2977636b0`, Ready, 0 restarts, restarted ~20:25 UTC; Argo 32/32 Synced Healthy; `api.weysure.com/api/v1/health` and `weysure.com` 200 |
| `[FLAGS]` | `LIVE_AUTO_PAUSE_MODE=enforce` on api and worker; other flags unchanged |
| Guards / errors | no `[BOOT GUARD]`; 0 error or traceback lines; `jobs_stats` `dead: 0` |
| First sweep | `[WORKER] job … live.auto_pause_sweep rescheduled to 20:40:09` at 20:25:09 UTC; no `[LIVE AUTO PAUSE]` pause line, no failure line |
| Not exercised live | an actual pause (0 candidates); the developers' flags-on e2e is the evidence for that path (`docs/fe-integration-guide-captures/train-3-api/flags-on/`) |

## Operate / roll back

- Roll back: set `LIVE_AUTO_PAUSE_MODE` to `"shadow"` (logs `[LIVE AUTO PAUSE] shadow: would pause …` once per developer, pauses nobody) or `"off"` in `projects/weysure/environments/prod/apps/api/values.yaml`; Reloader restarts api and worker. Keys already paused stay paused until a superadmin resumes them (`POST /admin/users/{id}/live-keys/resume`).
- Watch: `{namespace="weysure-prod",container="api-worker"} |= "LIVE AUTO PAUSE"`; admin notifications `live_keys_auto_paused`.

## Follow-ups

- [ ] The first real pause: confirm the developer gets the email and the admin notification, and that a superadmin resume works in prod (break-glass admin path).
- [ ] Optional Loki alert on a pause (admin notification and audit row exist; no rule added).
- [ ] If shadow-style data is ever wanted, an aggregate threshold for sub-₦5,000 deals is the developers' follow-up.
