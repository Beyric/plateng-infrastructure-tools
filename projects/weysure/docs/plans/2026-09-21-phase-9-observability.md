# Phase 9 implementation plan

Spec: [2026-09-21-phase-9-observability.md](../specs/2026-09-21-phase-9-observability.md).

| # | Task | Repo / files | Owner | Depends |
|---|---|---|---|---|
| 1 | S3 bucket `beyric-loki-…` + Loki pod-identity role; 3 RDS CloudWatch alarms + SNS topic | infra `observability.tf` | me → PR, Adebayo applies | — |
| 2 | Vault: Grafana admin password (`secret/platform/grafana`); ESO scope for `monitoring` | Vault CLI / gitops `platform/monitoring/secrets` | Adebayo / me | — |
| 3 | kube-prometheus-stack (Prometheus 7 d/15 GB, Alertmanager→Slack, Grafana, default rules trimmed) on system nodes | gitops `bootstrap/apps/kube-prometheus-stack.yaml`, `platform/monitoring/` | me → PR | 2 |
| 4 | ServiceMonitors: Traefik, Argo CD, Vault, cert-manager, Karpenter, Kyverno, ESO, LBC (enable metrics in each chart's values) | gitops | me → PR | 3 |
| 5 | Blackbox + Probes (external through Cloudflare with allowed UA; internal Services); NetworkPolicy allow `monitoring` → api/web | gitops | me → PR | 3 |
| 6 | Loki single-binary (S3) + Alloy DaemonSet (stdout+stderr, namespace/pod labels); Grafana datasource | gitops | me → PR | 1, 3 |
| 7 | Alert rules (spec §5) + `ALERTS.md` runbook; Watchdog route; sleep-mode silence in `platform-sleep.sh` | gitops + infra docs/scripts | me → PR | 3–6 |
| 8 | Dashboards as ConfigMaps (spec §6) | gitops | me → PR | 3–6 |
| 9 | Cloudflare Zero Trust: team, IdP (one-time PIN or Google), Access app for `grafana.beyrictech.com`, policy by email | Cloudflare console | Adebayo (I give click-path) | — |
| 10 | Grafana ingress + `[auth.jwt]` against the Access certs; direct-to-origin test → 401 | gitops | me → PR | 3, 9 |
| 11 | DoD drills: scale web to 0 (alert fires/resolves), sleep/wake with silence | cluster | Adebayo, I watch | 7 |
| 12 | SOP, checklist, overview, developer note (app `/metrics`, Sentry: DSN in Vault + egress rule) | infra docs | me → PR | all |

Lanes: 1 ‖ 2 ‖ 9 run in parallel now; 3 unblocks 4–8; 10 needs 9.
Rollback: every component is its own Argo Application — delete the app manifest; PVCs are
`Delete`-reclaim so nothing lingers; S3 bucket survives (7-day lifecycle empties it).
