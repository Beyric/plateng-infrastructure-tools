# SOP — Train 5 API (#135) live, flags off, ratings migration

**Shipped:** [Weysure-API #135](https://github.com/Beyric/Weysure-API/pull/135) merged 2026-10-31 13:57:36 UTC as a **merge commit** `c157f08ce180` (approved head `62c262a14e61e1c4e00efb6b59b876c9f558af77`, `release/2026-11-5-api`) → `main` build #92 → promote gitops `60b8d348` → Argo `weysure-api` Synced/Healthy 14:57 UTC → API ×2 + worker rolled out 14:59 UTC ·
**Kind:** developer release, money path, **one migration** (`c7d2e9a41b58`), flags off · **Cost delta:** $0 ·
Notes and replies (`weysure/docs/`): `platform-note-2026-10-31-train5-{api-review,api-review-fixes,new-head,sonar-fixes}.md`, `platform-note-2026-10-31-refund-marker-clear.md`, `platform-reply-2026-10-31-{web71-live-and-train5,train5-review,train5-build-failed,train5-head-review,train5-sonar,train5-head-62c262a1,train5-go,train5-live}.md`.

## What it is

| Change | Effect now (no flag) |
|---|---|
| Ratings hardening | unique `(escrow_id, rated_by_id)`; a second rating is **409**; reads need a signed-in user (`RATINGS_PUBLIC_READ=false`) |
| Developer routes | every `/developer/*` route except the key routes and `POST /developer/api-access` needs API access (403 `API_ACCESS_REQUIRED`) |
| Directory | empty search at most 10, `skip` ignored; one-character name search `200 []` |
| Manual `/refund` and `/split` | list Paystack's refunds first and adopt one that landed; an unclear answer (5xx, non-JSON, timeout) or a reconcile refusal sets `refund_send_unconfirmed_at`, which blocks `/release`, `/split`, auto-release and `close_lost` ([runbook](../runbooks/REFUND_MARKER_CLEAR.md)) |
| 30 s budget on transfer verifies | 503 and no send when spent |
| `api_key_id` filters | dashboards, history and analytics now match the caller's key ids (figures can rise) |
| Payout retry after `RELEASED` | **off** (`BUSINESS_PAYOUT_RETRY_ENABLED=false`); new job `escrow.api_payout_retry`, 8 new admin alert types |

## Why it went the way it did

| Decision | Why |
|---|---|
| Rebuilt on `main` by merging, not rebasing (36 behind, 27 ahead before) | per-commit identity; carries #133 and #134 |
| Opus review of `93fee6a6`: **H1** a 5xx answer became a plain 503 with no marker, **H2** a reconcile 409 set nothing durable (both verified in code); developers fixed in `a22b365c` | the marker is the guarantee that a lost answer cannot be followed by a payout |
| `93fee6a6` failed 7 migration tests (stale `HEAD_REVISION`), so Sonar never ran; `50270583` failed Sonar with 8 new issues; `62c262a1` passed | each head re-checked from the Jenkins log and the Sonar database |
| Delta Opus review of `50270583`: one MED, `_stop_for_reconciliation` rolled back then re-locked, releasing the row lock before the marker committed (verified); fixed with a savepoint in `62c262a1`, test with a queued `/release` on a second connection | the new guarantee had a hole; the fix rode in the Sonar-fix head |
| M1 ("sending" marker before the Paystack call), an admin exit for the marker, and small items = one follow-up PR before the refund route goes to outside developers | no live developer volume, flags off, no worse than `main` |
| Pre-merge prod read for the migration (counts only): **0 duplicate groups, 0 rows** (10:35 UTC, again 13:56 UTC, one minute before the merge) | the migration deletes duplicate ratings and its downgrade cannot restore them |

## Verification (live, 2026-10-31)

| Check | Evidence |
|---|---|
| CI on exactly `62c262a1` (PR-135 #3) | 6088 passed, 3 skipped, 0 failed; changed-line coverage 93% (610 lines, 37 missing); Sonar `new_violations` 0 on that revision; Trivy 0 unfixed CRITICAL |
| Migration | Loki `container="migrate"`: `Running upgrade b3f6a9d2c814 -> c7d2e9a41b58` and `ratings: removed 0 duplicate rating row(s)`; **Adebayo's `alembic current` after the roll: `c7d2e9a41b58 (head)`** |
| Pods and Argo | API ×2 + worker on `c157f08ce180`, ready; Argo 32/32 Synced/Healthy; 5 nodes Ready |
| Restarts | 0, 0 and **1**: one API pod's first container got SIGTERM one second after it started (exit 143) then started normally; the worker had the same single early SIGTERM on 10-31 morning (under investigation, not the application) |
| Flags (boot `[FLAGS]` line, three pods) | the three `BUSINESS_*` flags and `BUSINESS_PAYOUT_RETRY_ENABLED` false, `RATINGS_PUBLIC_READ=false`, `LIVE_AUTO_PAUSE_MODE=enforce` |
| Logs and sites | 0 error/exception/traceback lines on the three pods; `api.weysure.com/api/v1/health` 200, `weysure.com` 200 |
| **Not exercised** | every "no flag" behaviour live (ratings 403/409, developer gate, directory limits, the refund marker, the verify budget); a real lost refund answer; a clear of the marker |

## Operate / roll back

**Not image-only.** The old image cannot find `c7d2e9a41b58`, so the PreSync would fail. Order: no-op downgrade with this image first (`scripts/db-oneoff.sh c157f08ce180 alembic "downgrade b3f6a9d2c814"`, it only drops the unique constraint and restores nothing), then `images.yaml` back to `7208ab9cf0ba`. Flags first if any is on. **Before any image rollback, count deals carrying `refund_send_unconfirmed_at`** (an old image ignores the marker and can release such a deal on top of a refund that may have landed). To stop the retry job without a restart: `JOBS_DISABLED_KINDS=escrow.api_*`.

## Follow-ups

- [ ] Developers: web rating-409 fix (`fix/rating-already-rated-409`), its own GO.
- [ ] Developers: refund follow-up PR (M1, admin exit for the marker, small items: settle wait counts from claim time, reversed/cancelled counted differently in `send_late_refund`, reconcile alert without `try/except`), own money review and GO, before the refund route is offered to outside developers.
- [ ] Platform: the early SIGTERM on new pods (worker and one API pod on 10-31) next to the Karpenter/spot write-up.
- [ ] Flag-on conditions of Train 4 and payout retry stay as in the #133 SOP.
