# Phase 10 implementation plan

| # | Task | Repo / files | Owner | Depends |
|---|---|---|---|---|
| 1 | Prefix delegation + node group max-pods; roll | infra `main.tf` | me → PR, Adebayo applies | — |
| 2 | Karpenter metricRelabelings; Argo ignoreDifferences; Vault config checksum | gitops | me → PR | — |
| 3 | Vault snapshot: IAM role + pod identity (`vault-snapshot`), bucket lifecycle 30 d, KMS deletion alarm | infra `vault.tf` | me → PR, Adebayo applies | — |
| 4 | Vault policy + k8s role `vault-snapshot`; CronJob; `VaultSnapshotMissing` alert | Vault CLI (Adebayo) · gitops | me writes | 3 |
| 5 | Restore drill scripts + runbook; run once (Vault scratch + RDS PITR) | infra `scripts/`, `runbooks/RESTORE_DRILL.md` | me writes, Adebayo runs | 4 |
| 6 | Cloudflare Access apps ×4 (+ AUDs), GitHub webhook bypass | Cloudflare console | Adebayo (click-path from me) | — |
| 7 | forward-auth verifier + Traefik Middleware; apply to jenkins/sonar; then Ingresses for prometheus/alertmanager | gitops | me → PR | 6 |
| 8 | Vault provider: import live objects, plan = 0 changes; retire runbook | infra `vault-config.tf` | me → PR, Adebayo runs imports/plan | — |
| 9 | Sleep/wake: healthchecks pause; full rehearsal | infra scripts | me → PR, Adebayo runs | — |
| 10 | SOP, checklist, overview; Phase 10 closes the build | docs | me → PR | all |

Lanes now: 1 ‖ 2 ‖ 3 ‖ 6 ‖ 8 ‖ 9. Rollback per task: 1 revert the addon value (nodes roll back
on the next apply); 7 remove the middleware from the Ingress; 8 `terraform state rm` the imports.
