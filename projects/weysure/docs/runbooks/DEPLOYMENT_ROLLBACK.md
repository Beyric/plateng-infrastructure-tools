# Runbook — roll back a Weysure deployment

**When:** a promote commit produced a bad release (errors, failed probes, wrong behaviour).

1. Find the promote commit and the previous tag:
   ```bash
   git -C ~/Documents/beyric/projects/plateng-infra/plateng-gitops log --oneline -5 -- projects/weysure/environments/prod/images.yaml
   ```
2. Revert it on a branch and open a PR (main is protected):
   ```bash
   cd ~/Documents/beyric/projects/plateng-infra/plateng-gitops && git checkout -b rollback/<app>-<sha> main && git revert --no-edit <promote-commit> && git push -u origin HEAD && gh pr create --fill
   ```
3. Merge. Argo syncs within 3 min: the PreSync Job runs `alembic upgrade head` (no-op unless the
   schema moved), then rolls the previous image with `maxUnavailable 0`.
4. Watch: `kubectl get app weysure-<app> -n argocd` → Synced/Healthy; `kubectl -n weysure-prod get pods`.

**Schema caveat:** a release whose migration dropped or renamed columns cannot be rolled back by
image alone — that is why migrations must be expand/contract. If it happened, the migrate user
can run a corrective revision: `kubectl -n weysure-prod create job --from=job/weysure-api-db-migrate fix-<n>`
is *not* available (hooks are deleted); write a forward migration instead.

**Whole-app removal:** revert the commit that added `bootstrap/apps/weysure-<app>.yaml`; the
Application finalizer deletes everything it owns. Namespace, Redis and Vault config stay.
