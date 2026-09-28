# Runbook — changing how nodes get pod IPs (VPC CNI mode)

Applies to any change of `ENABLE_PREFIX_DELEGATION`, custom networking, `WARM_*` targets or `maxPods`.

**Rule (Finding ㊺): a CNI mode change takes effect on every running node at once. A node that was
born in the old mode must never receive a new pod after the change. Cordon the old nodes first,
bring up new ones, then drain — never flip the mode and roll the nodes in one apply.**

Why: the setting is an environment variable on the `aws-node` DaemonSet. There is one DaemonSet for
the whole cluster, so there is no "per node group" switch. `maxPods` is the opposite: it is baked into
a node at boot and only new nodes get it.

## Procedure

| # | Step | Command / where | Expected |
|---|---|---|---|
| 0 | Vault snapshot | `kubectl create job -n vault --from=cronjob/vault-snapshot vault-snapshot-pre-cni-$(date +%s)` | Job `Complete` |
| 1 | Note zonal volumes | `kubectl get pv -o custom-columns=PVC:.spec.claimRef.name,ZONE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]` | Vault, Prometheus, Loki … each tied to one AZ: the new node **in that AZ** must be Ready before its pod moves |
| 2 | **PR 1:** add a second node group (`system_arm_v2`) with the new `maxPods`, plus the addon setting. Old group untouched. | infra `main.tf` | plan: node group added, addon changed, **old group not in the plan** |
| 3 | **Cordon every old node** | `kubectl cordon -l eks.amazonaws.com/nodegroup=<old-group>` | `SchedulingDisabled` on all of them |
| 4 | Open the watch in a second terminal (below) | | |
| 5 | `terraform apply` | | new nodes `Ready`, `allocatable.pods` = new value, one in **each** AZ |
| 6 | Drain old nodes one at a time | `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=10m` | pods `Running` on a new node before the next drain |
| 7 | Verify (below), wait 30 min | | |
| 8 | **PR 2:** remove the old node group | infra `main.tf` | plan: old group destroyed only |

Running pods keep their IP through the change; only **new** pods on an old node are at risk. That is
why a cordon is enough to make step 5 safe.

### Watch during steps 5–6 (second terminal)
```bash
watch -n 10 'kubectl get nodes -L node-role -o custom-columns=NODE:.metadata.name,ROLE:.metadata.labels.node-role,PODS:.status.allocatable.pods,UNSCHED:.spec.unschedulable; echo; kubectl get pods -A --no-headers | grep -vE "Running|Completed"; echo; kubectl get events -A --field-selector reason=FailedCreatePodSandBox --no-headers | tail -3'
```
**Abort criteria — stop and investigate, do not wait for Terraform:** any pod in `ContainerCreating`
for more than 2 minutes, any `FailedCreatePodSandBox` event, or a **critical alert in Slack**.

### Verify
```bash
aws ec2 describe-instances --filters "Name=tag-key,Values=kubernetes.io/cluster/beyric-prod" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[PrivateDnsName,length(NetworkInterfaces),sum(NetworkInterfaces[].length(Ipv4Prefixes || `[]`))]' --output text
```
Every node shows at least one prefix. Then: all pods Running, Vault unsealed, all ExternalSecrets
Ready, probes green.

## Recovery — pods stuck `ContainerCreating` on an old node
1. Confirm: `kubectl get events -A --field-selector reason=FailedCreatePodSandBox` names the node.
2. **Collect the evidence first** (2 minutes; the node will be gone afterwards):
   ```bash
   kubectl logs -n kube-system $(kubectl get pod -n kube-system -l k8s-app=aws-node --field-selector spec.nodeName=<node> -o name) -c aws-node --tail=500 > ~/cni-<node>.log
   ```
3. Move everything off it. The stuck pods are not Ready, so a PDB-respecting eviction can wait
   forever; `--disable-eviction` deletes instead of evicting:
   ```bash
   kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --disable-eviction --force --timeout=300s
   ```
4. `terraform plan` → `apply` again; EKS retries the node group update on the now-empty node.
5. If `kubectl get clustersecretstore vault` says `unable to create client` for more than 5 minutes
   after Vault is back: `kubectl rollout restart deploy/external-secrets -n external-secrets`.

## Incident record — 2026-09-23 (infra #36)

**Change:** one apply set `ENABLE_PREFIX_DELEGATION=true` on the addon and changed the system node
group's launch template (`maxPods: 110`), which rolls both nodes.

| UTC | Event | Source |
|---|---|---|
| ~22:45 | `terraform apply` starts | terminal |
| 22:48:30 | Last sample from Vault and from all seven Blackbox probes. `vault-0` re-created on old node `ip-10-0-4-214` at 22:48:38, stuck `ContainerCreating` | Prometheus; pod metadata |
| 22:51:30 | **`VaultDown` (critical) fires** | Prometheus `ALERTS` |
| 22:52–23:17 | Six ExternalSecrets go not-Ready one by one | Prometheus |
| 22:59–23:08 | `TargetDown`, `NoWorkloadNode`, `KubePodNotReady`, `ExternalSecretNotReady` fire | Prometheus `ALERTS` |
| 23:12 | Apply fails after 28 min: `PodEvictionFailure` on `ip-10-0-4-214` | terminal |
| 23:13 | 21 pods on the old node not running (Vault, Argo CD, Karpenter, cert-manager, Kyverno, LB controller, Grafana, Blackbox …). Old node `allocatable.pods=29`, new node `110`. API answers 200 | `kubectl`, `curl` |
| 23:17:41 | Forced drain; `vault-0` re-created on new node `ip-10-0-4-128` | pod metadata |
| 23:18 | Probes resume. One failed sample on the external API probe at 23:18:00 | Prometheus |
| 23:27:37 | **Vault Ready and unsealed** | pod condition |
| 23:28 | Every pod Running; both system nodes at 110 | `kubectl` |
| 23:31 | ESO restarted; all ExternalSecrets Ready | Prometheus |

**Impact.** Vault unavailable **39 min** (22:48:30–23:27:37). Argo CD, Karpenter, cert-manager,
Kyverno and the LB controller down for about 30 min. No new pod could have started and no
credential could have been issued in that window. **User-facing impact: not measured** — the
Blackbox exporter was one of the stuck pods, so there is no probe data for 22:48:30–23:18:00.
Two manual requests (23:13, 23:28) returned 200, and running API pods kept their database
credentials.

**What is known**
- New pods on the old node failed with `FailedCreatePodSandBox: failed to setup network`.
- The new node, in the same cluster and mode, started pods normally.
- Vault's volume is zonal (`us-east-1b`). When its node was drained, the only system node in 1b was
  the old one, so Vault could go nowhere else. The first new node was in 1a. (Procedure step 1.)
- The old node was schedulable at 23:13 (the manual `cordon` reported `cordoned`).
- Today one workload node that predates the change (`ip-10-0-4-83`) runs in mixed mode — 5
  single IPs and 2 prefixes — and works.

**What is not known**
- **The exact reason the old node could not give out IPs.** The `aws-node` log query returned
  nothing and the node was replaced minutes later. The explanation given on the night — subnet
  fragmentation — is **not supported**: no `InsufficientCidrBlocks` error was captured, and new
  nodes received three /28 prefixes each from the same subnets. The most likely cause is that
  every address slot on the old node's interfaces was already held by single IPs, leaving no slot
  for a prefix; this is a hypothesis, not a finding.
- Which PodDisruptionBudget, if any, blocked the EKS drain. The check run at the time read the
  wrong column.

**What went wrong in the process**
1. Mode change and node roll in one apply; old nodes were not cordoned first.
2. The PR named the node roll as the risk, not the mode change on running nodes.
3. `VaultDown` fired three minutes in, and the apply ran another 21 minutes. Nobody was told to
   watch Slack or given an abort criterion.
4. No evidence was collected from the node before it was destroyed.
5. Monitoring was on the node being changed: one Blackbox replica, and the site alerts test
   `probe_success == 0`, which is silent when there is no data at all.

**Correction to the first write-up.** The summary given that night said "new nodes first, then the
addon flag". That order does not help: the new nodes would then be converted while running as
well. The order in the procedure above follows the AWS guide (setting first, then **new** node
groups) and adds the cordon.

## Follow-ups
| Item | Why | Where |
|---|---|---|
| `unhealthyPodEvictionPolicy: AlwaysAllow` on PDBs | Lets a drain evict pods that are already not Ready, so a broken node can be emptied without `--disable-eviction` | gitops `charts/beyric-app`, platform charts |
| Blackbox: 2 replicas spread over both system nodes, and an alert on `absent(probe_success)` | Monitoring must not go blind with the node it runs on | gitops `platform/monitoring` |
| Replace mixed-mode node `ip-10-0-4-83` | AWS: capacity reporting is unreliable on a node holding both kinds of address | `kubectl delete nodeclaim <name>` (Karpenter drains it) |
| Subnet CIDR reservations for prefixes | Private subnets are /24 with ~165 free addresses and no reservation; fragmentation is a future risk | infra `vpc` |
