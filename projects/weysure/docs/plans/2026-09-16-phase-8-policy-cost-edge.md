# Phase 8 implementation plan

Spec: [2026-09-16-phase-8-policy-cost-edge.md](../specs/2026-09-16-phase-8-policy-cost-edge.md).
Adebayo runs `terraform apply`, `kubectl cordon/drain`, NLB deletion; I write, verify read-only.

| # | Task | Repo / files | Depends on |
|---|---|---|---|
| 1 | LBC IAM policy + pod identity association | infra `terraform/lbc.tf` | — (apply) |
| 2 | LBC chart + Traefik Service annotations + namespace readiness-gate label | gitops `bootstrap/apps/aws-load-balancer-controller.yaml`, `platform/traefik` | 1 |
| 3 | Verify new NLB, DNS switch, probe through drain; delete legacy NLB | cluster (Adebayo) | 2 |
| 4 | Graviton node group added | infra `main.tf` (`system_arm`) | — (apply) |
| 5 | Cordon/drain x86 nodes; verify; remove x86 group | Adebayo; infra | 4 |
| 6 | Redis `do-not-disrupt` | gitops `redis.yaml` | — |
| 7 | vpc-cni network policy mode | infra `main.tf` addon `configuration_values` | — (apply) |
| 8 | NetworkPolicies, allows first, deny last, probe between | gitops `projects/weysure/environments/prod/network/` | 7 |
| 9 | Kyverno chart + 8 ClusterPolicies in Audit | gitops `bootstrap/apps/kyverno*.yaml`, `platform/kyverno/` | — |
| 10 | Quotas | gitops `projects/weysure/environments/prod/quota.yaml` | — |
| 11 | After 7 days: Enforce in `weysure-prod`; exceptions | gitops | 9 |
| 12 | SOP, findings, checklist, diagram | infra docs | all |

Parallel lanes: 1 ‖ 4 ‖ 6 ‖ 7 ‖ 9 ‖ 10. Each Terraform task is its own PR + apply.

Rollback: 1–3 remove annotations → in-tree controller resumes with the legacy NLB (kept 24 h);
4–5 keep the x86 group until the arm64 group has run 24 h; 8 delete `default-deny` first;
9 set `Audit`; 11 flip one policy at a time.
