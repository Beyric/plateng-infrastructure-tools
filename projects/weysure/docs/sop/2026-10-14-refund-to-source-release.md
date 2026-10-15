# SOP — Weysure-API #67 (refund to source, card-to-cash PR 3) deployed, flag off

**Shipped:** merged 2026-10-13 23:10:00 UTC (`9a4a5d3` → merge `acdae7f`) → promoted `acdae7fd271c` ~23:31 UTC (gitops
`3acf49c`) → migration `d4b7f2a91c68` in PreSync → Argo Succeeded 23:38:48 UTC · **Kind:** developer release with a
migration; no gitops change · **Cost delta:** $0 · Developers' notes: `weysure/docs/platform-note-2026-10-13-c2c-refund-to-source.md`,
`platform-note-2026-10-13-67-sonar-fixed.md`; our replies: `platform-reply-2026-10-13-67-sonar-gate.md`,
`platform-reply-2026-10-13-c2c-refund-to-source.md`

**Status: live and verified. No behaviour change: `REFUND_TO_SOURCE_ENABLED` unset (code default `false`), `SOURCE_REFUND_RETRY_ENABLED` unset (`false`).**

## What shipped

| Area | Change |
|---|---|
| Schema | migration `d4b7f2a91c68` (parent `58f3a1c7e0b9`): enum value `SOURCE_REFUND` on `wallettransactiontype` (autocommit block), enums `source_refund_status`, `manual_payout_status`, tables `source_refunds`, `manual_payout_requests` + partial unique indexes. Expand-only |
| Jobs (api-worker) | `source_refund.recheck` (per card refund + startup sweep); off switch `JOBS_DISABLED_KINDS=source_refund.recheck` |
| API | `POST /wallet/refunds`, `POST /wallet/manual-payouts`, lists, admin queues; 403 `REFUND_TO_SOURCE_DISABLED` while the flag is off |
| Egress | same host `api.paystack.co`, new paths (`/refund`, `/transaction/verify`); `api-egress` 443 already allows it |
| Secrets / config | none new; all settings have safe defaults |

## How (key decisions and review findings)

- **Order:** #64 closed first (`alembic current` = `58f3a1c7e0b9`, infra-tools #73), then #67. One migration release at a time.
- **Enum naming checked in prod before merge:** `SELECT unnest(enum_range(NULL::wallettransactiontype))` returned member
  *names* (`TOPUP … REFUND`), matching SQLAlchemy `Enum()` without `values_callable`; no `SOURCE_REFUND` yet.
- **Sonar:** PR-67 #2 FAILED "New issues 8 > 0" (all in files the PR adds: 4× `Annotated`, 2 duplicated literals,
  `plan()` complexity 16, `dict.fromkeys`). Fixed in code, none Accepted; #3 green (`9a4a5d3`). Reviewed the refactor:
  verbatim move into `_assign_lots`; `failed.get(id) is not None` ≡ `id in failed` (`_failed_amounts` stores only `Decimal`);
  `lots_of` kept its per-key list (a `dict.fromkeys(BASES, [])` would share one list).
- **Note corrected:** refunds are off by `REFUND_TO_SOURCE_ENABLED`, not `SOURCE_REFUND_RETRY_ENABLED` (retry endpoint only).
- **No staging:** the Paystack test-mode proof runs on a developer machine with test keys; prod never gets test keys.

## Verification

| Check | Result |
|---|---|
| Merged commit | `9a4a5d3` = the approved head; Jenkins `main` build success |
| Argo `weysure-api` | `3acf49c`, operation Succeeded 23:38:48 UTC (brief `Degraded`: quota-delayed scheduler surge + startup probes) |
| Migration Job (Loki `container="migrate"`) | `Running upgrade 58f3a1c7e0b9 -> d4b7f2a91c68` |
| `alembic current` | `d4b7f2a91c68 (head)` — `scripts/db-oneoff.sh acdae7fd271c alembic "current"`, Job `db-oneoff-20261015122650` |
| Pods | api ×2 (`ip-10-0-3-242`, `ip-10-0-4-49`), scheduler, worker on `acdae7fd271c`, 0 restarts |
| Errors since rollout | 0 error/Traceback; 0 `source_refund_orphan` / `_conflict` / `_unresolved` |
| Worker | `startup sweep ensure_source_refund_rechecks: 0 job(s) scheduled` (job kind registered) |
| Sites | web 200, API `/api/v1/health` 200 |

## Roll back

**Flag only; fix forward.** An image revert fails our PreSync (older image cannot locate `d4b7f2a91c68`). `alembic downgrade`
refuses while any refund is open or any payout awaits review. With the flag off nothing is user-visible.

## Follow-ups (before `REFUND_TO_SOURCE_ENABLED=true`)

- Loki alerts: `source_refund_orphan`, `source_refund_conflict` → page; `source_refund_unresolved`, `source_refund_stale`,
  `source_refund_over_taken` → ticket. Tested with decoy lines like the withdrawal alerts.
- Developers' test-mode capture: real `refund.*` webhook body + `RESULTS.md`.
- Before any later release of this area: `SELECT count(*) FROM source_refunds WHERE status NOT IN ('processed','failed','not_sent')`.
- Quota `limits.cpu=8` delayed the rollout again (6th time) — checklist item.
