# SOP — Weysure-API #69 (Paystack webhook-key trust) live, LIVE key emptied, Loki alerts

**Shipped:** Vault `PAYSTACK_LIVE_SECRET_KEY` emptied 2026-10-15 ~13:50 UTC (Reloader restart 13:52) → #69 merged 13:47:24 UTC
(rebase-merge: `0147595`, `bf57d47`, `28e4876`; same tree as the approved head `3daab28`) → promoted `28e48768d0cd`
(gitops `cbbaecf`, 14:08 UTC) → all api pods Ready 14:13:39 UTC · alerts: gitops #74 · **Kind:** developer release, no migration,
one Vault value change, one gitops monitoring PR · **Cost delta:** $0 · Developers' note:
`weysure/docs/platform-note-2026-10-14-paystack-webhook-key.md`; our reply: `platform-reply-2026-10-15-69-go.md`

**Status: live and verified end to end (test-mode top-up 14:17 UTC credited once).**

## Why

Before #69 the webhook accepted a body signed with **any** of `PAYSTACK_SECRET_KEY`, `PAYSTACK_TEST_SECRET_KEY` or
`PAYSTACK_LIVE_SECRET_KEY`, and credited money from the body. The test key is in developer `.env` files and CI, so anyone
holding it could forge `charge.success` (free credit), `transfer.failed/reversed` (double money) or `refund.*`.

## Key shape found in prod (shape only, `scripts/paystack-key-shape.sh`, Vault v11)

| Key | Shape | Consequence |
|---|---|---|
| `PAYSTACK_SECRET_KEY` | `sk_test_`, 48 chars, **equal to TEST** | Emptying TEST alone (the "quick fix") closes nothing |
| `PAYSTACK_TEST_SECRET_KEY` | `sk_test_`, 48 chars | — |
| `PAYSTACK_LIVE_SECRET_KEY` | 11 chars, not `sk_` (placeholder) | Was itself a trusted, possibly guessable signing key → **emptied** |

Emptying LIVE broke nothing: developer-API production traffic falls back to the main key only if it is `sk_live_`, so it
already answered 503 (`public_api.py:_get_paystack_secret_for_environment`).

## How (#69 and decisions)

- Each key class speaks only for its own flows (`app/services/paystack_webhook_trust.py`): wallet money only on the wallet
  key; developer escrows on the wallet key or the developer key of their own mode; body `domain` must match the key mode.
- Wallet top-ups and withdrawal outcomes are **re-verified with Paystack** before money moves; the credited amount comes
  from Paystack's answer. Refunds were already settled by lookup. Paystack unreachable → 503 → redelivery.
- Startup WARNING `[CONFIG] Paystack keys look misconfigured` in prod-like envs; two expected while prelaunch runs test keys.
- Review (Opus, security-critical): **GO at exactly `3daab28`**. Non-blocking follow-ups sent to the developers (below).
- Prelaunch risk was fake money only (test mode; Adebayo confirmed no test balance becomes real money).

## Verification

| Check | Result |
|---|---|
| Merged code = approved | `git diff 3daab28 28e4876` empty; same parent `acdae7f` |
| Rollout | 2/2 api pods `28e48768d0cd`, 0 restarts; 32/32 apps Synced/Healthy |
| Startup logs | only the 2 expected CONFIG warnings (wallet key not live; TEST equals wallet); no LIVE warning (empty took effect); 0 ERROR/Traceback |
| Forgery look-back (counts, `db-oneoff.sh acdae7fd271c read`) | 2 completed card top-ups (both matched in the Paystack test dashboard by Adebayo), 0 withdrawals, 0 refunded |
| End to end | ₦400 test top-up 14:17:56 UTC: webhook 14:18:03 `key class: developer_test,wallet`, verified with Paystack (0.36 s), 200; DB: exactly one `TOPUP COMPLETED 400.00` |
| Loki alerts (gitops #74) | `loki-rules-paystack-test.sh` on Loki 3.6.11 + Alertmanager: 6 scenarios + delivery PASS; prod values 0 |

## Operate / roll back

- Rollback #69: revert the API image to `acdae7fd271c` (no migration). Reverting re-opens the any-key trust.
- Rollback alerts: revert gitops #74. Runbook: `runbooks/ALERTS.md#paystackwebhookkeymismatch` (+ the two siblings).
- **Any Paystack key rotation:** update Vault `secret/weysure/prod` in the same step and restart api, or webhooks fail
  signature checks and are dropped (`PaystackWebhookSignatureFailing`).

## Launch gate (before real money)

`PAYSTACK_SECRET_KEY` = `sk_live_`; `PAYSTACK_TEST_SECRET_KEY` empty or prod's **own** test key (never the dev/CI one);
`PAYSTACK_LIVE_SECRET_KEY` = `sk_live_` if the developer API serves production traffic; startup shows no CONFIG warning.

## Follow-ups

1. Developers: verify 401/403 → 503 + admin alert (today a wrong key makes top-up webhooks look "not paid").
2. Developers: re-verify developer-escrow `charge.success` and payout outcomes with Paystack (signer-only today).
3. Developers: `stop_background_jobs` re-raises the child's `CancelledError` → shutdown-hook error while the scheduler is on.
4. Developers: `/wallet/topup/verify` answers 404 after a webhook already credited the top-up (pre-#69); answer "completed".
