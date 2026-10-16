# SOP — Weysure-API #78 (logging: no diagnose, token redaction) live

**Shipped:** #78 merged 2026-10-16 20:08:40 UTC (rebase-merge, 4 commits, `main` `af04c82` → `d8c0450`; each commit
patch-identical to the approved `6cf4f1c`) → main build #64 green 20:39:06 UTC, promoted `d8c04502febf` (gitops `56f78b6`)
→ Argo picked it up 20:44:49 → all 4 API pods 20:47:36 UTC · **Kind:** developer release, no migration, no config ·
**Cost delta:** $0 · Notes/replies: `weysure/docs/platform-note-2026-10-16-78-logging.md`,
`platform-reply-2026-10-16-78-{go,live}.md` · Related: [JWT-in-logs redaction (Alloy)](2026-10-15-jwt-in-logs-redaction.md)

**Status: live and verified.**

## What it is

Three changes to what the API writes to its logs, plus a CI fix:

| Change | Where | Effect |
|---|---|---|
| loguru `diagnose=False`, `backtrace=False` | `app/core/logger.py` | Tracebacks no longer print each local variable's value (tokens, emails, balances) |
| `token=` / `access_token=` redaction | `app/core/logger.py`: loguru `patcher` + a `logging.Filter` on `uvicorn{,.error,.access}` and `gunicorn.{error,access}` | `…/ws/messages?token=<JWT>` is logged as `?token=REDACTED` (closes Weysure-API #76 part 1) |
| Reconciliation failure logs type + location only | `app/worker/handlers/wallet_reconciliation.py` | A DB error's text (which can carry bound values) is no longer logged |
| Jenkinsfile `timeout` 30 → 45 min | `Jenkinsfile:80` | See "The release" |

Platform side is unchanged: Alloy still redacts JWT-shaped strings and invite paths in every namespace (gitops #79, #80).
That is the backstop; this change is the app no longer writing the value in the first place.

## Review (before merge)

GO for exactly `6cf4f1c` (PR-78 build 3 green). How it was checked:

| Check | Result |
|---|---|
| Tests | `test_logging.py` + `test_wallet_reconciliation_job.py` 17/17 on a throwaway Postgres 16 (`localhost:5433`, as `tests/conftest.py` expects) |
| Prod launch mode | A probe ASGI app calling the PR's `setup_logging()`, run under **gunicorn + UvicornWorker** exactly as `boot/docker-run.sh` does: WS `?token=` and HTTP `&access_token=` → `REDACTED`. Same probe on `main`: 2 raw |
| diagnose off | Same exception: 35 `└ <value>` annotation lines on `main`, 0 on the PR |
| Alerts | `WalletReconciliationMissing` / `WalletLotDrift` match `wallet reconciliation: ` (unchanged); the failure line never fed an alert |

**Gotcha found (dev only, non-blocking):** the filter sets `record.args = None`. uvicorn's own `AccessFormatter` unpacks
`record.args`, so under plain `uvicorn` (`ENVIRONMENT=development`) a redacted access line becomes `--- Logging error ---`
and is lost. Prod is unaffected: `UvicornWorker` replaces the uvicorn loggers' handlers with gunicorn's plain ones. #75's
`app/core/log_redaction.py` already uses the right pattern (rewrite string items of `args`, keep the tuple).

**Review slip (ours):** the go said `6cf4f1c` was based on `af04c82`; it was branched from `7249abf` (before #75). A
`--is-ancestor … && echo` check printed nothing and the silence was read as a pass. Consequence after merge: the merged tree
differs from `6cf4f1c` by all of #75 (166 files), so "tree equals approved tree" does not apply. **Right check for a
stale-based PR:** `git range-diff <merge-base>..<approved> <old-main>..<merged>` (here: 4/4 `=`) plus equal
`git patch-id --stable` of the net diff; and confirm the files you tested are identical in the merged tree (they were).
PR builds are `pr-merge` builds, so CI already tested the code combined with #75.

## The release

| Step | Time (UTC) | Note |
|---|---|---|
| Merge | 20:08:40 | rebase-merge, 4 commits |
| main build #64 | 20:09:08 → 20:39:06 | **29 min 58 s: 2 s under the old 30-minute timeout.** The 45-minute timeout in this same PR is what made it safe |
| Promote | 20:39:03 | gitops `56f78b6` |
| Argo sync | 20:44:49 | 5 min 46 s after the promote (poll + jitter); do not sync by hand |
| PreSync migrate Job | ~20:45 | no migration; Job succeeded and was cleaned up |
| 4/4 pods on tag | 20:47:36 | one-out-one-in (quota `limits.cpu=8`) |

## Verification (live)

Method: a **fake, non-JWT token** (`probe78-<label>-<epoch>`) on `wss://api.weysure.com/api/v1/ws/messages?token=…`. Alloy's
JWT rule cannot match it, so whatever Loki holds is exactly what the app wrote. Script: session scratchpad
`probe78/live-probe.sh` (copy below).

| Check | Before (20:02 UTC, `af04c821c325`) | After (20:48 UTC, `d8c04502febf`) |
|---|---|---|
| Probe line in Loki | `"WebSocket /api/v1/ws/messages?token=probe78-base-…` (raw) | `"WebSocket /api/v1/ws/messages?token=REDACTED" 403` |
| Unredacted `[?&](access_)?token=` from `api*` | 46 lines / 24 h (real tokens, masked only by Alloy) | 0 since the rollout |
| Pods / spread | — | 4/4 on tag, 0 restarts; api on `ip-10-0-4-18` + `ip-10-0-3-16` (ADR-024); web unchanged on 2 nodes |
| Errors | — | only gunicorn `Worker … was sent SIGTERM!` from the old pods during the roll (6); 0 `└` annotation lines |
| Edge | — | 0 × 5xx at Traefik (45 api lines in the window, so the selector is live); health 200 on both API hosts and web; Argo 32/32 |
| Reconciliation | last old-pod line 20:43:30 `wallet reconciliation: 1 users, 0 mismatches` | new pod 21:13:38 `wallet reconciliation: 1 users, 0 mismatches` — handler line `:56` (was `:51`), so it is #78's code; alert substring intact |

**Not provable live:** `diagnose=False`. No exception was logged by the API in the 24 h before the release, so there is no
live `└` line to compare; the local before/after (35 → 0) is the evidence. It becomes visible at the first real exception.

```bash
# live-probe core: send, wait for Alloy, count (needs the Loki port-forward on 13100)
python - "$marker" <<'PY'   # websockets client; the handshake 403s on the fake token, which is fine
...
PY
curl -sG localhost:13100/loki/api/v1/query --data-urlencode \
  'query=sum(count_over_time({namespace="weysure-prod", container=~"api.*"} |= "token=REDACTED" [15m]))'
```

## Operate / roll back

- Rollback: API image `af04c821c325` (gitops `images.yaml`). Nothing in the database. Alloy redaction stays either way.
- A future exception now logs the stack without variable values. To debug, reproduce locally with `diagnose=True`; never
  turn it on in prod.

## Follow-ups (sent to developers in the go reply, non-blocking)

1. Keep the `args` tuple in `_RedactTokens` (dev `uvicorn` access lines) — reuse `log_redaction.py`'s pattern.
2. Reconciliation "location" is the deepest frame (SQLAlchemy/psycopg); prefer the last frame under `app/`.
3. Other `log.exception` sites still print exception text (Postgres `DETAIL: Key (email)=(…)`): audit DB paths.
4. Regex misses `refresh_token`, `invite_token`, encoded `%3D`; #76 part 2 (token out of the URL) is the real fix.
5. Jenkinsfile Build & push idempotent for `main` (developers' own PR). **Plus:** main builds now take ~30 min; 45 leaves
   15 min headroom — watch the trend (test time grew with #75).
