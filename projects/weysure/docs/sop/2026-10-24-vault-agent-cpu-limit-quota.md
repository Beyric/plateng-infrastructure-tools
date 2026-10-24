# SOP — Vault Agent CPU limit + `weysure-prod` `limits.cpu` 10 (rollout surge stalls)

**Shipped:** plateng-gitops [#88](https://github.com/Beyric/plateng-gitops/pull/88), merged 2026-10-24 12:56 UTC (`4e02d51`) ·
**Kind:** chart + namespace quota · **Cost delta:** none (limits do not size nodes; requests unchanged)

**Status: live and verified 2026-10-24 12:58 UTC.**

## Why

Rollouts in `weysure-prod` kept waiting on `FailedCreate … exceeded quota … limits.cpu` (checklist deferred item since 2026-10-10).
On 2026-10-24 api-scheduler sat on the old image for ≈ 4 min after the #121 deploy. Every Deployment rolls with `maxSurge: 1,
maxUnavailable: 0`, so each roll needs one extra pod's limits. The namespace had 6.5 of 8 CPU of limits in use, leaving 1.5.

**Root cause:** the chart set the Vault Agent sidecar's CPU *request* (20m) and memory limit, but no CPU limit. When
`vault.hashicorp.com/agent-limits-cpu` is missing, the injector applies its own default of **500m**. Four sidecars (api ×2,
api-scheduler, api-worker) held **2 CPU** of the quota while using ≈ 1m each (`kubectl top`). A second effect: the api HPA (max 4) could
never reach 4 pods, because that needs 9.5 of 8.

## How

| Decision | Why | Rejected |
|---|---|---|
| Sidecar CPU limit **100m**, emitted only when set (`{{- with }}`) | 100× its use; caps only a renewal burst. The quota forces every container to have a CPU limit, so "no limit" was never possible | `maxSurge: 0` (downtime on single-replica pods) |
| Quota `limits.cpu` **8 → 10**, `requests.cpu` stays 4 | worst case = HPA at 4 + api, scheduler and worker surging together = **9.4** | quota alone at 12 (hides 2 CPU of wasted limits) |

## What changed

| File | Change |
|---|---|
| `charts/beyric-app/values.yaml` | `vaultAgent.resources.limits.cpu: 100m` (+ comment) |
| `charts/beyric-app/templates/_helpers.tpl` | `vault.hashicorp.com/agent-limits-cpu` annotation when the value is set |
| `charts/beyric-app/tests/render-test.sh` | asserts every sidecar Deployment (3) sets the CPU limit |
| `projects/weysure/environments/prod/quota.yaml` | `limits.cpu: "10"` (+ comment) |

The rendered diff against `main` was exactly 4 annotation lines (api, api-scheduler and api-worker Deployments, migration Job init agent);
the web render was unchanged.

## Verification

| Check | Result |
|---|---|
| Local | render test OK, pre-commit pass |
| Argo | `weysure-api` and `weysure-prod` on `4e02d51`, Synced/Healthy (`Degraded` for a few seconds from `ReplicaFailure`, then cleared) |
| Roll | api ×2, scheduler, worker restarted once on the **same image** `02cb3440e319`, all Ready by 12:57:54 (≈ 90 s; the 10-24 #121 roll took ≈ 6 min) |
| Pods | sidecar limits `100m` on all four |
| Quota | used `limits.cpu` **4900m / 10** (was 6500m / 8); requests 1030m / 4 |
| `FailedCreate` | 10 events at 12:56:50–53, all against the **old** `limited: limits.cpu=8`: the chart (app `weysure-api`) synced 4 s before the quota (app `weysure-prod`). **None** after the quota went to 10 at 12:56:54 |
| Sites | `weysure.com` 200, `api.weysure.com/api/v1/health` 200 |

## Operate / roll back

- Two Argo apps, no ordering between them: a quota change and a chart change in one PR can land seconds apart. Fine here (the new pods
  are smaller); if a quota change must come first, merge it in its own PR.
- Roll back: revert #88 (one more restart of api, scheduler and worker on the same image). No data or secret changes.
- Headroom check before raising replicas: `kubectl -n weysure-prod get resourcequota weysure-prod -o jsonpath='{.status.used.limits\.cpu}/{.status.hard.limits\.cpu}'`
  must leave one pod's limits (api 1.1) free for the surge.

## Follow-ups

- api-scheduler is a singleton with `maxSurge: 1`: two schedulers run side by side for a few seconds on every roll. Developers to confirm
  whether its jobs hold a lock (asked before Train 1b).
- The bootstrap one-off Job `uploads-remediate-dryrun-v1-job.yaml` writes its own agent annotations (no CPU limit → injector 500m while it runs).
