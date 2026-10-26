# SOP — `api-scheduler` removed; WebSocket tokens refused in the URL

**Shipped:** gitops [#91](https://github.com/Beyric/plateng-gitops/pull/91) (`b16d6c66`, merged 2026-10-26 11:50 UTC) and
[#92](https://github.com/Beyric/plateng-gitops/pull/92) (`e695d966`, merged 12:03 UTC, live 12:10 UTC) · **Kind:** platform config, no image,
no migration · **Cost delta:** $0 (the scheduler already ran 0 replicas) · Replies: `weysure/docs/platform-reply-2026-10-26-ws-url-token-off.md`.

**Status: live and verified.**

## What it is

| Change | Detail |
|---|---|
| **#91 remove `api-scheduler`** | component block out of `projects/weysure/environments/prod/apps/api/values.yaml` (Argo `prune: true` deleted its Deployment, ConfigMap, ServiceAccount); dropped from NetworkPolicies `api-egress` / `redis-ingress-from-api` (`network/allow.yaml`) and from `WalletLotDrift`'s selector (`platform/monitoring/loki-rules-wallet.yaml` → `container=~"api\|api-worker"`); render and Loki rule tests follow |
| **#92 `WS_ALLOW_URL_TOKEN: "false"`** | in `commonEnv` (both API ConfigMaps). Ends the switch period of Weysure-API #89: a WebSocket handshake carrying `?token=` is refused, even beside a valid `Sec-WebSocket-Protocol: weysure.bearer, <jwt>` header |
| This PR | `scripts/platform-sleep.sh` stops naming `api-scheduler`; runbooks (`SLEEP_WAKE`, `RESTORE_DRILL`, `SECRETS_ROTATION`, `VAULT_CONFIG`) and checklist updated |

## Why

- **Scheduler:** idle since Weysure-API #68 (2026-10-15; the reconciliation runs in `api-worker` as `wallet.reconciliation`), `replicas: 0`
  since gitops #89 ([SOP](2026-10-24-api-scheduler-zero.md)); removal was planned for after Train 1b + 2 (both live).
- **WS token:** a token in a URL lands in Traefik and uvicorn access logs (and Loki). Web Train 2 (#66, live 09:14 UTC) moved every socket
  to the subprotocol header; the server flag closes the old path.

## How (decisions)

| Decision | Why |
|---|---|
| Prove #91 with a `helm template` diff (prod values + `images.yaml`), not the values diff | Argo applies what renders: removed 3 objects, **changed 0**, so api/worker could not restart |
| Render test's "3 Vault-Agent pods" count changed to 2, not loosened | the count exists to catch a pod silently losing its sidecar |
| #92 only after #91 was live in **every** owning Argo app; rebased and re-proven | one change at a time; tested tree = merged tree |
| `?token=` safe to refuse only on a **positive** proof | prod had no socket traffic since 10-22; "0 `?token=` lines" alone would also be true with zero users. Proof = real connect without query (09:26 UTC) + code read of web `main` + Loki `token sent in the URL` 0 since 09:14 + developers' client sweep |
| Checked the flag is not in Vault's `weysure-app-config` | in `envFrom` the Secret beats the ConfigMap: a git change would be silently ignored |

## Verification

| Check | Evidence |
|---|---|
| #91 `weysure-api` | Synced `b16d6c66` 11:54 UTC; `kubectl get deploy,cm,sa \| grep scheduler` → 0; api/worker pods unchanged (started 10:24, 0 restarts) |
| #91 other apps | Loki ruler `/loki/api/v1/rules`: `WalletLotDrift` `container=~"api\|api-worker"`; `weysure-prod` synced 11:57 UTC (it reconciled 25 s after the merge, before the repo fetch, so one extra poll); both NetworkPolicies without `api-scheduler` |
| #91 local CI | render-test OK (13 api objects, was 16); pre-commit 7/7; `loki-rules-wallet-test.sh` all PASS (Loki 3.6.11 + Alertmanager) |
| #92 roll | Argo `e695d966`; ConfigMaps `WS_ALLOW_URL_TOKEN=false`; Reloader rolled api ×2 (two nodes) + api-worker 12:09–12:10 UTC, same image `c232753c8746`, 0 restarts; `[FLAGS]` api + worker `WS_ALLOW_URL_TOKEN=false` |
| #92 refusal (fake non-JWT token) | `?token=` only → **403**, log `WebSocket handshake rejected: token sent in the URL (no longer supported)`; `?token=` + header → **403**, same line; header only (control) → **403** `Invalid or expired token` (header path still checked) |
| #92 real clients | a signed-in web tab reconnected through the roll: `/ws/messages`, `/ws/notifications` **`[accepted]`**, no query string (12:10 UTC) |

Probe (fake values only; reuse with a new marker):

```bash
M="probe-$(date +%s)"; W="https://api.weysure.com/api/v1/ws/notifications"
probe(){ curl -s --http1.1 -o /dev/null -w "%{http_code}\n" -m 10 -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" "$@"; }
probe "$W?token=$M-a"                                                 # expect 403 + "no longer supported"
probe -H "Sec-WebSocket-Protocol: weysure.bearer, $M-b" "$W?token=$M-b"  # expect 403 + "no longer supported"
probe -H "Sec-WebSocket-Protocol: weysure.bearer, $M-c" "$W"             # control: 403 "Invalid or expired token"
```

## Operate / roll back

- A refused handshake is an HTTP **403** on the upgrade (the server refuses before `accept`); the browser's `close` event shows **1006**.
  Loki: `{namespace="weysure-prod",container="api"} |= "token sent in the URL"`.
- Roll back #92: revert (code default `true`); Reloader restarts api + worker. Roll back #91: revert (component returns with `replicas: 0`).

## Follow-ups

- [ ] Adebayo: trim `api-scheduler` from Vault `auth/kubernetes/role/weysure-api` `bound_service_account_names` (read the role first; `vault write` replaces every field)
- [ ] Developers: drop "switch period" wording in `docs/fe-integration-guide-websockets.md`
