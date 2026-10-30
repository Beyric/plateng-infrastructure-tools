# SOP — Loki alerts for the live-key auto-pause

**Shipped:** gitops [#96](https://github.com/Beyric/plateng-gitops/pull/96) merged 2026-10-30 11:45 UTC (`f72d979`); ConfigMap `loki-rules-autopause` created 11:51 UTC in `monitoring` → the Loki ruler loaded both rules ·
**Kind:** observability config (Loki ruler rules), no image change · **Cost delta:** $0 ·
Context: [auto-pause `enforce` live](2026-10-29-live-auto-pause-enforce.md). Runbook entries: `runbooks/ALERTS.md`.

**Status: live and verified.**

## Why

Since 2026-10-29 the worker's 15-minute sweep pauses a developer's live keys when a rule fires (`LIVE_AUTO_PAUSE_MODE=enforce`). A pause is a real customer-facing action, and a sweep that cannot run is a silent gap in fraud control. Neither showed on any channel; they were only in the logs.

## What

| Alert | Severity | Query (container `api\|api-worker`) | Fires when |
|---|---|---|---|
| `LiveKeysAutoPaused` | warning | `\|= "[LIVE AUTO PAUSE] paused live keys of"`, `count_over_time(… [30m]) > 0` | the sweep paused someone: an admin should look at that developer |
| `LiveAutoPauseFailing` | critical | `\|~ "\[LIVE AUTO PAUSE\] (failed for\|sweep failed)"` | a pause could not be applied, or the whole sweep failed: nobody is being protected |

No `for:` on either: one line is enough. Shadow-mode lines (`shadow: would pause …`) deliberately do not match. The log texts are produced by `live_pause.py` (the paused line at `:126`); **the developers must not change them without telling us** (said in the Train 4 GO).

File: `plateng-gitops/platform/monitoring/loki-rules-autopause.yaml` (a ConfigMap; Argo syncs the whole file, the ruler reads it from the ConfigMap volume).

## Verification

| Check | Evidence |
|---|---|
| Test | `platform/monitoring/tests/loki-rules-autopause-test.sh`: Loki 3.6.11 and Alertmanager in Docker, **7 scenarios plus Alertmanager delivery, all passed** (scenarios `paused`, `two` developers paused, `failed`, `sweepfail`, the same text from the `api` container, `shadow` (does not fire), `expired` (older than the 30 min window: does not fire)) |
| Live | both rules listed by the ruler (`/prometheus/api/v1/rules`) and `inactive` at 15:20 WAT 2026-10-30, after Train 4 went live |
| Not exercised live | a real firing in prod (no pause has happened); the Docker test is the evidence |

## Operate / roll back

- Fires: see the `ALERTS.md` entries (what to check, who decides to resume the keys: a superadmin).
- Roll back: revert gitops #96; the ConfigMap is pruned and the ruler drops the rules.
- Change a rule: edit the YAML, run the test script from the gitops root, merge.

## Follow-ups

- [ ] First real firing: confirm it lands in `#beyric-alerts-warning` / `-critical` with the runbook link (not yet seen).
