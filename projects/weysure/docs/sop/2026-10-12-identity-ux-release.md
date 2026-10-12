# SOP — Identity UX release (Weysure-API #62, no migration)

**Shipped:** 2026-10-12 14:37 UTC · **PR:** Weysure-API #62 (merge `e120fd3`, image `e120fd364ce7`) · **Cost delta:** $0 ·
Related: developers' note `weysure/docs/platform-note-2026-10-11-identity-ux.md`, our reply
`platform-reply-2026-10-12-identity-ux.md`, previous release [admin follow-ups](2026-10-12-admin-followups-release.md)

**Status: shipped and verified in production.** Alembic head unchanged (`c9a4e1b7d230`); 0 errors. Merged in the agreed
order (after #63 verified); web #47 follows.

## What shipped (developers)

| Piece | Where |
|---|---|
| In-app notice + email when an identity check passes, goes to review or fails (notice in the status-change transaction; email after commit, best effort, at most once) | `app/services/identity_notices.py`, template `app/email-templates/identity_result_email.html` |
| Superadmin "release identity" for test accounts (`POST /admin/kyc/users/{id}/identity/release`, audited `kyc_identity_released`), **fail-closed** outside dev/test/local unless `IDENTITY_RELEASE_ENABLED=true` | `app/services/identity_release.py` |
| New log lines: `[KYC] identity <state> email failed: <ExcType>` (error), `… email was not sent` (warning), `[KYC] identity released user=… admin=… attempts=…` (info) | same files |

## How (platform decisions)

| Point | Decision |
|---|---|
| `IDENTITY_RELEASE_ENABLED` | **Not set in prod** (Adebayo, 2026-10-12). The endpoint answers `403 IDENTITY_RELEASE_DISABLED` on prelaunch; testers use fresh accounts. The auto-mode classifier also stopped the gitops edit as a feature-flag write: it deletes BVN/NIN lock rows in prod |
| `EMAILS_FROM_EMAIL = support@weysure.com` | **Decoupled** from this release: #62 sends from the existing sender. The value lives in Vault (Secret beats ConfigMap in the chart's `envFrom` order, so a git value would be silently ignored). Switch = separate change, see the Resend reply `platform-reply-2026-10-12-resend-email.md` |
| Rebase before merge | developers rebased onto #63 (checklist conflict); `git range-diff c3babc4 → 9a36af2`: 4 of 5 commits identical, the 5th differs only in their checklist doc. No code change |
| Rollback | image revert is valid (no migration, DB head is the one the previous image `fd482c787ca5` knows) |

## Verification (2026-10-12)

| Check | Result |
|---|---|
| Merge → promote | merged 14:13:08 UTC → `78c9342 promote e120fd364ce7` 14:31:09 (~18 min) |
| PreSync migration Job | succeeded, no `Running upgrade` line (no-op, as expected) |
| Pods | api ×2, api-scheduler, api-worker on the tag by 14:37:39, 0 restarts (worker drains its job before exit, so it rolls last) |
| Errors since 14:30 incl. `email failed` / `was not sent` | none (gunicorn INFO socket-close lines only: shutdowns and worker recycling) |
| Argo / sites | 32/32 Synced/Healthy; web and `/api/v1/health` 200 |
| Live identity email | not exercised in prod (no identity check ran in the window); will show in Loki on the first one |

## Operate / roll back

- Roll back: revert promote commit `78c9342` in gitops (back to `fd482c787ca5`). Notices and audit rows written by the
  new code stay readable by the old code (developers' note).
- Email failures: Loki `{namespace="weysure-prod",container=~"api|api-worker"} |= "[KYC] identity" |= "email"`.

## Follow-ups

- Web #47 (identity dialog reminder + notices in the bell) next; then the Resend switch (one atomic `vault kv patch`).
- Developers: stop logging the recipient address in `Failed to send email to …` (`app/services/email.py:88`).
