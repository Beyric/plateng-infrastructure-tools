# SOP — Train 4 API (#131, developer-API deal safety net) live, flags off

**Shipped:** [#131](https://github.com/Beyric/Weysure-API/pull/131) merged 2026-10-30 12:27:30 UTC as a **merge commit** (`main` → `174036317683`, approved head `f1c8a575`) →
main build #88 (aborted by a spot reclaim at 22%) → restarted as #89 → green 13:53 UTC → promoted `174036317683` (gitops `bd38c678`) → Argo stalled on the PreSync hook (all-digit tag, below) → fixed by gitops [#97](https://github.com/Beyric/plateng-gitops/pull/97) (merged 14:10 UTC) → Argo re-synced 14:16–14:17 UTC → api ×2 + api-worker Ready ·
**Kind:** developer release, money path, **three flags off**, **no migration** (Alembic head stays `b3f6a9d2c814`) · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-27-train-4-api.md`, `platform-reply-2026-10-30-train4-review.md`, `…-auth-cookie-checks.md`, `…-train4-go.md`, `…-train4-live.md`.

**Status: live and verified at platform level.** No flag has been turned on. Adebayo's first live deal worked; three gaps went to the developers (below).

## What it is

| Change | Effect now |
|---|---|
| Three flags, default `false`: `BUSINESS_PAYMENT_EXPIRY_ENABLED`, `BUSINESS_HOLD_EXPIRY_ENABLED`, `BUSINESS_AUTO_RELEASE_ENABLED` | nothing changes; each turns on a clock for developer-API deals (expire an unpaid deal, expire a hold, auto-release after funding) |
| Three flag-independent fixes | partial `/refund` on an `ON_HOLD` deal stays `ON_HOLD`; the `escrow.released` webhook's `platform_fee` is an integer (it was a `Decimal`, so the delivery failed to serialise and was never sent); a charge reaching an already-expired deal is refunded |
| New worker job kinds (`escrow.api_payment_expiry`, `…auto_release`, `…hold_expiry`, `…release_upcoming`, `api_refund.late/check/notify`, `api_event.deliver`) | idle while their flag is off |
| Webhook outbox posts **from the worker** (`api_event.deliver`) | needs worker egress to developers' URLs **only once a flag is on** |
| Seller search (`/users/sellers`, `/users/buyers`) | any account can be a counterparty. Exact email or phone finds any active account with a **confirmed** contact; names and empty search find KYC-verified accounts only; inactive, suspended and banned accounts are never listed. A phone change clears `phone_verified_at` (`users.py:138`) |

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| Our own review of the money paths on `f2a44778` before any GO | it moves and expires money. Result: no blocker for a flags-off deploy; findings HIGH-1 (auto-release never checks the developer's account status: a banned developer's FUNDED deals would still pay out), MED-1 (webhooks now post from the worker to a developer-chosen URL with no SSRF guard, size or total-time cap), MED-2 (a card dispute on an escrow charge never holds the deal), LOW-1..7. We read HIGH-1 in the code ourselves before relying on it |
| GO for exact `f1c8a575`, flags off | HIGH-1/MED-1/MED-2 are **conditions of the flags**, not of the deploy: with flags off the worker reaches the outbox writers only through a flag-created state |
| One flag at a time, in order: payment expiry → hold expiry → auto-release, each its own ConfigMap change | blame stays clear; auto-release additionally waits for HIGH-1 and MED-2 and our re-review |
| Worker egress confirmed by us before the first flag flip | the worker needs merchant URLs, `api.paystack.co` and SMTP; MED-1 shapes the policy |
| Seller-search tradeoff accepted for pre-launch | exact search reveals whether a confirmed contact has an account. **Condition:** a per-user rate limit on `/users/sellers` and `/users/buyers` before public signup |
| Rollback is flags first; image-only rollback only while no deal has expired | the old image has no handler for the new job kinds; there is no migration to undo |
| Window rule while it was open | no other merge to either repo or any release branch |

## Platform findings this release exposed

| Finding | Effect | Action |
|---|---|---|
| **All-digit image tag.** `174036317683` was written unquoted by the promote `sed`; YAML read a number, Helm printed `1.74036317683e+11`; the migrate Job got `InvalidImageName`; Argo waited on the hook for ~20 min. Prod never moved | Train 4 delayed ~20 min after a green build | gitops #97 quoted the tag. **Follow-ups:** quote the tag in both Jenkinsfile promote steps with a post-check (asked of the developers, `…-train4-live.md` §2); chart guard so a non-string tag fails the render. About 1 in 300 twelve-hex tags is all digits |
| Recovery sequence went wrong once | Terminating the stuck Argo operation made Argo auto-sync the new revision at once, creating a fresh hook Job; a manual `kubectl delete job` seconds later hit that new Job and left it `Terminating` on Argo's `hook-finalizer`. A second terminate-op cleared it, then `argocd app sync` succeeded | next time: terminate the operation, **look at Argo before touching the Job**; the migrate pod of the deleted Job had already run clean (exit 0, alembic no-op) |
| Spot reclaim killed main build #88 at 22% (node `ip-10-0-3-16`) | ~25 min lost | restarted as #89; part of the open Karpenter / spot decision |
| Earlier: spot reclaim aborted PR-131 #2 at 90% of the tests; PR-131 #4 spent its slot on an older push | builds repeated | none beyond the above |
| `argocd` CLI had no server configured on the operator's machine | `terminate-op` failed with "server address unspecified" | use `--core` and set the kubectl context namespace to `argocd` first, then put it back to `weysure-prod` |

## Verification (live, 2026-10-30)

| Check | Evidence |
|---|---|
| Merged tree | merge commit `17403631` = approved `f1c8a575`; previous head `f2a44778` and `main` `a5198545` are ancestors; Jenkinsfile equals `main`'s; no Alembic change |
| CI | PR-131 #5 (built exactly `f1c8a575`): 5769 passed, 3 skipped, 0 failed; Sonar gate PASSED; `new_violations` 0 on revision `f1c8a575` |
| Pods | api ×2 + api-worker on `174036317683`, Ready, 0 restarts; rollouts complete; web unchanged |
| Migration | the migrate Job ran (exit 0), alembic log shows only `Context impl PostgresqlImpl` and `Will assume transactional DDL` |
| Health and logs | `api.weysure.com/api/v1/health` 200, `weysure.com` 200; 0 error/exception/traceback lines in api ×2 and the worker (20 min) |
| Flags | code default `False` (`config.py:275-277`) and no override in either ConfigMap or the app secret. **Not a runtime read**: exec into prod pods is blocked |
| Alerts, Argo | `LiveKeysAutoPaused` and `LiveAutoPauseFailing` inactive; `weysure-api`, `weysure-web`, `weysure-prod` Synced and Healthy; 4 nodes Ready |
| Adebayo's live deal (reported by him) | deal created with the seller found by **email**; buyer charged price plus escrow fee; seller notified in-app and by email |
| **Not exercised / gaps found** | seller search by phone and by name returned nothing (probably unverified test accounts or phone format; code reading in the reply); the seller does not see the escrowed money; no way to open chat in the web build, so #130's chat test is still open |

## Operate / roll back

- Image rollback (only while no deal has expired; all flags are off): promote `a5198545f609` again through gitops `images.yaml`. No migration.
- Flags later: one ConfigMap change each (api and worker), Reloader restarts the pods. Rollback is the flag first; `JOBS_DISABLED_KINDS=escrow.api_*` stops the clocks without a restart.
- Watch once a flag is on: `/admin/jobs/stats` lag and `dead`, and the critical admin notifications `escrow_late_refund_problem`, `escrow_unexpected_payment`, `escrow_expiry_blocked`.

## Follow-ups

- [ ] Developers: the follow-up PR (HIGH-1, MED-1 URL guard / body cap / total-time cap, MED-2, LOW-1..7, rate limit on the user directory), then our re-review.
- [ ] Developers: answers to the three gaps (seller search, seller escrow view, chat entry point) and the quoted-tag change in both promote steps.
- [ ] Platform: chart guard for a non-string image tag (gitops).
- [ ] Platform: worker egress check before the first flag flip.
- [ ] Adebayo: #130 two-session chat test once chat can be opened.
- [ ] Train 5 (`release/2026-11-5-api`, stacked on Train 4) follows; it needs a rebuild on the new `main`.
