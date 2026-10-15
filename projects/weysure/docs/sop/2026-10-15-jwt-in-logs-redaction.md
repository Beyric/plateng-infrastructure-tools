# SOP — login tokens in logs: Alloy redaction + SECRET_KEY rotation

**Shipped:** 2026-10-15 · gitops #79 (Alloy `loki.process "redact"`), reloaded on all 4 Alloy pods by 22:09:09 UTC →
`SECRET_KEY` rotated 22:12:06 UTC (Vault `secret/weysure/prod` v16, generated inside Vault, 128 hex chars) → ExternalSecret
force-synced 22:12:49 UTC → api, api-worker and api-scheduler restarted · **Kind:** security fix (platform), no app release
· **Cost delta:** $0 · Found by the developers in the web #51 live check: Weysure-API#76; our reply
`weysure/docs/platform-reply-2026-10-15-jwt-in-logs.md`

## Why

The API access log (uvicorn) prints the full WebSocket URL, `/api/v1/ws/messages?token=<JWT>` (and `/ws/notifications`).
Alloy shipped those lines to Loki: **367** lines with `token=eyJ` from `container=api`, the oldest 2026-10-08 22:44 UTC.
That's the whole window, since Loki retention is `1w` and deletes are off (`allow_deletes: false`). Access tokens live
**7 days** (`ACCESS_TOKEN_EXPIRE_MINUTES`), so any stored token could still be a valid session, admins included.
Readers were limited to platform operators (Loki has no Ingress; Grafana is behind Cloudflare Access).

## How

| Step | Decision |
|---|---|
| Redact at the shipper first | `loki.process "redact"` between `loki.source.kubernetes` and `loki.write`: regex `eyJ…\.eyJ…\.…` → `<redacted-jwt>`, **all namespaces**. Platform-owned, so it holds whatever the API fix looks like and covers future leaks |
| Then rotate `SECRET_KEY` | Voids every issued JWT, so the stored lines hold dead tokens. Order matters: rotating first would leak the new tokens until redaction was live. Safe: the key signs JWTs, setup/reset links and OTP hashes only; nothing stored is encrypted with it (10-09 SOP) |
| No Loki purge | Deletes are disabled, and enabling them for one purge is more change than the risk left after rotation. The lines age out by ≈ 2026-10-22 |
| API side (developers, #76) | Redact `/ws/*` query strings in the access log; move the WS token out of the URL; consider a shorter token lifetime before launch |

## Verification

| Check | Result |
|---|---|
| Alloy unit test | Alloy v1.19.2 in Docker: URL token and `Bearer` token → `<redacted-jwt>`; access-log and JSON (`"eyJ"` key) lines unchanged; `alloy fmt` valid on the rendered cluster config |
| Live | All 4 Alloy pods reloaded (22:08:09–22:09:09 UTC; components `loki.process.redact` present). 4 WebSocket handshakes with **fake** JWT-shaped tokens hit both api pods → all 4 stored as `token=<redacted-jwt>`. Raw-token lines after 22:09:09 UTC: **0**. A test 47 s before the last node reloaded was not redacted, so each node reloads on its own |
| Rotation | Vault v16 at 22:12:06 UTC, length 128; ExternalSecret refreshed 22:12:49 UTC; pods restarted (see below) |

## Operate / roll back

- Reverting gitops #79 would re-expose tokens; don't, unless the API redacts first (#76).
- `SECRET_KEY` rotation cannot be undone (the old value is gone). It doesn't need to be.
- Check for leaks at any time (counts only): `sum(count_over_time({namespace="weysure-prod"} |~ "token=eyJ" [1h]))` should be 0.

## Follow-ups

1. Developers: Weysure-API#76 (redact, token out of URL, shorter lifetime).
2. Consider a Loki alert on `|~ "eyJ[A-Za-z0-9_-]{8,}\\.eyJ"` (should never match after redaction) as a tripwire.
