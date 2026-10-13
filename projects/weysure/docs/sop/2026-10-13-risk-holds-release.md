# SOP — Weysure-API #64 (risk holds, card-to-cash PR 4) deployed, every flag off

**Shipped:** merged 2026-10-13 15:29:34 UTC → promoted `f9cf2e8d6a3f` 15:50:21 UTC (gitops `3b293a7`) → migration
`58f3a1c7e0b9` 15:51:52 UTC → pods 15:52–15:54 UTC · **Kind:** developer release with a migration; no gitops change in
the release itself (flags were pre-set in gitops #72) · **Cost delta:** $0 · Developers' note:
`weysure/docs/platform-note-2026-10-13-c2c-risk-holds.md`; our replies: `platform-reply-2026-10-13-web-48-and-api-64.md`,
`platform-reply-2026-10-13-64-platform-ready.md`

**Status: live and verified. No behaviour change: `RISK_HOLDS_MODE=off`, `RISK_SIGNALS_CAPTURE_ENABLED=false`.**

## What shipped

| Area | Change |
|---|---|
| Schema | migration `58f3a1c7e0b9` (parent `c9a4e1b7d230`): tables `wallet_holds`, `risk_signal_sightings` (BigInteger id → sequence), `risk_hold_settings` (seeded id = 1), enums `wallet_hold_reason`, `wallet_hold_status`. Create-only |
| Jobs (api-worker) | `wallet.hold_release` (per hold), `risk.sightings_purge` (daily, seeded by the startup sweep) |
| API | `/wallet/balance` gains `spendable`, `on_hold`, `holds[]`; new 400/409 codes; admin `/admin/wallet-holds`, `/admin/risk-holds/settings` |
| Boot validators | `enforce` requires `ORIGIN_RULES_ENFORCED=true`; capture requires a ≥32-byte `RISK_SIGNAL_HASH_KEY` |
| Config (gitops #72, before the release) | `RISK_HOLDS_MODE=off`, `RISK_SIGNALS_CAPTURE_ENABLED=false`; `RISK_DEVICE_COOKIE_DOMAIN` unset (host-only) |

## How (key decisions and review findings)

- **Order:** web #48 → flag `ORIGIN_RULES_ENFORCED=true` (#72) → Traefik NLB-only (#71) → client IP (#66) → #64. One at a time.
- **DB grants checked before merge:** migrations run as `weysure_owner`; default privileges give `weysure_app` DML on tables
  and USAGE/SELECT on sequences (`db-grants-v2`), so the new sequence needed nothing.
- **Cookie domain:** developers' example `.weysure.com` did not match prod hosts (`*.beyrictech.com`); `.beyrictech.com`
  would send the device cookie to Jenkins/Sonar/Grafana/Argo. Kept host-only (same-site Lax works; CORS already allows
  credentials for the exact web origin).
- **Note corrected:** web #48 does not send `credentials: "include"`, so the capture stage needs a further web change.
- **Sonar:** PR-64 #1 FAILED and #2 PASSED on the same commit (`5a92c33`): the `-pr` project compares with the previous PR's
  analysis. The real issue (redundant `list()` at `app/services/wallet_origins.py:167`, correct per SQLAlchemy 2.0.41
  `identity_map.values()` returning a new list) was fixed in `6947d22`; PR-64 #4 PASSED (14:43:59 UTC).
- **Rebase onto #66 checked with `git range-diff`:** 24/27 commits identical; 3 differ only by conflict resolution (imports,
  #64's stub `client_ip.py` dropped for #66's, docs); plus `6947d22`.

## Verification

| Check | Result |
|---|---|
| Argo `weysure-api` | `3b293a7`, operation Succeeded 15:53:58 UTC; 32/32 Synced/Healthy |
| Migration Job (Loki `container="migrate"`) | `Running upgrade c9a4e1b7d230 -> 58f3a1c7e0b9` at 15:51:52 UTC |
| `alembic current` | `58f3a1c7e0b9 (head)` — `scripts/db-oneoff.sh f9cf2e8d6a3f alembic "current"`, Job `db-oneoff-20261013180105` |
| Pods | api ×2 (`ip-10-0-4-17`, `ip-10-0-4-52`), scheduler, worker on `f9cf2e8d6a3f`, 0 restarts |
| Errors since 15:45 UTC | 0; `risk_hold_eval_failed` / `risk_hold_shadow_failed` / `risk_sighting_failed`: 0 |
| Worker | `ensure_sightings_purge: 1 job(s) scheduled` → `sightings purge removed 0 row(s)` → next 2026-10-14 15:52; `ensure_hold_release_jobs: 0` |
| Sites | 200 / 200 |

## Roll back

**Fix forward.** After the migration, an image revert fails our PreSync (the older image cannot locate `58f3a1c7e0b9`);
`alembic downgrade` refuses with active holds and drops sightings, so it is not a rollback path. With every flag off there is
nothing user-visible to roll back. Stage rollbacks (later) are the flags.

## Follow-ups (each stage = new developer note + our go)

- **Capture:** create `RISK_SIGNAL_HASH_KEY` in Vault (64 random bytes on stdin, never printed; do-not-rotate); needs the
  privacy-policy clause and a web change sending `credentials: "include"`.
- **Shadow:** Loki alerts on any `risk_hold_eval_failed` / `risk_sighting_failed` first; panel for `risk_hold_placed` /
  `risk_hold_shadow` per hour; threshold agreed after the shadow run.
- **IP signal:** possible now (#66 verified 14:34 UTC).
- **Enforce:** origin rules already on.
