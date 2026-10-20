# SOP — SonarQube and its DB protected from Karpenter consolidation (`do-not-disrupt`)

**Shipped:** plateng-gitops [#85](https://github.com/Beyric/plateng-gitops/pull/85), merged 2026-10-20 17:05:02 UTC (`2609e16`); stuck-drain alert [#86](https://github.com/Beyric/plateng-gitops/pull/86) (open)
· **Kind:** platform fix, GitOps config · **Cost delta:** ≤ ~one small spot node kept (≈ $0–25/mo, usually $0)

**Status: live and verified (17:08 UTC): both pods `do-not-disrupt=true`, Ready on `ip-10-0-4-35`; Karpenter logged `DisruptionBlocked … Pod=sonarqube/sonar-postgres-0`.**

## What happened

| When (UTC) | Evidence |
|---|---|
| 2026-10-09 | SonarQube moved by Karpenter 3 times; Weysure PR-38 #1 failed. The fix was parked (handoff §5 item 6) |
| 2026-10-20 16:40:45 | Karpenter event `Disrupting Node: Underutilized` on `ip-10-0-4-49` (nodeclaim `default-2zlfd`) → `sonarqube-sonarqube-0` recreated on `ip-10-0-4-35` while Weysure-API **PR-107 #1** was scanning → scanner `java.net.ConnectException: Connection refused` |
| same | `FailedAttachVolume` "waiting on detach": the 10 Gi EBS volume follows the pod. SonarQube needs ~1–2 min of startup before it answers (startup probe refused, then timed out) |

**Root cause.** NodePool `default` runs `consolidationPolicy: WhenEmptyOrUnderutilized`, `consolidateAfter: 1m`, budget
`10%`. SonarQube (`nodeSelector: node-role: workload`) and `sonar-postgres` sit on Karpenter spot nodes with no
protection. Jenkins agent pods already carry `karpenter.sh/do-not-disrupt`, so the *build* node is never consolidated,
but the *Sonar* node is. When a build finishes and its agent leaves, the Sonar node looks underutilised, and Karpenter
repacks SonarQube elsewhere, sometimes while another build's scan is talking to it.

## Fix

| File (plateng-gitops) | Change |
|---|---|
| `bootstrap/apps/sonarqube.yaml` | Helm value `annotations: { karpenter.sh/do-not-disrupt: "true" }`. In chart `sonarqube` 2026.4.1 the top-level `annotations` value is rendered onto the **pod template** (`templates/_pod.tpl:17`), not the StatefulSet |
| `platform/sonarqube/postgres.yaml` | the same annotation on the `sonar-postgres` pod template |

This is the pattern `redis-0` has used since Phase 8 (gitops #28/#33). It goes through the chart values, not `kubectl patch`:
`selfHeal` is off, so a hand patch would survive until the next sync and then silently disappear.

### What the annotation does and does not stop (Karpenter 1.14.1, [docs](https://karpenter.sh/docs/concepts/disruption/))

| Disruption | Blocked? |
|---|---|
| Consolidation (Empty / Underutilized) | **Yes**: nodes with an active annotated pod are excluded |
| Drift | **Yes**, while the NodePool has no `terminationGracePeriod` (ours has none) |
| Spot interruption (2-min notice) | **No**: this is forced |
| `expireAfter: 720h` | **No**: this is forced. The node is drained, but an annotated pod is not evicted, so without `terminationGracePeriod` the drain can hang (see Follow-ups) |
| Node auto repair, manual `kubectl delete node` | **No** |

### Alternatives considered

| Option | Verdict |
|---|---|
| **`nodeSelector` → system nodes** (on-demand, never consolidated) | **Rejected.** The system nodes are arm64 `m7g.large`, at 99% (1a) and 70% (1b) CPU requests, and SonarQube asks 500m / 2 Gi. Terraform gives the system node group no `vm.max_map_count=262144`, which SonarQube's embedded Elasticsearch needs (only the Karpenter EC2NodeClass userData sets it, ADR-013). The EBS PVCs are zonal (1b), so only one system node could take them |
| PodDisruptionBudget `minAvailable: 1` | Rejected: on a one-replica pod it blocks **every** drain, including the ones we want (Finding 37, as for Redis) |
| Separate on-demand NodePool for CI | Most robust (no spot moves either), but costs a dedicated node. Revisit if spot interruptions still fail builds |
| `consolidationPolicy: WhenEmpty` cluster-wide | Rejected: it gives up repacking for every workload to protect one |

### Cost

Karpenter will not consolidate the node(s) hosting SonarQube / sonar-postgres. Other pods can still be scheduled onto
those nodes, so the cost is only the capacity consolidation would otherwise have reclaimed: at worst one small spot
node, and often nothing, because the two api/web nodes (ADR-024 hard spread) exist anyway.

## Verification

**Done (pre-merge, 2026-10-20):**
- `helm template` of chart 2026.4.1 with the exact `valuesObject` from the branch → `StatefulSet/sonarqube-sonarqube`
  pod template has `karpenter.sh/do-not-disrupt: "true"`, `nodeSelector` unchanged.
- `kubectl apply --dry-run=server -f platform/sonarqube/postgres.yaml` → `statefulset.apps/sonar-postgres configured (server dry run)`.
- `pre-commit run` on both files: all hooks passed. `charts/beyric-app/tests/render-test.sh`: OK.

**After merge (Adebayo / next session):** Argo polls about every 3 min; only judge the result once `sync.revision` equals the merge commit.

```bash
kubectl -n argocd get app sonarqube sonarqube-postgres -o custom-columns=APP:.metadata.name,REV:.status.sync.revision,SYNC:.status.sync.status,HEALTH:.status.health.status
```

```bash
kubectl -n sonarqube get pods -o custom-columns=POD:.metadata.name,DND:'.metadata.annotations.karpenter\.sh/do-not-disrupt',NODE:.spec.nodeName,AGE:.metadata.creationTimestamp
```

```bash
kubectl get events -A --field-selector involvedObject.kind=Node --sort-by=.lastTimestamp | command grep -i sonarqube
```

Expected: `sonarqube` is Synced/Healthy at the merge commit (its sync revision is the chart version 2026.4.1, so judge it
by pod age), both pods show `DND=true`, and within a day a `DisruptionBlocked … Pod=sonarqube/…` event appears on the Sonar node.

## Decision: no `terminationGracePeriod` (Adebayo, 2026-10-20, option A)

With `expireAfter: 720h` and no `terminationGracePeriod`, a node that expires while it holds a do-not-disrupt pod is
tainted `karpenter.sh/disrupted` and **never finishes draining by itself**. The pods keep running and the node takes no
new pods. Setting a grace period looks like the fix, but it is not:

| Fact (read-only, 2026-10-20) | Consequence of a grace period |
|---|---|
| EC2NodeClass `amiSelectorTerms: alias: al2023@latest` | every EKS AMI release (every week or two) marks every workload node as drifted |
| Karpenter docs: with a `terminationGracePeriod`, drift may disrupt a node "even if there are pods with blocking PDBs" / do-not-disrupt | Sonar, sonar-postgres and redis get force-deleted when the grace period ends. They never exit on their own, so the grace period only delays the kill, at a time Karpenter picks |
| Docs: "changing this value in the nodepool will drift the nodeclaims" | merging it marks all 4 workload nodes as drifted at once, and existing NodeClaims keep `<none>`, so it does not even cover today's nodes |

| Option | Verdict |
|---|---|
| **A. No grace period; alert + manual drain** | **Chosen.** We pick when Sonar restarts. The cost is one manual step per node per 30 days |
| B. Grace period of about 2 h now | Rejected: brings back random Sonar kills (on AMI releases) and replaces all workload nodes at merge |
| C. Pin the AMI alias to a version, then add a grace period | The right long-term setup (drift only when we bump the version), but AMI updates become our job. In backlog |

**Alert** (gitops #86): `KarpenterNodeStuckDraining`, `max by (node) (kube_node_spec_taint{key="karpenter.sh/disrupted"}) == 1`
for 1h, warning. Threshold measured in the live Prometheus: 44 drained nodes in 7 days held the taint for at most
19 samples (about 20 min or less). Test: `bash platform/monitoring/tests/prometheus-rules-test.sh` (promtool v3.14.0;
no alert at 50 min, alert at 75 min; decoys are a 20-min drain and another taint key; a mutant `for: 30m` fails it).
Response steps: runbook `ALERTS.md#karpenternodestuckdraining`.

**First expected:** `ip-10-0-4-18` (redis-0), created 2026-10-16 12:10 UTC, expires **2026-11-15 ~12:10 UTC**.

## Operate / roll back

- **Merge timing:** the pod template changes, so on sync **both pods restart once** (SonarQube is down for about 2 min, and
  sonar-postgres restarts in seconds). A restart kills any running scan. **Merge only when no PR or main build is in its
  Sonar / Quality gate stage.**
- **Roll back:** revert #85. Argo removes the annotation, and the pods restart once more.
- **Deliberately moving Sonar** (node maintenance): `kubectl drain` still evicts it, because do-not-disrupt only governs
  Karpenter. Do it when no scan is running.

## Follow-ups

- Option C (pin the AMI alias, then `terminationGracePeriod`): backlog.
- Spot interruptions can still move SonarQube. If builds keep failing on `Connection refused` after this change, consider
  an on-demand CI NodePool or retries in the Jenkinsfile's scanner step (developers).
