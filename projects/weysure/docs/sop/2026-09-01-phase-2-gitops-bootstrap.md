# SOP — Phase 2: GitOps bootstrap

**Shipped:** 2026-09-01 · **Repos:** `plateng-gitops` PR #1 · **Cost delta:** $0

## What shipped

The cluster stopped being something you talk to and became a projection of a git commit.

| Component | Delivered by | Verified |
|---|---|---|
| **Argo CD** 10.6.0, self-managing | `helm install` once, then adopts itself | `Synced` / `Healthy` |
| **gp3 StorageClass** on `ebs.csi.aws.com`, default | Argo CD | PVC bound, PV provisioned by CSI |
| **metrics-server** 3.14.0 | Argo CD | `kubectl top nodes` returns data |
| **Karpenter** 1.14.1 + NodePool + EC2NodeClass | Argo CD | node in 11s, consolidated after 1m |

## The bootstrap

Exactly two hand-run commands, both once, ever:

1. `helm install argocd argo/argo-cd -f <the same values file Argo CD will manage itself with>`
2. `kubectl apply -f bootstrap/root-app.yaml`

The values file was fetched from `plateng-gitops` rather than written locally. Installing with
different values would have shown drift on Argo CD's first self-sync.

**Zero hand-created secrets.** ADR-014 anticipated one — Argo CD's repository credential.
Making `plateng-gitops` public removed it, since Argo CD reads a public repo anonymously.

## Sync waves

Wave 0 (Argo CD, storage, metrics-server) → wave 1 (Karpenter controller + CRDs) → wave 2
(NodePool, EC2NodeClass). Waves 1 and 2 cannot be merged: the custom resources depend on CRDs
the chart installs, and applying both at once is a race.

## Finding ⑳ closed

The cluster shipped with only `gp2` on the deprecated in-tree provisioner
`kubernetes.io/aws-ebs`. The EBS CSI driver was ACTIVE but nothing routed to it. `gp3` on
`ebs.csi.aws.com` is now default. `WaitForFirstConsumer` is required, not stylistic: EBS
volumes are AZ-bound, so binding before the scheduler picks a node can strand a pod in a zone
that cannot attach its volume.

## Finding ㉑ — Spot silently unavailable, ~$40/month

**New, and the most valuable thing this phase found.**

The first Karpenter node came up `capacity-type=on-demand` despite a spot-first NodePool.
Karpenter's logs showed it had tried spot and been refused:

```
AuthFailure.ServiceLinkedRoleCreationNotPermitted:
The provided credentials do not have permission to create the
service-linked role for EC2 Spot Instances.
```

Sequence: NodeClaim created → `CreateFleet` failed `UnfulfillableCapacity` → NodeClaim deleted
→ retried → landed on-demand.

The cause was not Karpenter's IAM. **`AWSServiceRoleForEC2Spot` had never existed in the
account.** AWS creates that role invisibly the first time you launch a spot instance through
the console. This account has only ever been driven by IaC, so nobody ever clicked the button,
and Karpenter's role is not permitted to create it.

**Fix**, once per account, free:

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

After it: `c7i-flex.large` and `c5a.large`, both `capacity-type=spot`, Ready in 11 seconds.

**Why it matters beyond the money:** Karpenter did not error, alert or degrade. It quietly
delivered a working node at roughly three times the price, and the cluster looked perfectly
healthy. Without checking the `karpenter.sh/capacity-type` label, this would have cost ~$40 a
month indefinitely.

Service-linked roles are worth knowing generally — Spot, ELB, EKS and ECS each need one to
exist before they work, and the console creates them silently on first use. When a service
mysteriously refuses to do something it should, check:

```bash
aws iam list-roles --path-prefix /aws-service-role/
```

## Verification

| Test | Result |
|---|---|
| PVC bound via CSI | `pvc-e5b77bb5…` `Bound`, StorageClass `gp3`, provisioner `ebs.csi.aws.com` |
| Karpenter provisions | `c6a.xlarge` Ready in **11s** |
| Karpenter uses spot | `c7i-flex.large`, `c5a.large` — `capacity-type=spot` after the fix |
| Consolidation | node tainted, drained and deleted ~1 min after the workload went away (logged saving: $0.15) |
| PV reclaimed | no orphaned PV after PVC delete |

## Drift policy

`selfHeal` reports drift as `OutOfSync` rather than correcting it. The first weeks should show
honestly how often someone reaches past the system. Phase 5 turns correction on once that
number is real — turning it on earlier hides the behaviour instead of changing it.

## Rollback

`kubectl delete application root -n argocd` stops reconciliation; `helm uninstall argocd -n
argocd` removes Argo CD. Karpenter-provisioned nodes drain and terminate on their own. The
Terraform-managed cluster is unaffected.

## Follow-ups

| Item | Where |
|---|---|
| `gp2` still exists as a non-default class | Harmless; remove in Phase 10 cleanup |
| Argo CD has no ingress — access is `kubectl port-forward` | Phase 4 exposes it via Traefik |
| `selfHeal` correction still off | Phase 5, once the drift count is honest |
