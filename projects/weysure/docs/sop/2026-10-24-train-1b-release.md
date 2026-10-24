# SOP — Weysure-API Train 1b (#123, 11 PRs, 6 migrations) live

**Shipped:** #123 merged 2026-10-24 17:06 UTC as a **merge commit** (`main` → `551f19e0`, parents `02cb3440` + approved `edd82337`,
tree == `edd82337`) → main #80 waited ~55 min for an agent pod, then **aborted at the 45-min pipeline timeout** inside pytest (76 %)
→ **#81 = Replay of #80 with only the timeout changed to 90 min** → promoted `551f19e06b11` (gitops `7bb0befa`) → migration + all 3 API
pods 20:00 UTC · **Kind:** developer release train (new domains: KYB, API-key lifecycle, refresh tokens, DVA 5a), **six migrations**
(`f2b8d6a4c1e7` → `d5b2f8a1c7e3`), no platform config · **Cost delta:** $0 · Notes/replies (`weysure/docs/`): `platform-note-2026-10-2x-train-1b.md`,
`platform-reply-2026-10-24-train-1b-review.md`, `…-train-1b-go.md`, `platform-note-2026-10-24-train-1b-merged.md`, `…-train-1b-build-delay.md`,
`platform-note-2026-10-24-train-1b-main80-aborted.md`, `platform-reply-2026-10-24-train-1b-build-timeout.md`, `…-train-1b-live.md`.
Developers' own SOP: `Weysure-API/docs/sop/2026-10-21-train-1b-integration.md`. Platform review: side-session note `train-1b-platform-review.md`.

**Status: live and verified.** Second release train, following the method of [Train 1a](2026-10-21-train-1a-release.md).

## What it is

| Part | Content |
|---|---|
| 11 PRs (merge commits into `release/2026-10-1b`) | #83 API access, #87 API-key lifecycle (revoke, no plaintext), #92 KYB tables, #93 KYB applicant, #94 KYB admin review, #96 KYB limits/payouts, #100 Dojah CAC, #101 KYB live-key gating (**no flag**, active at deploy), #97 DVA 5a, #98 refresh tokens, #113 Nigerian legal forms |
| Migrations (PreSync, one Job) | `b7e3c9a15d42` users.api_access_enabled · `c8d2f6a41b95` api_keys.revoked_at, **plaintext keys erased** · `f2a6d9c3b8e1` KYB tables · `c5e8a3d71b94` business_profiles.cac_directors · `5b028fb23181` DVA tables · `d5b2f8a1c7e3` refresh_tokens |
| New flags (all off) | `DVA_CARD_CAP_ENABLED`, `DVA_CREATE_ENABLED`, `DVA_REFUND_ENABLED`, `KYB_APPLICATIONS_ENABLED`; `REFRESH_COOKIE_SECURE=true` |
| API surface | OpenAPI 241 → 274 paths, 218 → 255 schemas, nothing removed |
| New worker job | `[DVA RECONCILE]` every 15 min (no line for > 30 min = worker down or job disabled) |

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| Devs **merged main (#121) into the train** before the go; re-pin = main merge only, remerge-diff empty | the train's Jenkinsfile must equal main's (10-21 rule), or the tested tree ≠ the merged tree |
| GO at **`edd82337`** only; merge with `--merge --match-head-commit` | approval of an exact, re-proven commit (PR-123 #2: 5181 passed; Sonar DB `pr-123` `new_violations` 0) |
| Prod pre-read: live API keys belong only to the banned test account | `c8d2f6a41b95` erases plaintext keys and #101 gates live keys by tier: no real developer loses a key |
| MED-1 (DVA boot check keyed on `DVA_CREATE_ENABLED` only) = **DVA flag-on condition**, LOWs → Train 2 | unreachable with no accounts and creation off (same rule as 1a M-1) |
| #80 aborted → **Replay with `timeout(time: 90)`**, not a dev hotfix | the commit was right, the build script's limit was wrong. Replay builds the same approved commit (still the tip, so Promote's tip check passes) with no new commit into frozen `main`. A hotfix would have meant a new merge commit, a new artifact and ~1 h more |
| 90 min, not 60 | #81 took 55:47 (tests 48:37 on a busy spot node; PR-123 #2 had 41:16). 90 ≈ 1.6× worst seen; a ceiling only costs time when a build truly hangs. Real fix = `pytest-xdist` |

## Platform findings this release exposed

| Finding | Effect | Status |
|---|---|---|
| **API Jenkinsfile 45-min timeout < main build time** (5181 tests) | every API main build aborts; PR builds pass by seconds (PR-123 #2: 44:28) | devs: one-line hotfix PR to 90 min before the next API merge; `pytest-xdist` in Train 2 |
| A green PR build is not proof a main build fits | main runs Build & push, Image scan, Promote on top | check main duration vs. timeout after any big test growth |
| us-east-1b prefix exhaustion again: agent pod for #80 waited ~55 min; Karpenter node `ip-10-0-4-243` (m5.xlarge) **NotReady 52 min**, removed by Karpenter once empty | release delayed ~1 h before the build started | open (handoff §6 item 6): zone spread / secondary CIDR / bigger subnets. gitops #90 removed the stale-branch-build trigger |
| Consolidation 2 min after the roll (`Evicted pod: Underutilized`) | Argo `Degraded` briefly; same image, same ReplicaSet | expected; not a rollout. Check the tag, not the pod age |

## Verification (all live, 2026-10-24)

| Check | Evidence |
|---|---|
| Merged tree | `551f19e0` parents `02cb3440` + `edd82337`; tree == `edd82337` |
| Main #81 (Replay) | `Timeout set to expire in 1 hr 30 min`; 5181 passed, 2 skipped (48:37); `weysure-api` gate PASSED; Trivy `Python │ 0`; promoted `551f19e06b11` (gitops `7bb0befa`); 55:47 total |
| Migration | Loki `container="migrate"` 19:58 UTC: six `Running upgrade` lines `f2b8d6a4c1e7 → … → d5b2f8a1c7e3`; Adebayo `db-oneoff.sh 551f19e06b11 alembic "current"` 20:04 UTC → `d5b2f8a1c7e3 (head)` |
| Plaintext keys | Adebayo `db-oneoff.sh 551f19e06b11 read "SELECT count(*) FROM api_keys WHERE key IS NOT NULL"` 20:05 UTC → `0` |
| Pods | api ×2 (`ip-10-0-4-37`, `ip-10-0-4-18`, ADR-024 holds) + api-worker on `551f19e06b11`, Ready, 0 restarts; api-scheduler 0 |
| `[FLAGS]` | four new flags `false`, `REFRESH_COOKIE_SECURE=true`; gitops prod values kept (`ORIGIN_RULES_ENFORCED=true` all; `WALLET_RECONCILIATION_SCHEDULER_ENABLED=true` worker only; `WS_ALLOW_URL_TOKEN=true`) |
| OpenAPI (before measured on the old image) | 241/218 → 274/255; `/api/v1/auth/refresh`, `/api/v1/business/me/documents` absent → present; 0 removed |
| `[DVA RECONCILE]` | 19:58:29 UTC `{'resolved': 0, 'timed_out': 0, 'deactivated': 0}` |
| Errors / sites / Argo | only gunicorn `SIGTERM` from stopping pods; 200 / 200 / 200; 32/32 Synced/Healthy |

## Operate / roll back

- **Rollback is not image-only:** `scripts/db-oneoff.sh 551f19e06b11 alembic "downgrade f2b8d6a4c1e7"` (the **train** image), then revert the
  gitops promote to `02cb3440e319`. The erased plaintext key does not come back (banned test account's; accepted).
- **Replay** (Jenkins → build → Replay) is the tool when the build script is wrong and the commit is right. Record the change in the SOP;
  Jenkins keeps the replayed script with the build.

## Follow-ups

- [ ] Devs: API Jenkinsfile `timeout(time: 90)` hotfix PR (own go) **before the next API merge**; `pytest-xdist` in Train 2
- [ ] Loki rules on 1b's new lines (`refresh_token_reuse_detected`, `[DVA …]`, `[KYB]`, `[LIVE ACCESS]`, "no `[DVA RECONCILE]` > 30 min"), with decoys
- [ ] MED-1 before any DVA flag-on; 1b LOWs in Train 2; `ACCESS_TOKEN_EXPIRE_MINUTES=15` only after web #59 live
- [ ] us-east-1b prefix space design (handoff §6 item 6)
- [ ] Remove `api-scheduler` after Train 2
