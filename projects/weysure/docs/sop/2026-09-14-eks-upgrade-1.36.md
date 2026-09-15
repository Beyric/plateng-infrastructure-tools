# SOP — EKS upgrade 1.31 → 1.36

**Shipped:** 2026-09-14 · **PRs:** infra #19–#23 (one hop each) · gitops #26 (Vault PDB), #27 (Traefik HA)
· **Cost delta:** **−$365/mo** (control plane $0.60/h → $0.10/h) · Spec:
[2026-09-14-eks-upgrade-1.36](../specs/2026-09-14-eks-upgrade-1.36.md) · Runbook:
[EKS_UPGRADE.md](../runbooks/EKS_UPGRADE.md)

## What shipped

Five one-line diffs to `terraform.tfvars` (`kubernetes_version`), each applied by Adebayo. Every
apply updated the control plane, the five managed addons and the system node group (module 21.x
follows `kubernetes_version` for all three); Karpenter drifted the workload nodes to the new AMI on
its own. Final state: 1.36 `ACTIVE` (eks.12), `STANDARD_SUPPORT` to 2027-08-02, all kubelets
`1.36.3`, addons ACTIVE, Vault unsealed, all Argo apps Healthy, all four public hosts 200.

| Hop | Wall clock | Terraform | API probe (1 req / 2 s) |
|---|---|---|---|
| 1.31 → 1.32 | ~15 min | 1 add · 5 change · 1 destroy | 5 fails, one ~50 s hole |
| 1.32 → 1.33 | 17 min | 1 · 4 · 1 | 5 isolated |
| 1.33 → 1.34 | 19 min | 1 · 3 · 1 | 8 isolated |
| 1.34 → 1.35 | ~18 min | 1 · 3 · 1 | 2 isolated |
| 1.35 → 1.36 | ~16 min | 1 · 3 · 1 | 6 isolated |

"1 destroy" is always `module.eks.time_sleep`, the module's internal wait timer.

## Findings

**㊲ — A single-replica PDB blocks every drain.** Vault's chart computed `maxUnavailable: 0`; EKS
fails a node-group update after 15 min of blocked eviction. Disabled at one replica (gitops #26);
re-enable at three.

**㊳ — Traefik ran one replica, no PDB, on a spot node.** Karpenter drift evicted the only ingress
pod during hop 1: every host dark for ~50 s. The Phase 7 spec's "2+ replicas on system nodes" was
an unverified assumption. Now two replicas pinned to system nodes, one per node, `minAvailable 1`
(gitops #27). Hops 2–5 kept Traefik 2/2 throughout.

**㊴ — The in-tree load-balancer controller cannot update the NLB.** It logs
`SyncLoadBalancerFailed: Multiple tagged security groups`: the eks module hard-codes
`kubernetes.io/cluster/beyric-prod=owned` on the node SG and EKS puts the same tag on the cluster
SG. Nodes still register (health checks pass on the existing NodePort rules), but deregistration
lags termination — the isolated probe failures in every hop. Fix: AWS Load Balancer Controller with
pod-IP targets and readiness gates. **First item of Phase 8.**

Also: `upgradePolicy.supportType` on the cluster is a *policy* (may the cluster enter extended
support), not the billing state; the version's status from `describe-cluster-versions` is what bills.

## Verification

`aws eks describe-cluster` 1.36/ACTIVE · `describe-cluster-versions --cluster-versions 1.36` →
STANDARD_SUPPORT · `kubectl get nodes` all `v1.36.3` · `aws eks list-addons` five ACTIVE ·
`vault status` unsealed · `kubectl get app -n argocd` all Synced/Healthy · api, web, jenkins, sonar 200.
Cost run-rate re-checked in Cost Explorer after 48 h (expected ≈ $13/day from ≈ $25).

## Rollback

None for the control plane (irreversible); the gates were insights → plan review → one hop at a
time. Node AMI can be pinned back via `amiSelectorTerms` (Karpenter) or the module's
`ami_release_version` if a kubelet regression appears.
