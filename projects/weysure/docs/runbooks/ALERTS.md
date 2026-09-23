# Runbook — alerts

Every alert in `plateng-gitops/platform/monitoring/alerts.yaml` links here. Critical → `#beyric-alerts-critical`
(repeats every 4 h), warning → `#beyric-alerts-warning` (12 h). First move for anything red: `kubectl get app -n argocd`
and the Grafana **Cluster overview** dashboard. Kubernetes-level alerts (KubePodCrashLooping, KubeJobFailed,
KubeNodeNotReady, KubePersistentVolumeFillingUp) come from kube-prometheus-stack's defaults and follow the same channels.

## SiteDownExternal
The site fails from the internet. Check **SiteDownInternal** first: if it is *not* firing, the app is fine and the fault is
at the edge, in this order — `kubectl get pods -n traefik` (2 running?), `aws elbv2 describe-target-health` on the
`k8s-traefik-…` target groups (pod IPs healthy?), `kubectl get certificate -A` (Ready?), Cloudflare status page, DNS
(`dig +short <host> @1.1.1.1` → two Cloudflare IPs). During sleep mode this alert is silenced.

## SiteDownInternal
The Service does not answer inside the cluster: the application. `kubectl -n weysure-prod get pods` → restarts, Pending,
CrashLoop; `kubectl -n weysure-prod logs deploy/api -c api --tail=100`; a failed PreSync migration Job
(`kubectl -n weysure-prod get jobs`); Kyverno denial in `kubectl get events -n weysure-prod`. Roll back a bad release
with [DEPLOYMENT_ROLLBACK.md](DEPLOYMENT_ROLLBACK.md).

## DeploymentReplicasMissing
api or web has fewer ready pods than desired for 10 min. `kubectl -n weysure-prod describe deploy <name>` and the pod
events: image pull (ECR), Kyverno admission, ResourceQuota exhausted, no workload node (see **NoWorkloadNode**), Vault
agent init failing (`-c vault-agent` logs).

## Traefik5xxRateHigh
More than 2 % (critical: 10 %) of requests to a service are 5xx. `kubectl -n weysure-prod logs deploy/api -c api` for
tracebacks; correlate with the last promote commit in `images.yaml`; RDS alarms in CloudWatch. 502/504 with healthy
pods = readiness/timeout mismatch at Traefik.

## TLSCertExpiringSoon
cert-manager renews 30 days before expiry, so < 14 days means renewal is failing. `kubectl describe certificate <name>
-n <ns>` → the Order/Challenge events: Cloudflare token invalid (Vault `platform/cloudflare`), DNS-01 propagation, or
Let's Encrypt rate limit (5 duplicate certs/week). Critical at < 3 days: fix today.

## VaultSealed
Auto-unseal via KMS did not happen. `kubectl -n vault logs vault-0 | grep -i seal` → KMS permission (pod identity),
KMS key state, or the pod restarted on a node without the identity association. `kubectl exec -n vault vault-0 --
vault status`. Nothing that needs a credential works until this is fixed; existing pods keep running.

## VaultLeaseAnomaly
More than 100 leases. Normal is a few dozen (one per API pod + logins). `vault list sys/leases/lookup/auth/kubernetes/login`
and `…/database/creds/weysure-app`; a climbing count means a login loop (agent restarting) or revocation failing —
Finding ㊶, [VAULT_CONFIG.md](VAULT_CONFIG.md).

## ArgoAppDegraded
`kubectl get app <name> -n argocd -o yaml | grep -A5 conditions`; Degraded = a workload it owns is unhealthy (see the
pod), Missing = a resource was deleted out from under it (a sync recreates it).

## ArgoAppOutOfSync
Lasting OutOfSync with auto-sync on = the sync failed or a hook is blocked: `operationState.message` in the app status.
Expected while asleep (`karpenter-nodepools`, `weysure-prod`). `aws-load-balancer-controller` and `root` are excluded
(cosmetic webhook-cert diff).

## ExternalSecretNotReady
`kubectl describe externalsecret <name> -n <ns>` → the error: Vault path missing, policy lacks the path, Vault sealed,
or the ClusterSecretStore's auth role expired.

## KarpenterChurn
More than 6 node disruptions in an hour. `kubectl get events -A --field-selector reason=DisruptionBlocked,reason=Evicted`
and Karpenter logs (`kubectl -n kube-system logs deploy/karpenter | grep -i disrupt`). Consolidation too eager →
raise `consolidateAfter` in `platform/karpenter/nodepool.yaml`; drift → an AMI changed.

## NoWorkloadNode
No Karpenter node for 10 min. Expected while asleep. Otherwise Karpenter cannot launch: its logs, the NodePool
`limits` (sleep sets cpu 0 — did wake restore it?), spot capacity in both AZs, the EC2 spot service-linked role.

## EKSEndOfStandardSupportApproaching
Static reminder from 2027-06-03: Kubernetes 1.36 leaves standard support on 2027-08-02 and the control plane then bills
at 6×. Run [EKS_UPGRADE.md](EKS_UPGRADE.md) one hop at a time before that date.

## MonitoringStackDegraded
Prometheus, Alertmanager, Grafana or Blackbox is down. `kubectl -n monitoring get pods`; PVC full
(`kubectl -n monitoring get pvc`); a system node roll. If **Prometheus** is down no other alert can fire — this is the
one to notice by its absence (dead-man's switch: follow-up, healthchecks.io ping on Watchdog).
