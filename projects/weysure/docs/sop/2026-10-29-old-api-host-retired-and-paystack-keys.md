# SOP — old API host `weysure-api.beyrictech.com` retired (C2/C3) and Paystack keys rolled

**Shipped:** gitops [#94](https://github.com/Beyric/plateng-gitops/pull/94) merged 2026-10-29 21:56:42 UTC (squash `076b5b71`, approved head
`8e9390d7`) → Argo `weysure-api` Synced/Healthy 21:59 UTC → Cloudflare DNS record removed (Adebayo, ~22:04 UTC; `NXDOMAIN` on 1.1.1.1 and 8.8.8.8) ·
**Before it:** Vault `secret/weysure/prod` Paystack keys rolled (version 17, 21:39 UTC) and a ₦400 test top-up proved the new webhook URL ·
**Kind:** gitops config + one small chart option + a Vault value change; no image change (`7cd2977636b0`), no migration · **Cost delta:** $0 ·
Plan: `plans/2026-10-15-domain-cutover-weysure-com.md` §5 (C2/C3).

**Status: live and verified.** Open: the orphan Secret `api-tls` (harmless), Loki and Prometheus keep only 7 days (see Why).

## Why

The API moved to `api.weysure.com` on 2026-10-15 (C1). The plan was to retire the old name after 14 days without traffic.

| Evidence (Loki, Traefik access log, router `…weysure-api-beyrictech-com`, 10-22 to 10-29) | Count |
|---|---|
| `GET /api/v1/health` (our blackbox probe, NLB-side address) | about 20,000 |
| Internet scanners (`/.env`, `/wp-login.php`, `/xmlrpc.php`, …), all 404/405 | under 60 |
| App calls (login, deals, wallet) | **0** |
| `POST /api/v1/payments/webhook` → 404 (a path that never existed; Paystack-like retries: 3 min apart, then hourly; bursts 10-24, 10-27, 10-28) | 70 |

Limit: Loki and Prometheus retain **1 week**, so 7 of the 14 days were provable, not 14. Adebayo accepted the 7-day evidence. The 70 failed
POSTs came from an unidentified sender (the NLB hides the client address and the log has no user agent); the most likely cause is a wrong Paystack dashboard URL, **not confirmed**. The real route is `POST /api/v1/wallet/paystack/webhook` and had **zero** hits on either host in 7 days. Adebayo replaced the dashboard URLs; no more 404s are expected.

## How

| Step | What | Why this way |
|---|---|---|
| 1 | Paystack keys: `scripts/paystack-roll.sh` (prompts with `read -rs`, shape-checks, refuses a non-`sk_` value, asks to type `LIVE` for a live main key), one atomic `vault kv patch` of `PAYSTACK_SECRET_KEY` + `PAYSTACK_TEST_SECRET_KEY` (both `sk_test_`, 48 chars, equal), force-sync of `weysure-app-config`, Reloader restart | one write cannot pair a new key with an old one; ExternalSecret refreshes only hourly |
| 2 | Dashboard webhook URL (live and test) → `https://api.weysure.com/api/v1/wallet/paystack/webhook` | Paystack signs with the mode's secret key; no separate webhook secret |
| 3 | ₦400 test top-up | the signature check and the Paystack re-verification run end to end |
| 4 | gitops #94: ingress host `api.weysure.com`, `BACKEND_CORS_ORIGINS=["https://weysure.com"]`, old API probe removed | plan C2/C3 |
| 5 | Cloudflare DNS record for the old name removed | after the cluster stopped serving it |

**Key decision: `ingress.tlsSecretName`.** The chart named the primary host's Secret `<name>-tls` and the extra hosts' `<name>-extra-tls`.
Making `api.weysure.com` the primary host with the default name would have reissued its certificate and served the old name's certificate for about a minute on
the live API. The new optional field keeps the Secret `api-extra-tls` (already a valid, Ready certificate, expires 2027-01-13), so cert-manager sees the same
Certificate and does nothing. Default unchanged: the web render is byte-identical. Rejected: leave the old host as `host` and drop only its rule (the
template requires a primary host); swap the Secret names by hand (not in git).

The old **web** host stays: Cloudflare 301s `weysure.beyrictech.com/*` to `https://weysure.com/` (C1), and its probe stays as the redirect canary.

## What's involved

| Where | Change |
|---|---|
| `plateng-gitops/projects/weysure/environments/prod/apps/api/values.yaml` | `ingress: { host: api.weysure.com, tlsSecretName: api-extra-tls }`; CORS list |
| `plateng-gitops/charts/beyric-app/templates/ingress.yaml`, `values.yaml` | optional `ingress.tlsSecretName` |
| `plateng-gitops/platform/monitoring/probes.yaml` | old API URL removed |
| `plateng-gitops/charts/beyric-app/tests/render-test.sh` | asserts one host and the Secret |
| Vault `secret/weysure/prod` | `PAYSTACK_SECRET_KEY`, `PAYSTACK_TEST_SECRET_KEY` (version 17) |
| Paystack dashboard | live and test webhook URLs |
| Cloudflare | DNS record `weysure-api.beyrictech.com` deleted |

## Verification (live, 2026-10-29)

| Check | Result |
|---|---|
| Key roll | shape script: both `sk_test_`, len 48, `SECRET==TEST true`, LIVE unset; pods restarted 21:39 UTC on `7cd2977636b0`, 0 restarts; only the 2 expected `[CONFIG]` warnings; no `[BOOT GUARD]` |
| Top-up | 21:43:56 UTC `POST /api/v1/wallet/paystack/webhook` on `api.weysure.com` → 200, `Signature verified, key class: developer_test,wallet`, `charge.success`; credited once (Adebayo); 0 signature-failure lines |
| `helm template` before/after | web identical; api: Ingress (old rule and `api-tls` entry gone) and 2 ConfigMaps (CORS) only |
| After merge | ingress only `api.weysure.com` / `api-extra-tls`; `api-extra-tls` not reissued (same `notAfter`); `api-tls` Certificate removed; api ×2 + worker rolled once, 0 restarts; health 200 |
| Old name | no answer at TLS; DNS `NXDOMAIN` |
| CORS | preflight from `https://weysure.com` 200 with allow-origin; from `https://weysure.beyrictech.com` 400 |
| Old web host | still `301 → https://weysure.com/` |
| Alert | `SiteDownExternal` fired for the old API probe 22:00:49–22:01:49 UTC: the ingress and the probe list are separate Argo apps. Predicted in the PR; cleared when the target left Prometheus |

**Not proven live:** the *live-mode* webhook URL (no live payment exists); only the test-mode URL had a real event. One `POST /wallet/topup/verify`
answered 400 three seconds before the webhook landed, then 200 (the app asked before Paystack's event arrived; SOP `2026-10-15-paystack-webhook-key-trust.md`
follow-up 4).

## Operate / roll back

- **Revert gitops #94** to re-add the old host and CORS origin (certificate reissues in about 1 minute via DNS-01), then re-create the DNS record. **Never redirect the API** (POST becomes GET).
- **Keys:** write the previous values with the same prompt; every key roll = Vault, force-sync, check pods, then dashboard. Do not roll during a payment.
- **Expected warnings** while prelaunch runs test keys: `PAYSTACK_SECRET_KEY is not set to a live key`, `PAYSTACK_TEST_SECRET_KEY equals the wallet or live key`.
- The Vault CLI printed a `patch` capability notice (the policy lacks `patch`; the CLI read-merged-wrote). Harmless alone; add the capability if concurrent writers appear.

## Follow-ups

1. Delete the orphan Secret `api-tls` (`kubectl -n weysure-prod delete secret api-tls`, Adebayo) once nothing references it.
2. Live-mode webhook proof at launch (launch gate in the 10-15 SOP: `PAYSTACK_SECRET_KEY` = `sk_live_`, TEST empty or our own).
3. Docs still naming the old API host (`ARCHITECTURE.md`, older SOPs, runbooks) are history; fix the ones an operator would copy from.
