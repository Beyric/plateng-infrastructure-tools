# SOP — Phase 9: Observability

**Shipped:** 2026-09-21 → 2026-09-23 · **PRs:** infra #30 (spec), #31, #32 · gitops #39–#49 ·
**Cost delta:** +≈$5/mo (23 GB gp3, S3 pennies); run-rate unchanged at **$13.0–13.3/day** · Spec:
[2026-09-21-phase-9-observability](../specs/2026-09-21-phase-9-observability.md) · Runbook:
[ALERTS.md](../runbooks/ALERTS.md)

## What shipped

| Piece | Where | Proof |
|---|---|---|
| **kube-prometheus-stack 91.4.1** — Prometheus 7 d / 13 GB cap on 15 GB gp3, Alertmanager, Grafana, operator; system nodes | gitops `bootstrap/apps/kube-prometheus-stack.yaml` | 57 targets, 0 down · 237 rules in 36 groups · 225 k active series |
| **Alertmanager config rendered by ESO from Vault** (Slack critical/warning, healthchecks receiver) | `platform/monitoring/secrets.yaml` | test alert in Slack (2026-09-23 14:50) |
| **ServiceMonitors** for Traefik, Argo CD ×5, Vault (telemetry stanza), cert-manager, Karpenter, Kyverno ×4, LBC, Reloader; PodMonitor for ESO | each chart's values · `platform/monitoring/podmonitor-external-secrets.yaml` | `vault_core_unsealed = 1` after the Vault pod restart |
| **Blackbox 11.18.0** — external through Cloudflare (browser UA), Grafana expects the Access 302, internal to the Services; NetworkPolicy monitoring → api/web | `bootstrap/apps/blackbox-exporter.yaml` · `platform/monitoring/probes.yaml` · `network/allow.yaml` | 7 probes `probe_success = 1`; TLS 62.7 d on all five certs |
| **18 platform alerts** in 6 groups on top of the stack's Kubernetes set; each with `runbook_url` | `platform/monitoring/alerts.yaml` | **drill:** web scaled to 0 for 4 m 21 s → SiteDownExternal + SiteDownInternal in `#beyric-alerts-critical` at 20:36, resolved 20:41 |
| **Dead-man's switch** — Watchdog → healthchecks.io ping URL (Vault) every minute | `secrets.yaml` receiver `healthchecks-watchdog` | healthchecks shows a POST from the NAT IP every ~2 min |
| **Loki 7.3.0** single-binary, S3 + pod identity, 7-day compactor retention; **Alloy 1.12.1** DaemonSet via the kubelet log API (stdout **and** stderr) | `bootstrap/apps/loki.yaml`, `alloy.yaml` · infra `observability.tf` | 13 namespaces in Loki; gunicorn's stderr "Booting worker" line queryable; 242 objects / 2.1 MB in S3 after 1 h |
| **Grafana** at `grafana.beyrictech.com` behind **Cloudflare Access + JWT validation at the origin**; Admin/Viewer by email | `kube-prometheus-stack.yaml` `grafana.ini [auth.jwt]` | direct-to-NLB `/api/org` → 401; forged JWT → 401; Adebayo Admin, developer Viewer |
| **Dashboards** — Weysure service (own, 14 panels) + 8 pinned community boards in a Platform folder + the stack's 25 | `platform/monitoring/dashboard-weysure-service.yaml` | 12/13 panels live (5xx ratio waits for a 5xx) |
| **RDS CloudWatch alarms** ×3 → SNS (free tier); **sleep silences Alertmanager**, wake expires it | infra `observability.tf` · `scripts/platform-*.sh` | alarms `OK`; amtool present in the pod |

Footprint: 15 pods, 142 m CPU, 1.85 Gi memory; system nodes at 56 % / 59 % memory.

## How it was reached — nine loops

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Vault target 403 after enabling telemetry | config-only change does not restart the Vault pod (Finding ㉖ again) | `kubectl delete pod vault-0` (auto-unseal); checksum annotation is a follow-up |
| 2 | Grafana unreachable from the Mac/browser | local negative DNS cache from before the record existed | flush; platform was fine |
| 3 | Drill produced no alert | **HPA** scaled web back up 3 s after `scale --replicas=0` | drill = delete HPA, scale, wait 4 min, restore, Argo sync |
| 4 | `NoWorkloadNode` fired non-stop | `(m or vector(0)) == 0` always appends a 0 series | `absent(m) or (m == 0)` |
| 5 | InfoInhibitor in Slack | my ESO-rendered config dropped the stack's `null` route for it | routes for `alertname=InfoInhibitor` and `severity=none` |
| 6 | EKS date rule rejected | scalar comparison needs `vector(time()) > epoch` | fixed; every expression now evaluated live before push |
| 7 | Alloy crash-loop | read-only rootfs, no volume for `storagePath` (Phase 7's `/app/logs` again) | emptyDir at `/tmp/alloy` |
| 8 | Alloy crash-loop | `;` is not a separator in Alloy's language | one attribute per line; **config parsed with `alloy fmt` before pushing** |
| 9 | Ping URL pasted as a markdown link, Vault token expired | terminal linkified the URL; token TTL | check recreated (URL was exposed), re-login, re-store |

## Findings

**㊷ — A system node is at 28/29 pods.** `KubeletTooManyPods` (info) fired the moment the stack
landed: m7g.large allows 29 pods under the VPC CNI's default ENI/IP maths, and the monitoring stack
pinned to the system nodes filled it. Memory is fine (59 %). Fix: **VPC CNI prefix delegation**
(`ENABLE_PREFIX_DELEGATION=true`) raises the limit to 110 — needs the node group rolled once (LBC
makes that zero-blip). Queued as the first Phase 10 infra PR.

**㊸ — Karpenter's pricing tables are 22 % of Prometheus.** `karpenter_cloudprovider_instance_type_
offering_{available,price_estimate}` = 49 k of 225 k series. Drop them with `metricRelabelings` on the
Karpenter ServiceMonitor (gitops follow-up).

**Also:** `probe_success` from a library user-agent is 403 at Cloudflare (browser UA in the module) ·
Loki rejects lines older than `reject_old_samples_max_age` on first start (one-minute burst of
`write operation failed`, expected) · Alertmanager does not log successful sends — Slack itself is
the evidence · healthchecks pings arrive every ~2 min (group interval), inside the 5-min grace.

## Open investigations (carried)

- Extra Vault credential render on 2026-09-18 18 min after the daily one — log retention starts
  today; watch for a repeat in Loki (`{namespace="weysure-prod", container="vault-agent"} |= "rendered"`).
- Karpenter "Underutilized" consolidation churning app pods — now measurable (`KarpenterChurn`,
  dashboard panel); tune `consolidateAfter` from a week of data.
- Laptop-only probe blips — external vs internal probes now separate them; none seen from the cluster.

## Deferred

Tracing (Tempo/OTel) · application `/metrics` and Sentry (developers: DSN in Vault + one egress rule
when they ask) · Access in front of Prometheus/Alertmanager/Jenkins/Sonar via forward-auth (Phase 10) ·
Vault chart config-checksum annotation · healthchecks pause from the sleep script (a sleep currently
shows one "down") · SNS → Slack for the RDS alarms (AWS Chatbot) · retention review at go-live (spec D3).

## Verification

`kubectl -n monitoring get pods` 15 Running · Prometheus targets 57/57 up · `probe_success` 7/7 ·
drill in Slack (above) · healthchecks Up · Grafana via Access (Admin/Viewer), direct-to-NLB 401 ·
Loki query for `container="api"` returns lines incl. stderr · dashboards render.

## Rollback

Each component is its own Argo Application: delete the manifest under `bootstrap/apps/`; PVCs are
`Delete`-reclaim. The S3 bucket and the RDS alarms are Terraform (`observability.tf`); removing the
bucket needs it emptied first (14-day lifecycle does that on its own).
