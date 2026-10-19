# SOP — Weysure-API #88 (every withdrawal requires Tier 2) live

**Shipped:** #88 merged 2026-10-16 22:28:13 UTC (rebase-merge, `main` → `681ce3b`, tree identical to the approved
`b64cd73`) → main build #65 green, promoted `681ce3b37762` (gitops `bc177ab`) → migration Job 23:01:25 UTC → all 4 API
pods 23:03:48 UTC · **Kind:** developer release, money path, data-only migration · **Cost delta:** $0 · Notes/replies:
`weysure/docs/platform-note-2026-10-16-88-{tier2,live}.md`, `platform-reply-2026-10-16-88-{go,live}.md`

**Status: live and verified on the platform side; the developers' Tier-1/Tier-2 end-to-end times are pending.**

## What it is

Policy of 2026-10-15 (cash-out mules passed Tier 1 with a phone alone): **only Tier 2+ (BVN-verified) users can withdraw.**
`require_withdraw_tier` sits inside `open_withdrawal`, the one function that creates a user bank withdrawal (used by
`/wallet/withdraw` and manual payouts); the card-refund retry to a bank is gated the same way. Admins cannot set
`out_30d > 0` below Tier 2. `is_frozen` no longer reads a Tier-1 user's policy-zero limit as a freeze. Migration
`e1a7c4d9b3f2` sets `kyc_tier_limits.out_30d = 0` for tiers 0 and 1.

## Review (money path: full review)

| Area | Result |
|---|---|
| Base / build | `b64cd73` on current `main` (`d8c0450`), `PR-88` build 1 green |
| Every bank-transfer site | `send_transfer` (after the gated `open_withdrawal`); admin `approve_withdrawal` (existing `PENDING` rows only); public-API escrow `/release` (merchant payout, not a wallet withdrawal) |
| `is_frozen` | all 5 callers go through it; `_active_override` respects `expires_at` |
| Migration | single head (`alembic heads`), round trip on PG16: Tier 1 500000 → 0 → 500000 → 0 |
| Tests | 52 money-path files on an isolated PG16: 924 passed |
| Prod impact (read-only counts, 22:02 UTC) | 0 pending withdrawals below Tier 2; 0 active provisional Tier 2; 0 overrides allowing out below Tier 2; **prod has 1 user** (Tier 1, with a balance: the team's test account) |

**Decisions (developers, 10-16):** "no payout below Tier 2, ever": re-check in `approve_withdrawal` + worker retry as a
follow-up PR. Provisional Tier 2 (manual approval with a deadline) may withdraw until the deadline. Public-API `/release`
merchant payouts are excluded by design (KYB + API-key limits).

## Verification (live)

| Check | Result |
|---|---|
| Migration Job | deadline 900; Loki `container="migrate"`: `Running upgrade c8e1f4a7b2d9 -> e1a7c4d9b3f2`, no errors |
| DB (`db-oneoff.sh`, Adebayo, 23:15 UTC) | `alembic current` = `e1a7c4d9b3f2 (head)`; `out_30d`: T0 `0.00`, T1 **`0.00`** (was `500000.00`), T2 `10000000.00`, T3 `50000000.00` |
| New code serving (no credentials) | public OpenAPI: `WalletHoldOut` gained `reason_codes`; "Withdrawals need Tier 2" 0 → 2 (admin tier-limit routes). Baseline captured before merge |
| Pods / edge | 4/4 on tag, 0 restarts, api on two nodes; 0 errors, 0 × 5xx (69 api lines), health 200 |
| Worker | reconciliation 23:14:14 UTC `1 users, 0 mismatches` |
| End to end | **pending:** developers' Tier-1 → **403** `KYC_TIER_REQUIRED` (`KycError` default status; corrected 2026-10-19 — earlier text said 422), Tier-2 → withdraw succeeds; match times in Traefik |

## Operate / roll back

- Rollback: `scripts/db-oneoff.sh 681ce3b37762 alembic "downgrade c8e1f4a7b2d9"` (**with this image**: the old one cannot
  locate `e1a7c4d9b3f2`, so its PreSync would fail), then API image `d8c04502febf`.
- Credential-free deploy proof for a schema change: diff `.components.schemas` of `https://api.weysure.com/api/v1/openapi.json`
  before and after; confirm the check reads "absent" on the old image first.

## Follow-ups

- Developers: Tier-2 re-check in `approve_withdrawal` + worker retries; web copy (disable Withdraw below Tier 2) + one-time
  notice to the affected user.
- **#67 flag-on gate:** a needs-attention card refund for a user below Tier 2 has no admin resolution (bank retry refused)
  — "credit back to wallet" admin action before `REFUND_TO_SOURCE_ENABLED=true`.
