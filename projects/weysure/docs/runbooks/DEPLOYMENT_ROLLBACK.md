# Runbook — roll back a Weysure deployment

**When:** a promote commit produced a bad release (errors, failed probes, wrong behaviour).

**First question: did the release add a migration?** (`git diff --name-only <old>..<new> -- app/alembic/versions`
in Weysure-API.) If **no**, use *Image only*. If **yes**, use *Release with a migration*: an image-only
revert will fail.

## Image only (no new migration)

1. Find the promote commit and the previous tag:
   ```bash
   git -C ~/Documents/beyric/projects/plateng-infra/plateng-gitops log --oneline -5 -- projects/weysure/environments/prod/images.yaml
   ```
2. Revert it on a branch and open a PR (main is protected):
   ```bash
   cd ~/Documents/beyric/projects/plateng-infra/plateng-gitops && git checkout -b rollback/<app>-<sha> main && git revert --no-edit <promote-commit> && git push -u origin HEAD && gh pr create --fill
   ```
3. Merge. Argo syncs within 3 min: the PreSync Job runs `alembic upgrade head` (a no-op: the schema
   did not move), then rolls the previous image with `maxUnavailable 0`.
4. Watch: `kubectl get app weysure-<app> -n argocd` → Synced/Healthy; `kubectl -n weysure-prod get pods`.

## Release with a migration

The PreSync Job runs the **old** image's `alembic upgrade head`. The database is at a revision that
image does not have, so the hook fails and the sync stops — **even for an expand-only migration**.
Proven 2026-10-05: `FAILED: Can't locate revision identified by 'c3e8a1f4b7d2'`.

Order:
1. **Stop anything that would act on new data**, in git: the api-worker with `replicas: 0`
   (`projects/weysure/environments/prod/apps/api/values.yaml`). Not `kubectl scale`: `selfHeal` is off,
   but the image revert in step 4 is a sync, and a sync re-applies git — it would bring the worker back.
2. Any data clean-up the developers' rollback note asks for: `scripts/db-oneoff.sh <new-tag> write "..."`.
3. **Downgrade the schema with the NEW image** (the one that contains the revision being removed):
   `scripts/db-oneoff.sh <new-tag> alembic "downgrade <previous-revision>"`. Between this step and
   step 4 the new API may error on the removed tables: use a quiet window.
4. Revert the promote commit (*Image only*, steps 1–3). PreSync is now a no-op.
5. Repeat any clean-up the note asks for, then `replicas: 1` for api-worker in git.

Follow the developers' release note for *what* to clean up; this runbook is *how*. If a downgrade is not
safe (data written to new columns that must survive), stop and write a forward fix instead.

## One-off database commands: `scripts/db-oneoff.sh`

Runs one SQL statement or one alembic command as a Job with the migration's identity (ServiceAccount
`db-migrate`, Vault role `weysure-migrate`, NetworkPolicy label `db-migrate`), rendered from the chart's
migration Job. Asks before running; `write` and alembic `downgrade|upgrade|stamp` need the mode word typed.

```bash
scripts/db-oneoff.sh <image-tag> read "SELECT kind, status, count(*) FROM jobs GROUP BY 1, 2"
```

```bash
scripts/db-oneoff.sh <image-tag> alembic "current"
```

| Mode | Behaviour |
|---|---|
| `read` | `SET TRANSACTION READ ONLY`: any write is refused by Postgres. 60 s statement timeout. Up to 200 rows as JSON |
| `write` | one transaction, committed only if the statement succeeds; prints `rowcount` |
| `alembic` | `alembic <args>` from the image you name |
| `DRY=1` / `PRINT=1` | validate with the API server and Kyverno, creating nothing / print the Job only |

Results can hold personal data: they stay in your terminal, never in a ticket or chat. The Job is kept
1 h for its logs (`ttlSecondsAfterFinished`), then deleted.

**Whole-app removal:** revert the commit that added `bootstrap/apps/weysure-<app>.yaml`; the
Application finalizer deletes everything it owns. Namespace, Redis and Vault config stay.
