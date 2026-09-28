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

## Sleep (~20 min, most of it waiting for the nodes to drain)
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
| 6 | api, api-scheduler, web, redis → 0 | PDBs would block the last eviction; Redis carries `do-not-disrupt`. |
| 7 | Delete NodeClaims; poll EC2 until 0 Karpenter instances | Karpenter must be alive to terminate its own instances, or they are orphaned and keep billing. |
| 8 | Pause healthchecks.io; system node group → 0 | |
| 9 | Stop RDS | |
| 10 | Poll EC2 until the cluster has 0 instances; pause healthchecks again | Proof that compute billing stopped. EKS drains first, and PDBs on the last node make this take up to ~15 min. |

**If it stops half-way, for any reason: run `platform-wake.sh`.** It returns to the state in git from
any intermediate state.

## Wake (~15–20 min)
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

## Rules
- Sites are **down** while asleep. Never sleep once there are users.
- Never sleep a platform that is not healthy: Vault down, a node group update in progress or failed, or apps Degraded.
  Fix first. Sleeping hides the fault and makes the wake harder (Finding ㊺). The snapshot in step 1 fails if Vault is down.
- AWS auto-starts a stopped RDS instance after **7 days**.
- Do not `terraform apply` while asleep — it sets the node group minimum back to 2 (a wake by accident).
- Argo shows `root`, `karpenter-nodepools` and the `weysure-*` apps OutOfSync while asleep; that is the sleep state.
- A commit to plateng-gitops while asleep is safe: the paused apps do not sync it until wake.
- The 02:00 UTC Vault snapshot does not run while asleep (no nodes). Sleep takes one before, wake takes one after.
- Vault leases expire while asleep; pods mint fresh credentials on wake. Jenkins re-downloads plugins.
