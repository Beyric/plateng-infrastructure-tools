# SOP — Weysure-API Train 2 (#126) live

**Shipped:** #126 merged 2026-10-25 16:59 UTC as a **merge commit** (`main` → `5ef23964`, parents `73101c25` + approved `ecae95c4`) → main #83
(queued ~13 min for an agent, green 18:09 UTC) → promoted `5ef239645723` (gitops `ca91a14f`) → migrations + api ×2 + api-worker 18:13 UTC ·
**Kind:** developer release train (DVA 5b refunds, KYB PR-7, KYC Tier 3, KYB draft expiry, 1b review LOWs, two new start-up guards),
**two migrations** (`d5b2f8a1c7e3` → `a9c3e7b15d28` → `e4b8d1a6c372`), no platform config · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-25-train-2-api.md`, `platform-reply-2026-10-25-train-2-api-review.md`,
`platform-note-2026-10-25-train-2-api-review-answer.md`, `…-train-2-api-go.md`, `…-train-2-api-live.md`. Developers' SOP index:
`Weysure-API/docs/sop/2026-10-25-train-2-integration.md`.

**Status: live and verified.** Third release train; method of [Train 1b](2026-10-24-train-1b-release.md).

## What it is

| Part | Content | Flag |
|---|---|---|
| S2 DVA 5b | refunds of DVA money; third-party returns on superadmin approval (`dva_return_requests`) | `DVA_REFUND_ENABLED` off |
| S3 KYB PR-7 | pre-KYB developers: live payouts only to the owner's Dojah-verified own-name account, ₦50k per live deal (`settings`), admin pause/resume of live keys | **none (active)** |
| S1 KYC P4 | self-serve Tier 3 (NIN + liveness, statement, admin queue, superadmin approval) | `KYC_ENHANCED_ENABLED` off |
| KYB draft expiry | job `kyb.draft_expiry` every 6 h, closes drafts idle > `KYB_DRAFT_EXPIRY_DAYS` (default 30) | active (KYB off → no drafts) |
| 1b LOWs a–e | `PUT /users/me` ignores `status`; boot refuses `REFRESH_COOKIE_SECURE=false`; `5b02` seeds `ON CONFLICT`; `f2a6` downgrade guarded; admin-created developers get API access | none |
| **Start-up guards** | (1) **launch guard** `app/core/boot_guard.py` (`ENVIRONMENT=prelaunch`): SECRET_KEY ≥ 32 chars / ≥ 10 distinct / no placeholder word, `PAYSTACK_SECRET_KEY` = `sk_(test\|live)_…`, LIVE/TEST slots empty or right mode, `REFRESH_COOKIE_SECURE` not false; (2) **MED-1 DVA guard**: refuses if a pending/active dedicated account exists while origin rules + an enforced holds/chargebacks mode are not all on (exit 3) | — |
| Migrations | `a9c3e7b15d28` `dva_return_requests` · `e4b8d1a6c372` `kyc_reviews` + `kyc_records.purpose` (both expand-only) | — |
| CI | Jenkinsfile: PR-only **Changed-line coverage** stage (`diff-cover` ≥ 80%) | — |

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| Pre-GO **key-shape check** (`HANDOFF-scripts/bootguard-shape.sh`: lengths/modes only) against the guard's own code | a refused boot = every API and worker pod down. `prelaunch` is in neither `FAKE_ELIGIBLE_ENVS` nor `PRODUCTION_ENVS`, so `sk_test_` passes and the strict rules apply |
| Pre-GO prod reads, counts only: `dedicated_accounts` (0 rows) and **open live API escrows** (`pending_payment`/`funded`/`on_hold` with a production key or `environment=production`: 0) | MED-1 guard would refuse start-up; the own-name gate would hold existing live escrows. A superset count of 0 answers the narrower question without the developers' query |
| Review MED #112 (socket `message` relay) **downgraded to LOW** after reading the REST path | REST send paths still push `event: "message"` (`messages.py:93`); web sends only `typing`/`read` on the socket; no mobile client exists |
| PR-126 #2 aborted by a **spot interruption** in Build & push → **Restart from Stage `Build & push`** (#3), not a full rebuild | Tests/coverage/Sonar had passed for the same commit; the Jenkinsfile uses no `stash`, so the image stages need only the checkout. Saved ~55 min |
| GO at **`ecae95c4`** only; `--merge --match-head-commit`; developers hold their SOP edits until after live | approval of an exact commit; any push = new build + new GO |
| Review findings: MED DVA guard ignores DEACTIVATED accounts = **condition of DVA flag-on**; LOWs (DB hard boot dependency, any-admin resume of paused keys → Train 3, `NOT VALID` for future constraints) accepted | unreachable with 0 accounts and DVA creation off |

## Platform findings this release exposed

| Finding | Effect | Status |
|---|---|---|
| **`karpenter.sh/do-not-disrupt` does not stop a spot reclaim** (node `ip-10-0-3-243`, 1a `c5.xlarge`, 16:49 UTC) | PR-126 #2 lost its agent mid-kaniko after 55 min of tests | open: weigh an on-demand NodePool for Jenkins agents with CI-speed B |
| Restart from Stage works for API PR builds | image stages in 2 min with a warm kaniko cache; skipped stages are marked skipped, evidence cited from the earlier build of the same commit | method recorded here |
| Sonar DB: in a recreated `-pr` project, "new" = **`issues.issue_creation_date` > base snapshot `analysis_date`**, not row `created_at` | `created_at` lists every issue (found while reading web PR-66) | recorded |
| Consolidation moved the new worker 2 min after the roll (same image) | none | expected |

## Verification (all live, 2026-10-25)

| Check | Evidence |
|---|---|
| Merged tree | `5ef23964` parents `73101c25` (tested main) + `ecae95c4` (approved head) |
| PR-126 #2 / #3 | 5506 passed, 3 skipped (55:10); changed-line coverage 93% of 1666; B1 delete 204 / create 200 / select 204; Sonar DB `pr-126` `new_violations` 0; #3 built `pr-126-ecae95c4fd44-b3`, Trivy CRITICAL debian 0 / Python 0 |
| Main #83 | green 18:09 UTC; promoted `5ef239645723` (gitops `ca91a14f`) |
| Migration | Loki `container="migrate"`: `d5b2f8a1c7e3 → a9c3e7b15d28 → e4b8d1a6c372`; Adebayo `db-oneoff.sh 5ef239645723 alembic "current"` 18:29 UTC → `e4b8d1a6c372 (head)` |
| Guards | no `[BOOT GUARD]` line in `weysure-prod` (same window shows migrate + `[FLAGS]`, so Loki was receiving) |
| Pods | api ×2 (`ip-10-0-4-37`, `ip-10-0-4-18`, ADR-024) + api-worker on `5ef239645723`, Ready, 0 restarts |
| `[FLAGS]` | `KYC_ENHANCED_ENABLED=false` (new), `DVA_REFUND_ENABLED=false`, `KYB_APPLICATIONS_ENABLED=false`, `REFUND_TO_SOURCE_ENABLED=false`, `CHARGEBACKS_MODE=off`, `ORIGIN_RULES_ENFORCED=true`, `RISK_HOLDS_MODE=off`, `WS_ALLOW_URL_TOKEN=true` |
| Worker | `startup sweep ensure_draft_expiry: 1 job(s) scheduled`; `kyb.draft_expiry` next 2026-10-26 00:10 UTC |
| Errors / public | 0 traceback/ERROR/CRITICAL lines (api, api-worker) after the roll; `/api/v1/health` 200; OpenAPI 293 paths incl. `/wallet/dva/returns`, `/admin/dva/returns/*`, `/admin/chargebacks/mode` |

## Operate / roll back

- **Not image-only:** `scripts/db-oneoff.sh 5ef239645723 alembic "downgrade d5b2f8a1c7e3"` (the **train** image), then revert the gitops
  promote to `73101c25b5eb`. The downgrades refuse once `kyc_reviews` / `dva_return_requests` have rows → roll back with the flags instead
  (`KYC_ENHANCED_ENABLED=false`, `DVA_REFUND_ENABLED=false`) and keep the train image.
- `KYB_DRAFT_EXPIRY_DAYS=0` stops draft expiry. While any dedicated account is pending/active, an image older than 1b must never run.
- A boot-guard refusal shows as one CRITICAL `[BOOT GUARD] refusing to start …` line naming the settings (never values), then exit.

## Follow-ups

- [x] Web Train 2 (#66) live 2026-10-26 09:14 UTC (`8d81d74c58c0`) — [SOP](2026-10-26-train-2-web-and-127-release.md)
- [ ] DVA flag-on conditions: MED-1 guard counts DEACTIVATED accounts (or inflow stops crediting them); 1b MED-1
- [ ] Web auth MED-B (refresh scheduling against the device clock) before `ACCESS_TOKEN_EXPIRE_MINUTES=15`
- [ ] CI-speed B (pytest-xdist) PR; consider on-demand capacity for Jenkins agents
- [ ] Loki rules on 1b + Train 2 new lines; remove `api-scheduler` (both trains live)
- [ ] Developers' docs PR with their SOP additions (DB hard boot dependency; admin withdrawal refuses out-limit-frozen users)
