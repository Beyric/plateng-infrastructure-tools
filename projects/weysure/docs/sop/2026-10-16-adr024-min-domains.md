# SOP — ADR-024 repaired: `minDomains: 2` keeps api/web replicas on two nodes

**Shipped:** gitops #82 merged 2026-10-16 10:52 UTC (`4db95e2`) → api and web rolled 10:56–10:58 UTC, same images ·
**Kind:** chart + prod values change, no app change · **Cost delta:** one more spot workload node (estimated ~$25–30/month) ·
Amends [ADR-024](../../memory/DECISIONS.md) · Earlier SOP: [2026-10-13-api-web-hard-spread](2026-10-13-api-web-hard-spread.md)

**Status: live and verified.**

## Why

Found 2026-10-16 ~10:45 UTC: `api` ×2 **and** `web` ×2 all on one spot node (`ip-10-0-4-19`), the exact state ADR-024
was written to prevent.

| UTC | Event |
|---|---|
| 09:51 | Karpenter consolidated `ip-10-0-3-17` (`Underutilized`); its pods moved to `ip-10-0-4-38` |
| 10:30:05 | **AWS spot interruption** of `ip-10-0-4-38` (Karpenter log: `initiating delete from interruption message`). One api, one web, api-scheduler, api-worker and a Jenkins build agent evicted. **0 × 5xx** for api/web 10:28–10:36 (Traefik): the spread worked, the other replica of each served |
| 10:32 | Jenkins main build #59 (Weysure-API #77, docs only) aborted with its agent: nothing promoted |
| 10:30 → | every replacement scheduled onto `ip-10-0-4-19`, the only workload node left |

**Root cause.** The hostname spread counts only nodes the pod may run on (`nodeSelector: node-role=workload`;
`nodeAffinityPolicy` defaults to `Honor`). With one eligible node the skew is always 0, so `DoNotSchedule` allows every
replica on it, and Karpenter's consolidation, simulating the same rule, may pack down to one node. ADR-024 worked on
10-13 only because a second workload node happened to exist. The 10-13 SOP's claim "consolidation will not pack below
that" was wrong (corrected there).

## How

- `minDomains: 2` on the `DoNotSchedule` spread for `api` and `web`. With fewer than 2 eligible nodes, the global minimum
  counts as 0: the second replica stays Pending and Karpenter launches a node.
- Karpenter v1.14.1 implements the same rule (`pkg/controllers/provisioning/scheduling/topologygroup.go:317`, read at the
  `v1.14.1` tag; the docs page is silent on `minDomains`), and consolidation simulates it, so it cannot collapse to one.
- Chart guard: `minDomains` renders only with `whenUnsatisfiable: DoNotSchedule` and fails the render otherwise (the API
  server rejects the combination at sync time).
- Rejected: letting api/web use the system nodes (keeps the system/workload split we chose); a zone spread (workload
  nodes and RDS share us-east-1b).

## What's involved

| File (plateng-gitops) | Change |
|---|---|
| `charts/beyric-app/templates/deployment.yaml` | `$ts.minDomains` rendered under the spread; `fail` unless `DoNotSchedule` |
| `charts/beyric-app/values.yaml` | documented option |
| `projects/weysure/environments/prod/apps/{api,web}/values.yaml` | `topologySpread: { whenUnsatisfiable: DoNotSchedule, minDomains: 2 }` |
| `charts/beyric-app/tests/render-test.sh` | asserts api/web `minDomains: 2`, scheduler/worker none |

## Verification

| Check | Result |
|---|---|
| Pre-merge | render-test OK; guard test fails as intended; rendered diff vs `main` = one line in Deployments `api` and `web` only; `kubectl diff` (server dry-run, incl. Kyverno) accepted |
| Rollout | Argo `weysure-api`/`weysure-web` Synced on `4db95e2`, Healthy; new node `ip-10-0-4-50` launched for the Pending replica |
| Placement | api on `ip-10-0-4-240` + `ip-10-0-4-50`; web on `ip-10-0-4-19` + `ip-10-0-4-240` |
| Unchanged | images api `38b579b34f51`, web `a0d4e7b4adfe`; api-scheduler, api-worker not restarted |
| Sites | `api.weysure.com/api/v1/health` 200, `weysure.com` 200 |

Argo showed `Degraded` for ~1 min during the roll: surge pods refused by the namespace quota (`exceeded quota …
limits.cpu`), a `ReplicaFailure` condition. Serving capacity never dropped below 2 (`maxUnavailable: 0`). Known item
(quota `limits.cpu=8`, deferred table).

## Operate / roll back

- Expect **≥ 2 workload nodes at all times**; a Jenkins build may add a third for a while, then Karpenter consolidates to 2.
- A Pending api/web pod right after a node loss is the rule working: Karpenter adds a node in ~1–2 min while the other
  replica serves.
- Roll back: revert gitops #82 (api and web restart; replicas may share a node again).

## Follow-ups

- Confirm the steady state settles to 2 workload nodes after the Jenkins build node goes.
- Quota `limits.cpu=8` now also shows as Argo `Degraded` during every api/web roll: right-size (handoff §6 item 7).
