# Runbook — sleep and wake the platform (pre-launch only)

**Why not `terraform destroy`:** Vault's data and hand-typed config, the RDS database, Jenkins/Sonar
history, the KMS unseal key (deletion is scheduled, then Vault backups are undecryptable), Secrets
Manager names (held 7–30 days), Let's Encrypt rate limits and a multi-hour manual re-bootstrap.
Sleep keeps all state and stops only the hourly compute.

| | Awake | Asleep |
|---|---|---|
| EKS control plane | $2.40/day | $2.40 |
| System nodes 2× m7g.large | $3.90 | 0 |
| Karpenter spot nodes | ~$1.0–1.5 | 0 |
| RDS db.t4g.micro | $0.40 | storage only ~$0.08 |
| NAT gateway, NLB, EBS, KMS, Secrets Manager | ~$2.2 | ~$2.0 |
| **Total (before VAT)** | **~$12.5/day** | **~$4.5/day** |

## One-time setup: healthchecks.io API key
Without it the scripts still work; healthchecks.io just sends one "DOWN" notification per sleep.
healthchecks.io → project → **Settings → API Access → Create** a **read-write** key, then store it
(the key is typed, never echoed, never in shell history):
```bash
kubectl exec -n vault -it vault-0 -- vault login -method=userpass username=adebayo
```
```bash
printf 'API key: '; read -rs K; echo; printf '{"api_key":"%s"}' "$K" | kubectl exec -n vault -i vault-0 -- vault kv put secret/platform/healthchecks - >/dev/null; unset K; kubectl exec -n vault vault-0 -- sh -c 'echo "api_key: $(vault kv get -field=api_key secret/platform/healthchecks | tr -d "\n" | wc -c) chars"'
```
The script reads it through your Vault login inside `vault-0` (1 h). Log in again before sleeping, or
pass it for one run with `HC_API_KEY=… platform-sleep.sh`.

## Sleep (~20 min, most of it waiting for the nodes to drain — measured 21 min)
```bash
~/Documents/beyric/projects/plateng-infra/plateng-infrastructure-tools/scripts/platform-sleep.sh
```

| Step | What | Why in this position |
|---|---|---|
| 1 | Vault snapshot → S3; read the healthchecks key | Back up before switching anything off. Vault is gone later, so the key is read now. A failed snapshot aborts with nothing changed. |
| 2 | Silence Alertmanager (12 h) | Also stops the Watchdog pings, so the healthchecks pause is not undone. |
| 3 | Pause Argo automated sync: **`root` first**, then `karpenter-nodepools`, `weysure-prod`, `weysure-api`, `weysure-web` | `root` (selfHeal) owns the child Applications and re-applies them. The old policy is saved in the annotation `beyric.io/sleep-automated`. |
| 4 | Wait 45 s and check the pause is still in place | Argo reverts within seconds when it is going to. Fails here = nothing is scaled down yet. |
| 5 | NodePool cpu limit 0 | Karpenter must not replace what is about to be removed. |
| 6 | api, api-scheduler, api-worker, web, redis → 0 | PDBs would block the last eviction; Redis carries `do-not-disrupt`. |
| 7 | Delete NodeClaims; poll EC2 until 0 Karpenter instances | Karpenter must be alive to terminate its own instances, or they are orphaned and keep billing. |
| 8 | Pause healthchecks.io; system node group → 0 | |
| 9 | Stop RDS | |
| 10 | Poll EC2 until the cluster has 0 instances; pause healthchecks again | Proof that compute billing stopped. EKS drains first, and PDBs on the last node make this take up to ~15 min. |

**If it stops half-way, for any reason: run `platform-wake.sh`.** It returns to the state in git from
any intermediate state.

## Wake (~20–25 min)
```bash
~/Documents/beyric/projects/plateng-infra/plateng-infrastructure-tools/scripts/platform-wake.sh
```
RDS start → node group to 2 → Vault auto-unseals (KMS) → Karpenter and Argo CD up → 30 min silence →
`root`'s automated sync restored from the annotation → `root` synced (re-applies the child
Applications from git, automated sync included) → children synced (replicas and NodePool limit come
back from git) → waits for **every Argo app Synced/Healthy and both sites 200** → snapshot if the last
one is older than 20 h → silences lifted. healthchecks.io resumes by itself on the next Watchdog ping.
Exit code 1 if not all-green after 20 min.

`root` is the one Application that is not in git's sync path (`bootstrap/root-app.yaml` is applied by
hand), so nothing but the wake script restores its sync policy. Check after every wake:
```bash
kubectl get app root -n argocd -o jsonpath='{.spec.syncPolicy.automated}'
```
Expected: `{"prune":true,"selfHeal":true}`.

## Why the first runs failed (Finding ㊹)
Argo CD is the owner of the cluster. First run: `karpenter-nodepools` (selfHeal) reverted the NodePool
limit within seconds, a fresh gitops commit made every app re-apply git and put Redis back, and
Karpenter launched three new nodes for the evicted pods. Second version (infra #34) paused the four
Applications it fights — but those Applications are themselves objects owned by `root`, which has
`selfHeal: true` and puts `syncPolicy.automated` back on them. **Pause from the top of the ownership
chain down, and verify the pause before acting on it.**

## Rehearsal log
| Date | Part | Result | Duration | Notes |
|---|---|---|---|---|
| 2026-09-23 | sleep v1 | failed | — | Argo reverted every change within seconds (Finding ㊹) |
| 2026-09-23 | sleep v2 (infra #34) | not run | — | would have been reverted by `root` |
| **2026-09-29** | **sleep v3 (infra #37)** | **PASS** | **21 min** (13:54 → 14:15 UTC) | Snapshot taken first. Pause held through the 45 s proof. Spot nodes gone in 1 min, RDS stopped after 8 min, system nodes gone after 17 min (EKS drain). healthchecks paused, HTTP 200. **0 instances.** |
| **2026-10-01** | **wake v3, first run ever** | **FAILED, recovered by hand** | 1 h 45 min from first attempt to all green (20:15 → 22:01 UTC); asleep for 2 d 6 h | Three bugs, below. Final state: 32/32 apps, both sites 200, snapshot taken. |
| | wake v4 (this fix) | not run yet | | next wake is its rehearsal |

### What the first wake found (2026-10-01)
| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `vault-0` Pending 30 min; script timed out twice | Vault's volumes are zonal (us-east-1b): one eligible node. It was Ready first and took 36 pods, 1915m of 1930m CPU requested | gitops: `priorityClassName: system-cluster-critical` on Vault; script now prints the scheduler's reason |
| 2 | API at 0 pods for 45 min, `SiteDownExternal` critical | the script synced `weysure-api` 42 s after Vault was Ready; External Secrets had not reconnected; the PreSync ExternalSecret failed, 3 retries used up; **Argo does not retry a failed sync of the same commit** | script waits for `ClusterSecretStore vault` Ready (restarts ESO after 3 min) and re-syncs any app whose last sync failed |
| 3 | `KubeJobFailed` ×2 | the 02:00 snapshot schedule fired twice with no nodes and failed at its deadline | script removes failed `vault-snapshot-*` Jobs before taking its own |

Also seen: Jenkins woke with 10 queued builds (PRs opened while asleep); Karpenter launched one
c7i-flex.2xlarge for them; the builds did not complete and must be re-run by the developers.


Observed while asleep: 0 nodes, 0 instances, RDS `stopped`, 10 volumes kept, all five paused
Applications still paused with their policy saved in the annotation, both sites unreachable.

## Vault cannot be scheduled on wake (`Insufficient cpu` + `PersistentVolume's node affinity`)
Should not happen once Vault has its priority class. If it does: free CPU on the node in Vault's zone.
```bash
kubectl get pv -o custom-columns='PVC:.spec.claimRef.name,ZONE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]' | command grep vault
kubectl get nodes -L topology.kubernetes.io/zone,node-role
kubectl cordon <system node in that zone>
kubectl delete pod -n kyverno -l 'app.kubernetes.io/component in (background-controller,cleanup-controller,reports-controller)'
kubectl uncordon <the same node>
```
The deleted pods restart on the other system node (the first is cordoned); Vault then fits. Run
`platform-wake.sh` again — it is safe to re-run from any state.

## API at 0 pods after wake, `weysure-api` OutOfSync with last sync `Failed`
`kubectl patch app weysure-api -n argocd --type merge -p '{"operation":{"sync":{}}}'` — once
`kubectl get clustersecretstore vault` says `True`.

## After a wake or a burst of builds: check the application node's size
Karpenter sizes a node for everything pending at that moment. At wake that includes queued Jenkins
builds (ten on 2026-10-01 → one `c7i-flex.2xlarge`, $3.60/day, 22 % used). The builds end; the
application stays on the big node, and Karpenter cannot shrink it because Redis carries `do-not-disrupt`.
```bash
kubectl get nodes -l node-role=workload -L node.kubernetes.io/instance-type
```
Anything larger than `xlarge` holding the application: replace it (`VPC_CNI_MODE_CHANGE.md` →
*Replacing a workload node*: delete the NodeClaim, then the Redis pod). Done 2026-10-01: → `large`,
$0.91/day, no failed request. The lasting fix is a separate NodePool for CI (deferred, ADR-023).

Spot reclaims are normal: 2026-10-02 the application's node was reclaimed twice in ten minutes
(08:05 and 08:13 WAT); replicas never went below 1, no probe failed, no alert fired.

## Rules
- Sites are **down** while asleep. Never sleep once there are users.
- **Tell the developers before sleeping and after waking.** While asleep they have no CI and no production; an unannounced sleep reads as an outage (developer note, 2026-09-30). Their queued builds fail at wake and must be re-run.
- **Nothing watches the platform while it is asleep**: Prometheus and Alertmanager are off, healthchecks.io is paused. Argo CD is off too: a merge to plateng-gitops is applied only at wake — do not merge what you will not be there to watch.
- Never sleep a platform that is not healthy: Vault down, a node group update in progress or failed, or apps Degraded.
  Fix first. Sleeping hides the fault and makes the wake harder (Finding ㊺). The snapshot in step 1 fails if Vault is down.
- AWS auto-starts a stopped RDS instance after **7 days** — and it then bills while nothing uses it. Asleep for longer than a week: wake and sleep again, or stop it again by hand (`aws rds stop-db-instance --db-instance-identifier weysure-postgres`).
- Do not `terraform apply` while asleep — it sets the node group minimum back to 2 (a wake by accident).
- Argo shows `root`, `karpenter-nodepools` and the `weysure-*` apps OutOfSync while asleep; that is the sleep state.
- A commit to plateng-gitops while asleep is safe: the paused apps do not sync it until wake.
- The 02:00 UTC Vault snapshot does not run while asleep (no nodes). Sleep takes one before, wake takes one after.
- Vault leases expire while asleep; pods mint fresh credentials on wake. Jenkins re-downloads plugins.
