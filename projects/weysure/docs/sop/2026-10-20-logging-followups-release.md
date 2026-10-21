# SOP — Weysure-API #91 (#78 logging follow-ups) + #99 (S3516 fix) live

**Shipped:** #91 merged 2026-10-19 17:22:14 UTC (`main` → `1b3b278`, tree identical to the approved `e85db3c`) → main #71
**failed main's Sonar gate** (1 new issue, S3516) → nothing built. Fix #99 merged 2026-10-20 12:18:11 UTC (`main` → `89883d3`,
tree identical to the approved `069be23`) → main #72 green, promoted `89883d393492` (gitops `b7bd7e0`, 12:51) → all 4 API pods
12:59:43 UTC · **Kind:** developer release, logging/security, no migration, no config · **Cost delta:** $0 ·
Notes/replies: `weysure/docs/platform-note-2026-10-17-logging-followups.md`, `platform-note-2026-10-19-99-logger-s3516.md`,
`platform-reply-2026-10-19-91-go.md`, `platform-reply-2026-10-19-91-main-gate.md`, `platform-reply-2026-10-19-99-go.md`,
`platform-reply-2026-10-20-91-99-live.md`

**Status: live and verified.** Closes follow-ups 1–4 of [#78's SOP](2026-10-16-logging-redaction-release.md).

## What it is

| #78 follow-up | Change (`app/core/logger.py` + call sites) |
|---|---|
| 1. `args` tuple | `_RedactTokens` redacts string items of `record.args` in place, keeps the tuple (uvicorn `AccessFormatter`) |
| 2. Reconciliation location | `describe_exception`: last frame under `app/`, not the deepest SQLAlchemy/psycopg frame |
| 3. DB error text | a chain holding a SQLAlchemy `StatementError` / `psycopg2.Error` (causes, contexts, exception groups) logs only `[Type at file:line]`: no traceback, SQL or bound values; loguru **and** uvicorn/gunicorn loggers; f-string sites use `safe_exception_text()` |
| 4. Regex | any `*token` query parameter, `=` or `%3D`, value ends at `&`/`%26`; `?tokenizer=` untouched |
| (extra) | `POST /wallet/withdraw` declares 400/401/403/404/409/500 in OpenAPI; no behaviour change |
| #99 | `filter` → one `return True`; body moved to `_redact_record() -> None` (Sonar `python:S3516`). Pure refactor |

**Ops consequence (accepted):** a database error in the logs no longer has a traceback; use `file:line` and reproduce locally.

## Review and the two gates

| Gate | Result | Lesson |
|---|---|---|
| PR-91 #3 (`weysure-api-pr`) | PASSED | — |
| main #71 (`weysure-api`) | **FAILED**, S3516 on `_RedactTokens.filter` | the shared `-pr` project's baseline is the previous PR analysed, not `main`: a PR pass is not proof |
| PR-99 #1 (`weysure-api-pr`) | **FAILED**, 1 issue S8410 on `admin_login` (`admin.py`, unchanged since 2026-02-13) | baseline was `pr-98` (refresh-token PR rewrote `admin_login`): noise outside the diff. **GO given with the PR check red** (Adebayo, one-off), main's gate as authority |
| main #72 (`weysure-api`) | PASSED | — |

Root-cause fix agreed with the developers: [Sonar PR base scan](2026-10-20-sonar-pr-base-scan.md).

Also found in review: `KYC_TIER_REQUIRED` is **403** (`KycError` default), not 422 as our #88 docs said (infra-tools #88).

## Verification (live)

Method as #78: **fake, non-JWT** values on the WebSocket route (uvicorn writes the full target; plain HTTP `/health` writes
no app access line, so it cannot prove anything). Alloy cannot mask non-JWTs, so Loki shows what the app wrote. `?token=` is
in the same request as a control.

| Check | Before (2026-10-19 17:46 UTC, `7770cf806803`) | After (2026-10-20 13:00 UTC, `89883d393492`) |
|---|---|---|
| WS `refresh_token=` | `token=REDACTED&refresh_token=probe91-base2-…-a` (**raw**) | `token=REDACTED&refresh_token=REDACTED` |
| WS `id_token%3D` | `token=REDACTED&id_token%3Dprobe91-base2-…-b` (**raw**) | `token=REDACTED&id_token%3DREDACTED`; 0 lines hold the marker |
| OpenAPI withdraw | `200, 422`; 217 schemas | `200, 400, 401, 403, 404, 409, 422, 500`; 217 schemas |
| Image | — | label `org.opencontainers.image.revision=89883d3…` (ECR) |
| Pods / spread | — | 4/4 on tag, 0 restarts; api on `ip-10-0-4-18` + `ip-10-0-4-241` |
| Errors / edge | — | 6 × `Worker … was sent SIGTERM!` (old pods, roll); 0 × 5xx in 109 Traefik api lines; health 200 both API hosts + web; Argo 32/32 |
| Reconciliation | — | new worker 13:12:43 UTC `wallet reconciliation: 1 users, 0 mismatches`, handler line `:53` (was `:56` on #78's code) |

Probe (run on the old image first for the "before"; needs `AWS_PROFILE=beyric-admin`; the handshake 403s on the fake token, which is fine):

```bash
m="probe91-<label>-$(date +%s)"
kubectl -n monitoring port-forward svc/loki 13100:3100 >/dev/null 2>&1 &
W="https://api.weysure.com/api/v1/ws/messages"
for q in "token=$m-t&refresh_token=$m-a" "token=$m-u&id_token%3D$m-b"; do
  curl -s --http1.1 -o /dev/null -w "%{http_code}\n" -m 10 -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" "$W?$q"
done
sleep 45   # Alloy
# any hit = a value written raw; the after-state must return nothing here
curl -sG localhost:13100/loki/api/v1/query_range --data-urlencode "query={namespace=\"weysure-prod\", container=~\"api.*\"} |= \"$m\""
```

**Seen, not #91's scope:** Traefik's access log keeps the raw query string (`?refresh_token=…`). Real tokens there are JWTs,
which Alloy masks in every namespace; #76 part 2 (token out of the URL) is the real fix.

## Operate / roll back

- Rollback: API image `7770cf806803` (gitops `images.yaml`); no migration since, so image-only is safe.
- Debugging a DB error: the log gives `Type at file:line` only; reproduce locally. Never turn tracebacks back on in prod.

## Follow-ups

- Developers: base-scan Jenkinsfile PRs (API, then web); make
  `test_replayed_charge_success_for_a_funded_developer_escrow_does_not_stall` deterministic (timed out under load locally).
- #76 part 2 (API #89 / web #56): WS auth via subprotocol, token out of the URL.
