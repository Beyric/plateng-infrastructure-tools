# SOP — Priority classes for node agents and zonal-volume pods

**Shipped:** 2026-10-09 17:41 UTC · **PR:** gitops #65 (`3e703c8`) · **Cost delta:** $0 ·
Related: [2026-10-08-database-recovery](2026-10-08-database-recovery.md) (the wake that exposed it), [SLEEP_WAKE](../runbooks/SLEEP_WAKE.md)

**Status: shipped and verified in production.** All 32 Argo apps Synced/Healthy at 17:48 UTC; every target pod
carries its class; nothing Pending; only `Watchdog`/`InfoInhibitor` firing.

## What shipped

| Object | Priority | Where |
|---|---|---|
| DaemonSets `alloy`, `prometheus-node-exporter` | `system-node-critical` (built-in, 2000001000) | gitops `bootstrap/apps/alloy.yaml`, `kube-prometheus-stack.yaml` |
| Prometheus, Alertmanager, StatefulSets `jenkins`, `loki` | **`platform-stateful`** (new, 100000, `preemptionPolicy: Never`) | gitops `bootstrap/apps/{kube-prometheus-stack,jenkins,loki}.yaml` |
| PriorityClass `platform-stateful` | — | gitops `platform/storage/priorityclass-platform-stateful.yaml` (app `storage`, sync wave 0) |
| Vault | `system-cluster-critical` (unchanged, gitops #54) | — |
| Everything else | 0 (default) | — |

## Why

At the 2026-10-08 wake, `alloy` and `node-exporter` stayed **Pending** on system node `ip-10-0-3-48` (1915m of 1930m CPU
requested). Ordinary pods took the space first and DaemonSets had no priority, so that node had no logs and no node
metrics until a pod was moved by hand.

## How (key decisions)

- **Agents get `system-node-critical`.** The scheduler then *preempts* (evicts) lower-priority pods to fit them.
- **The catch:** the eviction candidates on `3-48` included Prometheus, Alertmanager and Jenkins, whose EBS volumes are in
  us-east-1a, and `3-48` is the **only** 1a system node (Loki: same, in 1b). Evicted, they could not move: Prometheus
  Pending = no alerting.
- **So a middle class, `platform-stateful`.** Preemption picks victims from the lowest priority up, so stateless pods
  (priority 0, can run anywhere) are evicted first; the agents need ~60m, which a stateless pod always frees.
- **`preemptionPolicy: Never`**: these pods are protected but never evict anyone themselves.
- **Class in `platform/storage` at wave 0**: a pod naming a missing class is rejected, so it must exist before monitoring
  (6), Loki (6), Jenkins (7), alloy (7).
- *Rejected:* raising every platform pod to a high class (protects nothing if all are equal); a PDB (does not stop preemption).
- *Not covered:* Karpenter **consolidation** ignores priority. See "Follow-ups" (SonarQube).

## Verification (2026-10-09, after merge)

| Check | Result |
|---|---|
| `kubectl get priorityclass platform-stateful` | present 17:43:55 UTC (2 min after merge) |
| Pod `priorityClassName` | alloy ×4, node-exporter ×4 `system-node-critical`; prometheus-kps-prometheus-0, alertmanager-kps-alertmanager-0, jenkins-0, loki-0 `platform-stateful` |
| Restarts | each restarted once, 0 restarts since; nothing Pending cluster-wide |
| Argo | `kube-prometheus-stack` sync failed twice (`Prometheus … containers with incomplete status: [init-config-reloader]`, i.e. Argo's health check caught Prometheus mid-restart), succeeded on retry #3 at 17:48:26 UTC. No action needed |
| Alerts | only `Watchdog`, `InfoInhibitor` |
| Pre-merge | before/after renders of the four charts differ only in the six `priorityClassName` lines; server dry-run accepted the class |

Merged with Jenkins idle (only `jenkins-0`), so no build was interrupted.

## Operate / roll back

- **Expect** a brief Argo "retrying" on `kube-prometheus-stack` whenever Prometheus restarts; it clears itself.
- **Roll back:** revert gitops #65; pods restart once more without priority. Delete the class only after no pod references it.
- Any new pod with a zonal volume on a system node should get `platform-stateful`.

## Follow-ups

- **SonarQube** (parked 2026-10-09): not in this class, and priority would not help anyway. Karpenter evicted it 3× on
  10-09 (spot interruption 16:02, consolidation 16:39/16:40); one build (Weysure PR-38 #1) failed for it. Option when
  resumed: `karpenter.sh/do-not-disrupt` on the pod.
- Next wake: confirm the DaemonSets schedule on full system nodes without manual help (the original failure).
