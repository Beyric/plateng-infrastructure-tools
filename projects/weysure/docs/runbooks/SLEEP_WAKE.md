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

## Sleep
```bash
~/Documents/beyric/projects/plateng-infra/plateng-infrastructure-tools/scripts/platform-sleep.sh
```
Order matters: NodePool limit 0 → Redis to 0 (its `do-not-disrupt` would block the drain) → delete
NodeClaims **while Karpenter is still running** (otherwise its spot instances are orphaned and keep
billing) → system node group to 0 → stop RDS. The script refuses to continue if Karpenter instances
are still running.

## Wake (~10–15 min)
```bash
~/Documents/beyric/projects/plateng-infra/plateng-infrastructure-tools/scripts/platform-wake.sh
```
RDS start → node group to 2 → Vault auto-unseals (KMS) → Karpenter up → NodePool limit and Redis
restored → Argo reconciles. Verify: `kubectl get app -n argocd` all Healthy; both hosts 200.

## Why the first run failed (Finding ㊹)
Argo CD is the owner of the cluster. `karpenter-nodepools` has `selfHeal: true` and reverted the
NodePool limit within seconds; a fresh gitops commit made every app re-apply git and put Redis back;
Karpenter then launched three new nodes for the evicted pods. Any script that changes the cluster
directly must first switch off automated sync on the Applications it fights (`weysure-prod`,
`weysure-api`, `weysure-web`, `karpenter-nodepools`) and scale the app to 0 so PDBs cannot block the
last eviction. Wake restores by re-syncing `root`, which re-applies the Applications with automated
sync on. A commit to plateng-gitops between "pause" and "nodes to 0" (minutes) would still revert.

## Rules
- Sites are **down** while asleep. Never sleep once there are users.
- AWS auto-starts a stopped RDS instance after **7 days**.
- Do not `terraform apply` while asleep — it sets the node group minimum back to 2 (a wake by accident).
- Argo shows `karpenter-nodepools` and `weysure-prod` OutOfSync while asleep; that is the sleep state.
- Vault leases expire while asleep; pods mint fresh credentials on wake. Jenkins re-downloads plugins.
