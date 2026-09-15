# EKS upgrade 1.31 → 1.36 (Phase 8, item 1)

**Status:** approved 2026-09-14 ("GO"). **Owner of every apply:** Adebayo.

## Why now

Kubernetes 1.31 left standard support on 2025-11-26. The control plane bills
extended support at $0.60/h instead of $0.10/h: $182 of the $359 month-to-date
(Cost Explorer, 2026-09-14). Versions in standard support today: 1.34 (ends
2026-12-02), 1.35 (2027-03-27), 1.36 (2027-08-02). Target **1.36** — longest
runway, and 1.34 would be back in extended support in eleven weeks.

Saving ≈ $0.50/h ≈ **$365/month** plus VAT.

## Constraints that shape the plan

| Fact | Consequence |
|---|---|
| EKS upgrades one minor version at a time | five hops: 1.32 → 1.33 → 1.34 → 1.35 → 1.36 |
| A control-plane upgrade cannot be rolled back | one hop at a time; upgrade insights must PASS before each |
| terraform-aws-modules/eks 21.x: node group version and addon versions follow `kubernetes_version` | one `terraform apply` per hop does control plane → addons → system node group |
| Managed node group update drains nodes and respects PDBs; blocked eviction fails the update after 15 min | Vault's PDB (maxUnavailable 0 at 1 replica) disabled first — plateng-gitops #26 |
| Karpenter EC2NodeClass uses `al2023@latest` | after each hop Karpenter drifts workload nodes to the new AMI on its own, under the api/web PDBs |
| Karpenter 1.14.1 compatibility matrix: Kubernetes 1.36 needs Karpenter ≥ 1.13 | no Karpenter change needed |
| Platform charts (Argo 10.6, Traefik 41.4, cert-manager 1.21, ESO 2.10, metrics-server 3.14) all support 1.36 | no chart bumps needed for the upgrade itself |

## Per-hop procedure

1. `aws eks list-insights` — all PASSING for the target version. Stop if not.
2. PR: `terraform.tfvars` `kubernetes_version = "<next>"`. Merge.
3. `terraform plan` — expect: cluster version in-place update, five addon
   version changes, node group `version`/`release_version` change. **Nothing
   destroyed.** Paste the summary.
4. `terraform apply` — ~10 min control plane, then addons, then the node group
   rolls one node at a time (~10 min).
5. Verify (read-only, me): `kubectl get nodes` all on the new kubelet;
   addons Active; `kubectl get app -n argocd` all Healthy; Vault unsealed;
   both hosts 200; Karpenter node replaced (or replacing) under PDB.
6. Next hop.

## Expected impact per hop

| Component | Impact | Why |
|---|---|---|
| weysure api / web | none (PDB minAvailable 1, rolling under drain) | 2 replicas on workload node(s); Karpenter drift replaces one node at a time |
| Vault | unavailable ~1–2 min while its system node drains; auto-unseal on restart | single replica (ADR-007) |
| Vault Agent sidecars, ESO | retry through the Vault gap; no pod restarts | leases well within TTL |
| Jenkins, SonarQube | ~2 min each; no builds should run during a hop | single replicas on system nodes |
| Argo CD | ~1 min; reconciles on return | self-managed |
| Traefik / NLB | none | 2+ replicas across system nodes |

## Rollback

There is none for the control plane; that is why the gates above exist. If a
node group rollout fails: fix the cause (usually a PDB), re-apply — EKS resumes.
If Karpenter's new-AMI nodes misbehave: pin `amiSelectorTerms` to the previous
AMI id in `platform/karpenter/ec2nodeclass.yaml` and let drift roll back.

## Definition of done

`aws eks describe-cluster` → version 1.36; `describe-cluster-versions --cluster-versions 1.36` →
STANDARD_SUPPORT (the cluster's `upgradePolicy.supportType` is a policy setting, not the billing
state — corrected after hop 3); all nodes
1.36 kubelet; all Argo apps Synced/Healthy; both hosts 200; cost run-rate
drops by ~$12/day within 48 h (Cost Explorer daily).
