# SOP — Platform prep for Weysure-API #75 (deal invites): invite-token log redaction, migrate deadline, timeouts

**Shipped:** gitops #80 (Alloy path rule, merged 10:23:47 UTC, `05fc314`) and #81 (migrate Job deadline, merged 10:23:56
UTC, `3771014`), 2026-10-16 · **Kind:** platform config ahead of a developer release; #75 itself is not merged ·
**Cost delta:** $0 · Developers' note: `weysure/docs/platform-note-2026-10-14-deal-invites.md` (updated 10-16)

**Status: live (#80 verified); #81 takes effect at #75's sync (see below).**

## Why

#75's note asked the platform for three things before merge: (1) a migrate Job deadline above ~6 min for
`CREATE INDEX CONCURRENTLY ix_users_lower_email`; (2) `statement_timeout` 0 or high on the migrate connection;
(3) the invite token kept out of the ingress access log (it is a path segment: `/api/v1/invites/<token>`).

## How (and what we found)

| # | Finding | Decision |
|---|---|---|
| 1 | Chart default `activeDeadlineSeconds: 600`; prod did not override | **gitops #81:** prod `migration.activeDeadlineSeconds: 900` (inside the 30 min `weysure-migrate` Vault lease) |
| 2 | Nothing sets `statement_timeout`: RDS parameter group holds only `rds.force_ssl`; the Vault migrate role only `SET role = weysure_owner` | **No change.** Proven live (below). Developers asked to `SET statement_timeout = 0` inside the migration anyway |
| 3 | The invite token is a **JWT** (`create_deal_invite_token` → `create_access_token`), so the Alloy JWT rule from gitops #79 already redacts it in every namespace | **gitops #80:** add a path rule ahead of the JWT rule so a change of token format cannot reopen the leak; also covers the web page `/invite/<token>` and `Referer` fields the note did not mention |

Alloy rule (`bootstrap/apps/alloy.yaml`, `loki.process "redact"`): ``(?:/api/v1/invites/|/invite/)([^/?#\s"']+)`` →
`{token}`, the same output as the app's own filter (`app/core/log_redaction.py`).

## Verification

| Check | Result |
|---|---|
| #79 baseline | 0 raw JWT-shaped lines stored since the #79 reload (2026-10-15 22:09:30 UTC); `<redacted-jwt>` firing in traefik, weysure-prod, monitoring. (A 12 h window first showed 42 "leaks": all pre-reload; anchor look-backs to the change time) |
| #80 Docker test | `platform/monitoring/tests/alloy-redact-test.sh` (new, committed): exact block from `alloy.yaml` in `grafana/alloy:v1.19.2`, 12 cases incl. 4 decoys and the JWT regression → 12/12; against `main`'s config the 6 path cases fail; `alloy fmt` valid. Fake JWT built at run time (gitleaks blocks token literals) |
| #80 live | 3/3 Alloy pods `Reload triggered` 10:26:16–10:27:15 UTC; fake tokens sent to 404 paths → **0** raw in Loki; Traefik stored `POST /api/v1/invites/{token}/claim`, `GET /invite/{token}` |
| #81 | Argo `weysure-api` moved to `3771014` **Synced with no sync operation**: the deadline lives only on the PreSync hook, which Argo excludes from the diff. It applies when #75's sync renders the Job: **check `activeDeadlineSeconds: 900` on the migrate Job then** |
| `statement_timeout` (`db-oneoff.sh read`, migrate identity, `reset_val`) | `statement_timeout 0`, `lock_timeout 0`, `idle_in_transaction_session_timeout 86400000` (RDS default 24 h); only override on our roles = the Vault migrate user's `role=weysure_owner` (one row: lease cleanup works) |

## Operate

- At #75: the migrate Job should take seconds (small `users` table). Failure mode if a long-open transaction blocks the
  concurrent build: the migration's own `lock_timeout 300s` fails the Job at ~5 min with an INVALID index; a re-sync
  repairs it (the migration drops an INVALID leftover first). Then run the note's `indisvalid` query (expect `t`).
- `db-oneoff.sh` sets `SET LOCAL statement_timeout = '60s'` itself: read `reset_val`, not `setting`.

## Roll back

Revert gitops #80 (the JWT rule still covers today's token format) or #81 (deadline back to 600 s).

## Follow-ups

- #75 review and go (after its rebase onto `c737902`); check the migrate Job deadline and `indisvalid` at its release.
