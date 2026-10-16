# SOP — Weysure-API #70 (admin hardening) live

**Shipped:** #70 merged 2026-10-16 09:07:24 UTC (rebase-merge, head `38b579b`, same tree `fbd7ab9` as the approved
`360e994`) → Jenkins main #58 green 09:28 UTC → promoted `38b579b34f51` (gitops `088d901`) → all 4 API pods on it
09:37:35 UTC · **Kind:** developer release, no migration, no config, no dependency · **Cost delta:** $0 ·
Developers' note: `weysure/docs/platform-note-2026-10-14-admin-hardening.md`; our replies:
`platform-reply-2026-10-16-70-go.md`, `platform-reply-2026-10-16-70-live.md`

**Status: live and verified, closed 2026-10-16 10:38 UTC** (refused-action checks below).

## Why

- `POST /admin/update-status/{id}` with `{}` wrote `NULL` to `admins.is_active`, after which `GET /admin/admins` returned
  500 for every admin.
- Nothing stopped the last active superadmin from being removed, or two superadmins from demoting each other at once
  (both pass the role check, both commit, zero superadmins left).
- `PATCH /admin/escrow/settings` checked only some invariants, and only against the patch, not the stored values.

## How (what the developers built, what we reviewed)

| Change | Where |
|---|---|
| `is_active` must be a real boolean (`StrictBool`); explicit `null` for `is_active`/`role` on `PUT` → 422 | `app/schemas/admin.py` (`AdminStatusUpdate`, `AdminManage`) |
| Guard: `SELF_ACTION` 409 (self deactivate/demote), 403 for the loser of a mutual demotion, `LAST_SUPERADMIN` 409 backstop | `app/services/admin_guard.py` |
| Lock every active superadmin row in id order (`FOR UPDATE`, filter re-checked by Postgres after the wait) | `app/db/row_locks.py:lock_active_superadmins` |
| Escrow settings: lock the active row, check the merged result (`SETTINGS_FEE_RANGE`, `_TIER_ORDER`, `_DAYS_RANGE`, 400 + `code`); handler `async def` → `def` | `app/api/v1/endpoints/admin_escrow_settings.py` |
| `GET /admin/admins` reads NULL `is_active` as `false` | `AdminOut` validator |

Review (Opus, security-critical: permission checks + row locks). **GO at exactly `360e994`.** Points checked:
- Only two routes write `role`/`is_active`; both guarded; no delete route.
- No lock cycle: superadmins locked in id order, target after; the two `lock_admin` callers take one row only.
- `async def` → `def` is required: a `FOR UPDATE` wait inside `async def` blocks the pod's event loop.
- Race test runs on real Postgres with a slowed lock (SQLite would make `FOR UPDATE` a no-op).
- Content approval: merged tree compared to the approved commit's tree (`git rev-parse <sha>^{tree}`), equal.

## Verification

| Check | Result |
|---|---|
| Migration Job | ran, no-op (alembic context lines only); head unchanged `d4b7f2a91c68` |
| Pods | api ×2, api-worker, api-scheduler on `38b579b34f51`, Running |
| Health | 200 on `api.weysure.com` and `weysure-api.beyrictech.com`; web 200 |
| New code is serving (no credentials) | `/api/v1/openapi.json` schemas: `AdminStatusUpdate` (`is_active` required boolean), `AdminManage` — 0 → 2 vs pre-merge baseline |
| Errors | 0 error/traceback lines from new pods; `[ERROR] Worker … SIGTERM` only from old pods (shutdown) |
| Traefik | no 5xx on the API router since the roll (low traffic) |
| Refused actions in prod (Traefik access log) | Developers 10:20 UTC: `PUT /admin/<id>` → 422, → 409 (107 B). Adebayo 10:38 UTC (`refusal70.sh`, token read silently): `update-status/<made-up id>` `{}` → **422** (92 B; the old code would answer 404, so this step is safe on either version and gates the next); `update-status/<own id>` `{"is_active": false}` → **409 `SELF_ACTION`** (107 B); `/admin/me` before/after unchanged |

Rollout note: surge pod `FailedCreate … exceeded quota limits.cpu=8` again; the roll ran one-out-one-in. Known (deferred
table, right-sizing).

## Gotchas learned

- Traefik's access log has **no host**: match the router name (`websecure-weysure-prod-api-…@kubernetes`), not
  `api.weysure.com` — a host filter returns 0 lines and looks like "no 5xx".
- Prod serves the OpenAPI schema at `/api/v1/openapi.json` (`/openapi.json` is 404): diffing schema keys before/after
  proves a release that adds request models is serving, with no token and no PII.
- Alertmanager via `kubectl get --raw …/proxy` hangs (default-deny NetworkPolicy); use `port-forward`.

## After the release

- Weysure-API #77 (docs only) was merged 10:26 UTC without our go; its main build #59 was aborted by the 10:30 spot
  interruption, so nothing was promoted. Decided: do not re-run it; #77 ships with #75's build. Developers told.
- Same endpoint, three sizes: 403 / 30 B = auth stopped it (no token), 422 = body refused before the handler,
  409 / 107 B = the guard ran.

## Operate / roll back

Revert the API image to `7249abff973c` (gitops `images.yaml` revert of `088d901`). No database change to undo.

## Follow-ups (non-blocking, sent to developers)

1. Audit row is written in a second commit after the change; put both in one transaction.
2. No `lock_timeout` on the API's DB sessions (the worker has one).
3. Two superadmins can `reset-password` each other at once and both lose access until they use their emailed links.
