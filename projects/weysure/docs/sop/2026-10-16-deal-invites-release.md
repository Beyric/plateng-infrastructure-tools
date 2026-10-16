# SOP — Weysure-API #75 (deal invites) live, flag off

**Shipped:** #75 merged 2026-10-16 15:27:29 UTC (rebase-merge, `main` → `af04c82`, tree `79af3bb` = approved `926f347`) →
main build #61 aborted (timeout) → #62 failed (immutable tag) → **#63 (Replay) green 17:14 UTC, promoted `af04c821c325`
(gitops `b390331`)** → migration Job 17:20:47 UTC → all 4 API pods 17:24:22 UTC · **Kind:** developer release, two
migrations, flag off · **Cost delta:** $0 · Prep: [deal-invites platform prep SOP](2026-10-16-deal-invites-platform-prep.md)
· Notes/replies: `weysure/docs/platform-note-2026-10-14-deal-invites.md`, `platform-review-2026-10-16-75-deal-invites.md`,
`platform-reply-2026-10-16-75-{review,go,live}.md`

**Status: live and verified; `DEAL_INVITES_ENABLED` unset (off). Flag-on is a separate step.**

## What it is

A user invites someone with no account into an escrow deal by email. A buyer-inviter's money is held at creation
(escrow status `INVITED`); the invitee previews by link, claims (signed in, verified email must match) or declines (no
login; a declined/cancelled/expired buyer invite is refunded in full). New table `deal_invites`, new escrow status
`INVITED`, four worker job kinds (`invite.send/expire/notify/email_clear`).

## Review (Opus-level, before merge)

No blockers on `469a94b`. Four should-fixes folded into the rebase (`926f347`): M1 `SET statement_timeout = 0` in the CIC
migration; A1 fixed slowapi scopes (the default `key_style="url"` put the token path in Redis keys and the
"exceeded at endpoint" log line); A2 `Idempotency-Key` in CORS `allow_headers` (else the cross-origin create fails
preflight and a retried buyer create could debit twice); A3 `inert_text` on `decline_reason`. Money paths, lock order
(invite → escrow → users), refund guards (`NotRefundable`, no refund without an `ESCROW_HOLD`), KYC buy limit (counts
`ESCROW_HOLD` debits), card cap (fails closed) and the new status against every existing guard (allow-lists only)
checked clean. Full review: `weysure/docs/platform-review-2026-10-16-75-deal-invites.md`.

## The release: three builds, no gate skipped

| Build | What happened | Lesson |
|---|---|---|
| main #61 | Tests + push OK; **aborted at 30:00** (`options { timeout(time: 30 …) }`), 11 s after pushing `af04c821c325`, as Image scan started | #75's tests took the PR build to ~28 min; the timeout had become a cliff |
| main #62 (Replay, timeout 45) | **Build & push failed:** `TAG_INVALID … tag is immutable` (#61's push) | Build & push is not idempotent for `main` (bare-SHA tag) |
| main #63 (Replay of #62, push replaced by an `echo`) | Tests, quality gate, **Trivy on #61's image**, Promote: green | Provenance by elimination: only `main` builds get the bare-SHA tag, and #61 was the only one before 16:07 |

Jenkins **Replay** re-runs the same commit with an edited pipeline: no new commit, no new approval, every gate still runs.
GitHub's combined status reports an aborted build (`error`) as "failure": read the per-status description.

## Verification

| Check | Result |
|---|---|
| Migration Job | `activeDeadlineSeconds: 900` on the Job (gitops #81 applied at this sync, as predicted); `d4b7f2a91c68 → a3c9e5b71f24 → c8e1f4a7b2d9`, < 1 min |
| DB (`db-oneoff.sh read`, Adebayo) | `alembic_version = c8e1f4a7b2d9`; `ix_users_lower_email` `indisvalid = true` |
| New code serving (no credentials) | `GET /api/v1/invites/<junk>` → 404 `{"detail":"Invite not found.","code":"INVITE_NOT_FOUND"}` 56 B; baseline before: FastAPI `Not Found` 22 B |
| Flag | `DEAL_INVITES_ENABLED` in no weysure-prod ConfigMap (off) |
| Worker | `invite.email_clear` ran (`cleared 0 invitee address(es)`), rescheduled daily |
| Pods / spread | 4/4 on `af04c821c325`, 0 restarts; api on 2 nodes, web on 2 nodes (ADR-024) |
| Errors | 0 error/traceback lines from new pods; 0 × 5xx at Traefik; health 200 (both API hosts, web); Argo 32/32 |

## Operate / roll back

- **The old image cannot load an `INVITED` escrow** (SQLAlchemy `LookupError`). Before any invite exists: `alembic downgrade
  d4b7f2a91c68` **with this image** (`scripts/db-oneoff.sh af04c821c325 alembic "downgrade d4b7f2a91c68"`), then image
  `31c03c9ce8ca`. After the first invite: flag off and fix forward (the downgrade refuses).
- Flag-on (separate go): web `/invite/[token]` live with `Referrer-Policy: no-referrer`; `RiskHoldSettings` row 1 present
  (else every buyer invite 503s); one invite per direction end to end with a real inbox; watch email bounces the first week.

## Follow-ups

- **Jenkinsfile (developers, next PR):** timeout 45; Build & push skips when the `main` tag exists in ECR. Never mutable tags.
- #79 (chargebacks): re-parent its migration onto `c8e1f4a7b2d9`; gate invite create/resend/claim on the chargeback freeze.
- Review nits A4–A7 (unmatched-route log fallback, alias caps, idempotency hash after clearing, admin email change keeps
  `is_verified`) with later PRs.
