# SOP — Argo `root` stuck OutOfSync: pre-delete finalizer loop on child apps

**Shipped:** plateng-gitops #83, merged 2026-10-17 14:53:52 UTC (`752c917`); `bootstrap/root-app.yaml` applied by hand
(Adebayo) ~14:54 UTC · **Kind:** platform fix, GitOps config · **Cost delta:** $0

**Status: live and verified — root Synced, Argo 32/32.**

## What happened

From **2026-10-17 11:41:51 UTC** the app-of-apps `root` was permanently OutOfSync, in a loop:

| Step | Who | Evidence |
|---|---|---|
| A routine 3-min refresh re-rendered the kyverno chart (3.9.1 has PreDelete hook Jobs) and added `pre-delete-finalizer.argocd.argoproj.io` + `…/cleanup` to `Application/argocd/kyverno` | `argocd-application-controller` (Argo CD v3.5.2) | managedFields; controller log 11:41:51 `Update successful` + finalizer warning |
| `root` (prune + selfHeal) compared the child to `bootstrap/apps/kyverno.yaml` (only `resources-finalizer`) and stripped them | root auto-sync, every ~5 min | log `Tasks (dry-run) … Application:argocd/kyverno obj->obj`, 34 syncs 11:45–14:33 |
| The controller re-added them 1–2 min later | controller | watched live: stripped 14:43:41 / 14:48:41, re-added by 14:47:30 / 14:50:50 |

Kyverno itself was never at risk: no `deletionTimestamp`, spec equal to git, Healthy, 8 ClusterPolicies, 7 validating
webhooks. **The harm:** root OutOfSync for ever hides real drift in the other 31 children, and stripping the finalizer
defeats the PreDelete hooks it exists for. Why it started at 11:41 and not on 10-08 (when Argo 3.5.2 was installed) was
not established; the trigger was a routine re-render, not a change of ours.

## Fix

`bootstrap/root-app.yaml`:

```yaml
  ignoreDifferences:
    - group: argoproj.io
      kind: Application
      jqPathExpressions:
        - '.metadata.finalizers[]? | select(startswith("pre-delete-finalizer.argocd.argoproj.io"))'
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true   # a root sync keeps the live value instead of stripping it
```

Only those entries are ignored; `resources-finalizer` and every other field of every child Application are still compared.
It covers any future child whose chart gains PreDelete hooks.

| Rejected | Why |
|---|---|
| Add the finalizers to `kyverno.yaml` in git | They are Argo's to add and remove; pinned in git they could block a future deletion |
| Hand-patch the finalizers / the Application | root would fight it, and so would the controller |
| Turn off root `selfHeal` | Loses drift repair for all 32 apps |

## Verification

| Check | Before | After |
|---|---|---|
| Expression test (real kyverno object, saved with the extras) | — | `del(expr)` leaves exactly `["resources-finalizer.argocd.argoproj.io"]`; safe on an app with no finalizers |
| `kubectl apply --dry-run=server -f bootstrap/root-app.yaml` | — | `configured (server dry run)` |
| Root sync operations | every 5 min (14:43:41, 14:48:41) | none after 14:53:41 (watched 14:55–15:04: the 14:58:41 and 15:03:41 strips did not happen) |
| kyverno pre-delete finalizers | stripped and re-added | re-added ~14:56:58 and **kept** |
| root | Synced/OutOfSync flapping | Synced throughout; `sync.revision` = `752c917` |
| Argo | 31/32 Synced | **32/32 Synced** |

## Operate / roll back

- `root-app.yaml` is **the one file applied by hand** (root does not manage itself: it watches `bootstrap/apps/`). Any
  change to it is merge **plus** `kubectl apply -f bootstrap/root-app.yaml` from an up-to-date `main`. Applying it rolls
  nothing; only root's diff rules change.
- Rollback: revert #83, pull, re-apply the file. The loop returns (cosmetic).
- Diagnosing a stuck OutOfSync on root: `kubectl -n argocd get applications -o json | jq '.items[].status.resources[]?
  | select(.status!="Synced")'` names the child; compare its spec **and metadata** with git (Python `yaml`, no `yq` here),
  then `--show-managed-fields` to see who wrote the difference.

## Follow-ups

- None required. If another tool ever writes finalizers to child Applications, extend the same `ignoreDifferences` rule
  rather than hand-patching.
