# SOP — Weysure-API Train 3 (#128) live

**Shipped:** #128 merged 2026-10-26 16:46:22 UTC as a **merge commit** (`main` → `cdc254f0`, approved head `6efee785`) → main build
green 17:35:39 UTC (49 min) → promoted `cdc254f0a78e` (gitops `c32e03ae`) → PreSync migrate + api ×2 + api-worker, Argo
Succeeded/Healthy 17:41:38 UTC · **Kind:** developer release train A1–A11 (A1 DVA guard counts deactivated, A2 superadmin-only resume,
A3 wallet disputed, A4 usage-log bodies purged and no longer stored, A5 live auto-pause (ships `off`), A6 invite follow-ups, A7
chargeback job timer, A8 paused email, A9 verify-email token in the body, A10 FAQ wording, A11 `usage_logs` 90-day retention job) ·
**One data-only migration** `e4b8d1a6c372` → `b3f6a9d2c814` (no schema change) · no platform config · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-25-train-3-api.md`, `platform-reply-2026-10-26-train-3-early.md`,
`platform-question-2026-10-26-pr128-pr-merge-error.md`, `platform-reply-2026-10-26-pr128-sonar-gate.md`,
`platform-reply-2026-10-26-train-3-api-go.md`.

**Status: live and verified.** Fourth release train; method of [Train 2](2026-10-25-train-2-release.md).

## What it is

The developers' Train 3 API, which the platform side reviewed and gated. Every new capability ships off, except A4 (bodies purged and no
longer stored) and A11 (row retention, 90 days, Adebayo's decision 2026-10-26).

## Why it went the way it did (decisions)

| Decision | Reason |
|---|---|
| Rollback rewritten before the GO: downgrade **with the train image** first, then gitops back | the old image cannot run against `b3f6a9d2c814` (the PreSync `alembic upgrade head` fails with "Can't locate revision"); the A4 downgrade is a no-op that only moves the pointer |
| First `pr-merge` (`40f78eab`) was treated as a **code failure**, not re-run | the log showed `QUALITY GATE STATUS: FAILED`, exit 3; Sonar DB `new_violations` 3 (S8410, `verify_email` `Annotated`). The `release/*` branch build runs no Sonar, so its green said nothing. Fix = a new commit and a GO on the new SHA |
| Independent Opus review of A2 / A4 / A5 / A11 even though the developers had one | permission (A2), data deletion (A4, A11) and automatic account action (A5) paths; the developers had not reviewed A11 |
| A11 accepted inside the approved train | Adebayo decided 90 days on 2026-10-26; the first run deletes 0 rows (pre-merge read) |
| GO held on Adebayo's reads, including **table size** | A4 runs in one transaction despite its batches; 80 kB makes that irrelevant |

## Review findings (none blocking)

| Area | Finding | Status |
|---|---|---|
| A2 | `live_pause.resume` is the only un-pause path; both callers use the server-side `ResumeSuperAdmin` check | confirmed |
| A4 LOW | batches do not commit separately (`env.py` runs the whole upgrade in one transaction) | irrelevant at 80 kB; use `autocommit_block()` in future large data migrations |
| A4 LOW | old pods (`c232753c`, `usage_logging.py:73/115`) store request bodies until the roll ends | post-roll read: `with_body` 0; cleanup `UPDATE` committed 0 rows |
| **A5 MED (enforce only)** | `same_payer` and `refund_ratio` rules have no minimum amount: 5 tiny payments can pause an honest developer, and only a superadmin can undo it | **blocks `LIVE_AUTO_PAUSE_MODE=enforce`** until fixed and run in `shadow` |
| A5 LOW | `shadow` repeats the same WARNING each pass | fix with the MED |
| A11 | 0 / negative = off; cutoff direction and UTC correct; one job via `dedupe_key`; `JOBS_DISABLED_KINDS` honoured | confirmed |

## Verification (all live, 2026-10-26)

| Check | Result |
|---|---|
| Structure at `6efee785` | main `c232753c` merged in (no rebase); Jenkinsfile = main; single Alembic head `b3f6a9d2c814` (`down_revision e4b8d1a6c372`); 0 AI trailers |
| PR-128 #2 (`pr-merge`) | 5580 passed / 0 failed; changed-line coverage 98%; Sonar `pr-128` `new_violations` 0 (Sonar DB); Trivy CRITICAL 0 |
| Pre-merge reads (Adebayo, `c232753c8746`) | `dedicated_accounts`: no rows; `usage_logs` with_body / total **2 / 2**; older than 90 days **0**; size **80 kB** |
| Merge | watcher: merged head = approved `6efee785` → `cdc254f0` |
| Argo `weysure-api` | `c32e03ae` Synced, Succeeded, Healthy; PreSync ExternalSecret → `db-migrate` SA → Job `weysure-api-db-migrate` **Succeeded** |
| Pods | api ×2 on two nodes + api-worker on `cdc254f0a78e`, Ready, 0 restarts, 0 errors |
| `[FLAGS]` api + worker | `LIVE_AUTO_PAUSE_MODE=off`; all other flags unchanged; no `[BOOT GUARD]` |
| `alembic current` (Adebayo) | `b3f6a9d2c814 (head)` |
| `usage_logs` after (Adebayo) | with_body / total **0 / 2** |
| Cleanup `UPDATE` (Adebayo, `write`) | `{"rowcount": 0, "committed": true}` (Job ran to completion although the terminal was interrupted) |
| A11 | worker 17:40:21 UTC: `ensure_retention_sweep: 1 job(s) scheduled`; first run done, next 2026-10-27 17:40 UTC |

## Operate / roll back

- **Rollback (whole train):** `scripts/db-oneoff.sh cdc254f0a78e alembic "downgrade e4b8d1a6c372"` (pointer only; the bodies stay purged),
  then gitops `images.yaml` back to `c232753c8746`. Never gitops-first: the old image's PreSync fails on the unknown revision.
- **A11 off:** `JOBS_DISABLED_KINDS=usage_logs.retention_sweep` or `USAGE_LOG_RETENTION_DAYS=0` in the api-worker ConfigMap (Reloader
  rolls). Deleted rows do not come back.
- **A5:** stays `off`. `enforce` is its own change (see Follow-ups).
- A `db-oneoff.sh` run interrupted with Ctrl-C keeps running in the cluster: read `kubectl -n weysure-prod logs job/<name>` for the result.

## Follow-ups

- [ ] Developers: A5 minimum amount on `same_payer` and `refund_ratio` and dedupe the shadow WARNING, **before** `LIVE_AUTO_PAUSE_MODE=enforce`; then `shadow` first
- [ ] Train 3 web (`release/2026-11-3-web`) — next release; then the API `?token=` query form on `verify-email` can be removed
- [ ] Release watcher: treat `Unable to connect` / expired SSO as its own state (it looked like a slow Argo phase for 15 min)
- [ ] Loki rules on Train 3's new log lines (auto-pause shadow, retention sweep)
