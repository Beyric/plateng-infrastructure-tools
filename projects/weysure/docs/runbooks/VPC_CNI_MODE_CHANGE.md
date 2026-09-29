# Runbook — changing how nodes get pod IPs (VPC CNI mode)

Applies to any change of `ENABLE_PREFIX_DELEGATION`, custom networking, `WARM_*` targets or `maxPods`.

**Rule (Finding ㊺): a CNI mode change takes effect on every running node at once. A node that was
born in the old mode must never receive a new pod after the change. Cordon the old nodes first,
bring up new ones, then drain — never flip the mode and roll the nodes in one apply.**

Why: the setting is an environment variable on the `aws-node` DaemonSet. There is one DaemonSet for
the whole cluster, so there is no "per node group" switch. `maxPods` is the opposite: it is baked into
a node at boot and only new nodes get it.

**Second rule (Finding ㊺, 2026-09-29): with prefix delegation, count free _blocks_, not free
addresses.** A node takes pod addresses in /28 blocks of 16. AWS hands out only a block that is
completely free. One single address anywhere inside a block — a node's own IP, an EKS control-plane
interface, RDS — makes all 16 unusable as a prefix.

```bash
~/Documents/beyric/projects/plateng-infra/plateng-infrastructure-tools/scripts/subnet-blocks.sh
```
Read-only. Prints every /28 of the private subnets: free, in use, or blocked and by what.
Exit code 0 = ok, 1 = fewer than 3 free blocks in a subnet, 2 = none. **Run it before any change that
creates nodes** (node roll, EKS upgrade, wake from sleep) and whenever a pod is stuck in
`ContainerCreating` with `failed to assign an IP address to container`.

| Protection | State |
|---|---|
| Prefix reservations `.64`–`.239` in both private subnets (`vpc-reservations.tf`) | new single addresses can no longer land there |
| Larger subnets for nodes | **follow-up** — a /24 has 14 usable blocks in total |

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

## Recovery — a new node cannot start any pod (no free block)
`command grep` below: this laptop's zsh aliases `grep` to ripgrep, which reads `-E` and `-o` differently.
1. Confirm: `scripts/subnet-blocks.sh` shows `0 free block(s)` for the node's subnet. CloudTrail shows
   the API error (there is no shell in the `aws-node` container to read its log file):
   ```bash
   aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssignPrivateIpAddresses --max-results 20 --query 'Events[].CloudTrailEvent' --output text | command grep -o '"errorCode":"[^"]*"' | sort | uniq -c
   ```
2. Remove the node that cannot work, so its pods go to nodes that can:
   `kubectl get nodeclaims` → `kubectl delete nodeclaim <name>`.
3. Free blocks: the script names what blocks each one. Replace the owner that holds the most
   (procedure below).

## Replacing a workload node that holds scattered single addresses
For a node from before prefix delegation (it shows `(secondary)` addresses in the script's output).
Short downtime for what runs on it; api and web are not on it.

| # | Step | Expected |
|---|---|---|
| 1 | `scripts/subnet-blocks.sh` | note the free blocks before |
| 2 | `kubectl get pods -A -o wide --field-selector spec.nodeName=<node>` | know what will restart |
| 3 | `kubectl delete nodeclaim <name> --wait=false` | Karpenter taints the node and starts evicting |
| 4 | `kubectl delete pod redis-0 -n weysure-prod` — only if Redis is on it | Redis carries `do-not-disrupt`: Karpenter will not evict it, and the node would never go |
| 5 | watch `kubectl get pods -A -o wide \| command grep -v Running` | pods land on a **new** node and wait in `ContainerCreating` |
| 6 | the old instance terminates; its addresses are released | within ~2 min the waiting pods start |
| 7 | `scripts/subnet-blocks.sh` | free blocks went up; `RESULT: ok` |

Step 5 looks like the incident, and for a few minutes it is: the new node has no block until the
old one is gone. **Abort criterion:** pods still `ContainerCreating` 10 minutes after the old
instance has terminated.

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

## Incident record — 2026-09-29

| UTC | Event | Source |
|---|---|---|
| 08:04:35 | Karpenter launches two spot nodes in `us-east-1b` | Karpenter log |
| 08:05 | `ip-10-0-4-189` receives one /28. `ip-10-0-4-18` receives none | EC2 |
| 08:05–11:05 | Every pod on `ip-10-0-4-18` fails: `failed to assign an IP address to container` | events |
| 08:07 | metrics-server is one of the stuck pods: the HPAs have no metrics (`KubeAggregatedAPIDown`) | Prometheus |
| 08:16 | **`DeploymentReplicasMissing` (critical) fires** for api and web: 1 of 2 | Prometheus `ALERTS`, Slack |
| 10:56 | Investigation starts — by chance, while verifying an unrelated merge | session |
| 11:06 | Broken NodeClaim deleted; pods reschedule onto `ip-10-0-4-189` | `kubectl` |
| 11:11 | api 2/2, web 2/2, metrics-server 1/1 | `kubectl` |

**Impact.** api and web on one replica each for **170 min**. No failed external probe, no user
impact measured. HPAs blind for 3 h. Nobody acted on the critical alert for 2 h 40 min.

**Cause — proven.** CloudTrail: `AssignPrivateIpAddresses` → `InsufficientCidrBlocks`, 50 times in
the sample, from both new nodes. Subnet `10.0.4.0/24`: **144 free addresses, 0 free /28 blocks.**
Of 14 usable blocks, 6 were prefixes and 8 were blocked by 11 single addresses; 7 of those belonged
to one node from before prefix delegation (`ip-10-0-4-83`: two primary and five secondary addresses).

**The same alert had fired before.** 2026-09-24, 16:14–17:02 UTC, api and web at 1 of 2 for 48
minutes. It resolved by itself and was never investigated. The cause can no longer be proven.

### Correction to the 2026-09-23 record above
That record says the fragmentation explanation is "not supported" and files subnet CIDR
reservations as a low-priority follow-up. The evidence for 23 September is still missing, but the
judgement was wrong: fragmentation is now proven in the same subnet, and is the most likely cause
of the first incident as well. Lesson: *"not proven" is not "ruled out"*. A cause that fits the
symptom stays on the list, with its prevention, until something else is proven.

### What went wrong in the process
1. Prefix delegation was enabled on /24 subnets without counting blocks. 14 usable blocks, and
   every node holds 2–3 (`WARM_PREFIX_TARGET=1` keeps a spare one).
2. No reservation: single addresses were free to land in the middle of any block.
3. A critical alert that resolves by itself was treated as closed — twice.
4. There is no alert on the cause. The CNI exports `awscni_aws_api_error_count`; it is not scraped.

## Follow-ups
| Item | Why | Where |
|---|---|---|
| `unhealthyPodEvictionPolicy: AlwaysAllow` on PDBs | Lets a drain evict pods that are already not Ready, so a broken node can be emptied without `--disable-eviction` | gitops `charts/beyric-app`, platform charts |
| Blackbox: 2 replicas spread over both system nodes, and an alert on `absent(probe_success)` | Monitoring must not go blind with the node it runs on | gitops `platform/monitoring` |
| ~~Subnet CIDR reservations for prefixes~~ | **Done** 2026-09-29, `vpc-reservations.tf` | infra |
| **Replace node `ip-10-0-4-83`** | Holds 7 scattered single addresses; frees 6 blocks | procedure above — **do next** |
| **Larger subnets for nodes** (e.g. two /20) | A /24 has 14 usable blocks; 5 nodes already need 10–13 | infra `vpc`, blue/green node groups |
| Scrape `aws-node` metrics; alert on `awscni_aws_api_error_count` | Alert on the cause, minutes before replicas go missing | gitops `platform/monitoring` |
| Warm target: `WARM_IP_TARGET` instead of `WARM_PREFIX_TARGET=1` | Nodes stop holding a spare block each | infra addon config — one change at a time, after the above |
