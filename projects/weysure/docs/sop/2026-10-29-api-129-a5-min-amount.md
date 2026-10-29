# SOP — Weysure-API #129 (A5 auto-pause minimum amount) live

**Shipped:** #129 merged 2026-10-29 18:52:09 UTC as a **merge commit** (`main` → `7cd29776`, parents `cdc254f0` + approved head `156f67d5`) →
main build #86 green 19:51 UTC (tests 18:53–19:49) → promoted `7cd2977636b0` (gitops `bb43d95c`) → api ×2 + api-worker Ready 19:56 UTC ·
**Kind:** developer fix, flag-off, **no migration** (alembic head stays `b3f6a9d2c814`) · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-26-a5-min-amount.md`, `platform-reply-2026-10-29-api-129-go.md`,
`platform-reply-2026-10-29-api-129-live.md`.

**Status: live and verified.** Closes the MED finding of our Train 3 API Opus review (A5: no minimum amount on `same_payer` / `refund_ratio`). Method: [Train 3 API](2026-10-26-train-3-api-release.md).

## What it is

| Change | Effect |
|---|---|
| `LIVE_AUTO_PAUSE_VELOCITY_MIN_AMOUNT_NGN` renamed **`LIVE_AUTO_PAUSE_MIN_AMOUNT_NGN`** (default 5000, never set in any environment) | the ₦5,000 per-deal floor (escrow amount, fees excluded) now applies to **all three** rules (velocity, refund ratio, same payer), not only velocity |
| `shadow` logs a developer **once** (per process) until the rule set changes or it stops firing | the 15-minute sweep no longer repeats `[LIVE AUTO PAUSE] shadow: would pause …` for the same developer |
| test fix | fake CAC numbers no longer collide with numbers left on profiles (the 409 flake that failed PR-129 #1) |

Known trade-off (developers' SOP): a per-deal floor means deals kept under ₦5,000 are counted by no rule; the pre-KYB ₦200,000 lifetime cap bounds that. An aggregate threshold is a follow-up if shadow data shows evasion.

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| GO for exact `156f67d5` with no separate Opus review | mode is `off` (unset) in prod, so nothing changes at deploy; the diff is 3 commits on `main` `cdc254f0`, read in full by us; the *enforce* switch gets its own review |
| Setting rename is safe | `LIVE_AUTO_PAUSE_VELOCITY_MIN_AMOUNT_NGN` appears nowhere in gitops or prod config |
| Merge commit with `--match-head-commit` | per-PR commits kept; GitHub enforces the approved SHA |
| Next: `shadow` (about a week) before `enforce` | Adebayo's decision is `enforce`; the Opus finding required the floor on every rule first, and the shadow log shows who would be paused before anyone is |

## Platform findings this release exposed

| Finding | Effect | Action |
|---|---|---|
| Karpenter consolidation (`Evicted: Underutilized`) evicted one api pod and the worker ~1 min after the roll, on a node it then removed | pods restarted on other nodes with startup-probe timeouts (api `/health` 1 s timeout, worker heartbeat file); Ready again in under 2 min; PDB `api` minAvailable 1 kept one pod serving | **open decision:** exempt api/worker from voluntary consolidation (`karpenter.sh/do-not-disrupt`) or give the startup probes more time (below) |
| `main` build #86 status flipped `pending` → `none` → `pending` at 19:23–19:24 | none: same build, Jenkins re-posted its status | none |
| API `main` build ≈ 58 min (tests 53 min) | roll lands about an hour after merge | pytest-xdist is the real fix (checklist, CI speed) |

## Verification (live, 2026-10-29)

| Check | Evidence |
|---|---|
| Merged tree | `7cd29776` parents `cdc254f0` + `156f67d5` = GO commit; PR-129 #2: 5586 passed, 3 skipped, Sonar gate PASSED, gitleaks 0, Trivy CRITICAL passed, black clean |
| Pods | api ×2 + api-worker on `7cd2977636b0`, Ready, 0 restarts (the watcher's 3/3 at 19:56:58; consolidation then replaced one api pod and the worker, all Ready again) |
| Migration | migrate Job log has `Context impl PostgresqlImpl` and `Will assume transactional DDL` only: no `Running upgrade` |
| Flags (`[FLAGS]`, api and worker) | unchanged: `LIVE_AUTO_PAUSE_MODE=off`, `ORIGIN_RULES_ENFORCED=true`, `WS_ALLOW_URL_TOKEN=false`, `RISK_HOLDS_MODE=off`, `CHARGEBACKS_MODE=off`, `REFUND_TO_SOURCE_ENABLED=false`; reconciliation scheduler on the worker only |
| Guards / errors | no `[BOOT GUARD]`; 0 error or traceback lines (old-pod SIGTERM excluded); 0 `[LIVE AUTO PAUSE]` lines (mode off) |
| Health | `api.weysure.com/api/v1/health` 200, `weysure.com` 200, Argo 29 Synced Healthy + 3 Progressing at the first look (api settling after the consolidation; `alloy` and `kube-prometheus-stack` still Progressing a minute later, cause not checked) |

## Operate / roll back

- Rollback is image-only: gitops `images.yaml` `api.tag` back to `cdc254f0a78e` (no migration). Mode stays `off`.
- Switching the pause on is a separate change: `platform-note-2026-10-2x-live-auto-pause-enforce.md` (shadow, read the log, then enforce; `LIVE_AUTO_PAUSE_MODE` in the api and worker ConfigMaps, Reloader rolls).

## Follow-ups

- [ ] Review the enforce note; offer `shadow` first (a week); run its pre-switch read (counts only).
- [ ] Decide on consolidation vs prod API pods (do-not-disrupt on api/worker, or longer startup probes); three consolidation or spot-reclaim events hit prod API pods on 2026-10-29.
- [ ] Optional: aggregate threshold for sub-₦5,000 deals if shadow data shows evasion (developers).
