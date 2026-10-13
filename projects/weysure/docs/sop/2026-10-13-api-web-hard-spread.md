# SOP — api and web replicas never share a node

**Shipped:** 2026-10-13 08:37 UTC (gitops [#70](https://github.com/Beyric/plateng-gitops/pull/70), merge `47275d8`) ·
**Kind:** Helm chart + prod values; rolling restart of every Weysure pod, same images · **Cost delta:** $0 today
(two spot workload nodes already existed); at most one extra small spot node if the second node lacks room ·
**Decision:** ADR-024 (amends ADR-023)

**Status: live and verified.**

## What shipped

| | Before | After |
|---|---|---|
| Hostname spread, `api` and `web` | `ScheduleAnyway` (a scoring hint) | **`DoNotSchedule`** (hard rule) |
| Hostname spread, `api-scheduler`, `api-worker` (1 replica) | `ScheduleAnyway` | unchanged |
| All components | — | `nodeTaintsPolicy: Honor`, `matchLabelKeys: [pod-template-hash]` |
| Placement at 00:15 UTC → 08:40 UTC | all 6 app pods on `ip-10-0-4-16` | api: `ip-10-0-4-52` + `ip-10-0-4-33`; web: `ip-10-0-4-52` + `ip-10-0-4-33` |

## Why

On 2026-10-12 (after the 12:43 spot interruption, everything on `ip-10-0-3-32`) and again on 2026-10-13 00:15 UTC (everything
on `ip-10-0-4-16`) every api and web replica sat on one spot node. One spot interruption (2-minute notice) or node failure =
both sites down until Karpenter brings a node and the pods start. The PDB (`minAvailable: 1`) cannot help: both replicas are
on the node that disappears.

**Root cause:** `whenUnsatisfiable: ScheduleAnyway` is one score among many for kube-scheduler (image locality, resource
fit can outweigh it), and Karpenter ignores soft constraints when it consolidates, so it is free to pack replicas together.

## How (key decisions)

- **Hard rule only where there are replicas.** Single-replica scheduler and worker gain nothing from a hard rule.
- **Per-component setting** `topologySpread.whenUnsatisfiable` in `charts/beyric-app` (default stays `ScheduleAnyway`), so
  other apps using the chart are unaffected.
- **`matchLabelKeys: [pod-template-hash]`**: during a rollout the new ReplicaSet's pods spread among themselves instead of
  being balanced against old pods that are about to go.
- **`nodeTaintsPolicy: Honor`**: a node the pod cannot tolerate is not counted as an empty domain it must fill.
- **No zone spread:** all workload nodes and RDS are in us-east-1b; a zone outage stops the app anyway.
- When no second node has room, Karpenter provisions one (hard constraints drive provisioning). If spot capacity is short,
  the second replica stays Pending and the old pod keeps serving (`maxUnavailable: 0`).

## Files

- `plateng-gitops/charts/beyric-app/templates/deployment.yaml` — the spread block
- `plateng-gitops/charts/beyric-app/values.yaml` — documented `topologySpread` key
- `plateng-gitops/projects/weysure/environments/prod/apps/{api,web}/values.yaml` — `DoNotSchedule`
- `plateng-gitops/charts/beyric-app/tests/render-test.sh` — asserts the rule on all four Deployments

## Verification

- Pre-merge: render test OK; mutation (web back to `ScheduleAnyway`) makes it fail; pre-commit pass.
- Post-merge (08:37–08:42 UTC): Argo `weysure-api` / `weysure-web` on `47275d8`; all 4 rollouts complete; placement as in the
  table; 0 Pending, 0 restarts; images unchanged (`e120fd364ce7`, `0456c8424250`); 32/32 Synced/Healthy; sites 200.
  Loki: only gunicorn shutdown lines from the old pods (`Worker … was sent SIGTERM`), no application errors.
- The empty node `ip-10-0-4-16` was consolidated away by Karpenter; 3 spot nodes remain (`-52`, `-33`, `-50` with redis).
- The rollout hit `exceeded quota … limits.cpu=8` again (4th time) and completed one-out-one-in. See follow-ups.

## Roll back

Revert gitops #70 (another rolling restart of all Weysure pods).

## Follow-ups

- Namespace quota `limits.cpu=8` throttles every rollout (seen 4 times). Raise it or right-size limits before the next release window.
- Interview/ops note: a hard spread rule is a standing claim on two nodes; consolidation will not pack below that.
