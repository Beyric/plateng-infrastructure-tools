# SOP — API #133 (Train 4 flag conditions) live, flags still off

**Shipped:** [Weysure-API #133](https://github.com/Beyric/Weysure-API/pull/133) merged as a **merge commit** (approved head `245c2857`, `fix/train4-flag-conditions`) → live as **`955818887811`** on 2026-10-30 evening, api ×2 + api-worker ·
**Kind:** developer release, money path, **three Train 4 flags still off**, **no migration** (Alembic head stays `b3f6a9d2c814`) · **Cost delta:** $0 ·
Notes and replies: `platform-note-2026-10-30-{api-flag-conditions-pr,api133-sonar-fix,web69-api133-new-heads}.md`, `platform-reply-2026-10-30-{api133-review,api133-sonar,train5-web-api133-builds,api133-go}.md`.

## Why

Train 4 went live with its flags off on the condition that HIGH-1, MED-1, MED-2 and LOW-1..7 were fixed before any flag turns on. #133 is that fix PR, plus new settings and a directory limit.

## What changed (flags off)

| Change | Effect at deploy |
|---|---|
| A card dispute on a `wys_escrow_` charge **holds the deal** even with `CHARGEBACKS_MODE=off`; the worker delivers `escrow.on_hold` / `escrow.hold_resolved` merchant webhooks | no deal exists, so nothing fires |
| Webhook SSRF guard: private ranges refused, DNS pinned, no redirects, 10 s cap (`WEBHOOK_ALLOW_PRIVATE_TARGETS=false`, in `.env.example`) | merchant URLs in private ranges stop receiving webhooks |
| User directory limits: 60/min and 600/h per user, page cap 50; phone search normalises `0803…` | rate-limits the enumeration oracle |
| Admin analytics `total_customer_payments_received` | moves from 0 to the real total |

## Decisions

| Decision | Why |
|---|---|
| GO for the exact commit `245c2857` after our own read of the refactor `1ed5c654..245c2857` | Sonar refactors on money code are read for behaviour: same conditions, same order, same queries, every helper module-level (AST pass) |
| Independent Opus review of `0e96e748` (no blocker or high) | money paths |
| Worker egress read from the live `api-egress` NetworkPolicy: public IPs on 443, 587, 465, VPC excluded | `http://` or another port is dropped and times out (10 s per attempt) |
| Open conditions stay open (not for this merge) | listed below |

## Verification

CI on exactly `245c2857`: **5907 passed, 3 skipped, 0 failed**; Sonar `new_violations` 0 on that revision; Trivy no unfixed CRITICAL. Live: 3 pods on `955818887811`, Ready, 0 restarts, no errors, flags still false (read from the boot `[FLAGS]` log line).

## Operate / roll back

Image-only to `174036317683` in `images.yaml`, **only while no deal has expired or been disputed** (all flags off). Once a dispute hold event is written: flags first, never an image revert.

## Follow-ups (conditions before the flags)

- [ ] Hold in the same transaction as the wallet ingest; counts-only pre-switch read for auto-pause; a real Paystack dispute body diffed against the developers' fixtures (before `BUSINESS_AUTO_RELEASE_ENABLED`).
- [ ] Webhook URL validation (https on 443) at creation.
- [ ] Train 5 API: empty directory search one page of 10 and 2+ characters for a name; the `is_disputed` re-check after the split re-lock; lazy imports back above the row lock in `ensure_auto_release`; JSON body for `PATCH /messages/messages/{id}`.
