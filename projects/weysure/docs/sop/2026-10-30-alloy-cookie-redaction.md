# SOP — Alloy masks sign-in cookie values before they reach Loki

**Shipped:** gitops [#95](https://github.com/Beyric/plateng-gitops/pull/95) merged 2026-10-30 11:32 UTC (`eac7684`) → Argo synced the `alloy` Application → each node's Alloy hot-reloaded its config ·
**Kind:** observability config in `bootstrap/apps/alloy.yaml`, no image change, no pod restart · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-30-auth-cookie-answers.md`, `platform-reply-2026-10-30-auth-cookie-checks.md`.

**Status: live and verified.** Method follows the JWT redaction of 2026-10-15 (API #76).

## Why

The developers' cookie sign-in (`ACCESS_COOKIE_MODE` off → dual → cookie_only) sets six cookies on `api.weysure.com`: `wey_at`, `wey_aat`, `wey_rt`, `wey_art`, `wey_did`, `wey_mfa`. The access cookies are JWTs (already masked by the JWT rule). The refresh, device and 2FA cookies are **opaque**, so no shape-based rule catches them. Loki keeps logs 7 days, so a leaked refresh cookie would stay valid-looking in the log store for a week.

We checked first: Traefik logs no header fields, and a 7-day Loki search for the cookie names found 0 lines. The rules are a net for the day someone logs a header, a `Set-Cookie` or a cookie dict.

## What changed

Three `stage.replace` blocks added after the JWT stage in `loki.process "redact"` (applies to every namespace):

| Stage | Matches | Example result |
|---|---|---|
| by cookie name | `\bwey_(?:at\|aat\|rt\|art\|did\|mfa)=([^;\s"',]+)` | `wey_mfa=<redacted-cookie>` |
| by dict/JSON key | `["']wey_(...)["']\s*:\s*["']([^"']+)["']` | `'wey_art': '<redacted-cookie>'` |
| by header name | `(?i)\b(?:set-)?cookie["']?\s*[:=]\s*["']?([^"'\r\n]+)` | `Cookie: <redacted-cookie>` |

`stage.replace` replaces only the **first capture group**, so the name and key stay and only the value goes. Decoys must stay unchanged: `REFRESH_COOKIE_SECURE=true ACCESS_COOKIE_MODE=dual` and `wey_did_lookup=…`.

## Verification

| Check | Evidence |
|---|---|
| Test | `platform/monitoring/tests/alloy-redact-test.sh` runs the real block in Alloy v1.19.2 (the cluster's version) in Docker: **19/19 passed** (12 existing, 5 new cookie cases, 2 decoys) |
| Live config | the `alloy` ConfigMap holds 3 `redacted-cookie` stages |
| Reload | of 4 Alloy pods, the two that were running at the merge logged config-reloader reloads; `alloy-p7hm7` started 12:46 UTC, after the merge, so it started with the new config |
| Not exercised live | a real cookie in a real log line (none is logged today); the Docker test is the evidence |

## Operate / roll back

- Revert gitops #95; the reloader sidecar re-applies the old config on each node.
- Change a rule: edit `bootstrap/apps/alloy.yaml`, run `bash platform/monitoring/tests/alloy-redact-test.sh` from the gitops root (needs Docker, ~30 s) and add a case for the new rule.
- Cookie names are fixed by the developers' design; a new cookie needs a new name in the first two regexes.

## Follow-ups

- [ ] Tell the developers to keep cookie values out of log lines anyway (this is a net, not a licence).
- [ ] If a cookie is added or renamed, update the regexes and the test in the same change.
