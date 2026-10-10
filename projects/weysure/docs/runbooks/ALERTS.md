# Runbook — alerts

Every alert in `plateng-gitops/platform/monitoring/alerts.yaml` (Prometheus) and `loki-rules-jobs.yaml` / `loki-rules-wallet.yaml` (Loki ruler, log-based) links here. Critical → `#beyric-alerts-critical`
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
api, web or api-worker has fewer ready pods than desired for 10 min. `kubectl -n weysure-prod describe deploy <name>` and the pod
events: image pull (ECR), Kyverno admission, ResourceQuota exhausted, no workload node (see **NoWorkloadNode**), Vault
agent init failing (`-c vault-agent` logs).

Pods `ContainerCreating` with `failed to assign an IP address to container` = the node's subnet has no free address
block: [VPC_CNI_MODE_CHANGE.md](VPC_CNI_MODE_CHANGE.md) → *Recovery — a new node cannot start any pod* (Finding ㊺).
**If this alert resolves by itself, find out why before closing it** — it fired on 24 Sept, resolved, and came back on 29 Sept.

## Traefik5xxRateHigh
More than 2 % (critical: 10 %) of requests to a service are 5xx. `kubectl -n weysure-prod logs deploy/api -c api` for
tracebacks; correlate with the last promote commit in `images.yaml`; RDS alarms in CloudWatch. 502/504 with healthy
pods = readiness/timeout mismatch at Traefik.

## EdgeAuthDown
`edge-auth/access-verify` has no ready pod. Traefik fails closed: every host that carries the
`access-verify` middleware (SonarQube since 2026-10-02) answers 401/500 to everyone, logged in or not.
weysure and weysure-api are not behind it. `kubectl get pods -n edge-auth`; `kubectl logs -n edge-auth
-l app.kubernetes.io/name=access-verify --tail=20` — `keys-error` means it cannot reach
`beyric.cloudflareaccess.com` for the signing keys (NAT, DNS, NetworkPolicy). A logged-in user who is
refused shows as a `deny` line with the reason (`audience`, `expired`, `issuer`, `unknown key`).
To open the door while you fix it: remove the `router.middlewares` annotation from the Ingress (gitops
`bootstrap/apps/sonarqube.yaml`) — Cloudflare Access still protects the hostname.

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

## VaultSnapshotMissing
No successful run of CronJob `vault/vault-snapshot` (02:00 UTC) in 26 h. `kubectl get job -n vault`, then
`kubectl logs -n vault job/<name> -c snapshot` (Vault side) and `-c upload` (S3 side). Seen so far:
`invalid role name` = the Kubernetes-auth role is missing ([VAULT_CONFIG.md](VAULT_CONFIG.md)); `403` on login = wrong
ServiceAccount or audience; `AccessDenied` on upload = Pod Identity association `vault/vault-snapshot`. Expected after a
sleep longer than a day - the wake script starts a snapshot. Run one now:
`kubectl create job -n vault --from=cronjob/vault-snapshot vault-snapshot-manual-$(date +%s)`. Delete failed Jobs
afterwards or `KubeJobFailed` fires.

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
After a Vault outage: `kubectl get clustersecretstore vault` still `unable to create client` five minutes after Vault is
back → `kubectl rollout restart deploy/external-secrets -n external-secrets` (Finding ㊺). Secrets keep their last value meanwhile.

## KarpenterChurn
More than 6 node disruptions in an hour. `kubectl get events -A --field-selector reason=DisruptionBlocked,reason=Evicted`
and Karpenter logs (`kubectl -n kube-system logs deploy/karpenter | grep -i disrupt`). Consolidation too eager →
raise `consolidateAfter` in `platform/karpenter/nodepool.yaml`; drift → an AMI changed.

## NoWorkloadNode
No Karpenter node for 10 min. Expected while asleep. Otherwise Karpenter cannot launch: its logs, the NodePool
`limits` (sleep sets cpu 0 — did wake restore it?), spot capacity in both AZs, the EC2 spot service-linked role.

## JobsQueueLagging
From the Loki ruler, not Prometheus: the oldest overdue job in the Postgres `jobs` table has waited more than 5 min
(api-worker logs one `"event": "jobs_stats"` line a minute). Escrow timers (auto-release, deadlines, expiries, dispute
escalation) are running late. `kubectl -n weysure-prod get pods -l app.kubernetes.io/name=api-worker` (0 pods or
restarting → **DeploymentReplicasMissing** / KubePodCrashLooping first); `kubectl -n weysure-prod logs deploy/api-worker
-c api-worker --tail=50`: DB errors (Vault lease, RDS), Paystack/SMTP timeouts, or a single slow job. A hung worker is
restarted by liveness within ~6 min (heartbeat stops after 5 min without progress). Jobs are never lost: they wait in the
table. More replicas are safe (`SKIP LOCKED`) if the queue is just long.

## JobsDeadIncreased
From the Loki ruler: a job used all its attempts (`JOBS_MAX_ATTEMPTS`, default 8) and is now `dead`. It never runs again
by itself. Fires once per increase and clears after 10 min. The worker's log line before it says which job and why
(`kubectl -n weysure-prod logs deploy/api-worker -c api-worker --since=30m | grep -i dead`). Re-queue or cancel it with the
developers' jobs SOP, after fixing the cause. Critical because later job types move money: treat a dead payout or refund
as an incident and tell the developers.

## JobsStatsMissing
From the Loki ruler: no `"event": "jobs_stats"` line from api-worker for 15 min (+5 min `for`). Either the worker is
down (**DeploymentReplicasMissing** fires too), its loop is stuck (liveness should restart it within ~6 min: check
`kubectl -n weysure-prod get pods -l app.kubernetes.io/name=api-worker` restart count), or its logs are not reaching
Loki (Alloy down on that node: `kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy -o wide`). While asleep
this is expected and silenced by platform-sleep.sh.

## WalletLotDrift
From the Loki ruler (gitops `platform/monitoring/loki-rules-wallet.yaml`): a wallet reconciliation found users whose
open origin lots (`wallet_lots.remaining`) do not add up to `wallet_balance`. Logged as `{"event": "wallet_lot_drift",
"users": N}` by api-scheduler (every 30 min) or by api when an admin runs reconcile/repair. The value is N. Clears ~35 min
after the last drift line. Critical: while it fires, `ORIGIN_RULES_ENFORCED` must stay `"false"`.

**Never** run `repair_wallets` for this (it is ledger-only, never touches `wallet_balance` or lots) and never edit
`wallet_lots` by hand. There is no lot-repair tool; the developers ship an audited one if drift is real.

Triage (deploy artefact or bug?):
1. Find the window: PreSync `weysure-api-db-migrate` start → last new api/worker pod Ready of the latest
   wallet-touching rollout (Argo `weysure-api` operation history, pod `startTime`s).
2. Run the PII-free count (quoted heredoc so `$`/`!` survive; `created_at` is naive UTC; gitops on `main`):
   ```
   SQL=$(cat <<'EOF'
   WITH drift AS (SELECT u.id FROM users u LEFT JOIN (SELECT user_id, SUM(remaining) AS lots FROM wallet_lots GROUP BY user_id) l ON l.user_id = u.id WHERE COALESCE(l.lots, 0) <> CASE WHEN NULLIF(TRIM(u.wallet_balance), '') IS NULL THEN 0 WHEN TRIM(u.wallet_balance) ~ '^-?[0-9]{1,16}(\.[0-9]+)?$' THEN CAST(TRIM(u.wallet_balance) AS NUMERIC(18,2)) END),
        w AS (SELECT DISTINCT user_id FROM wallet_transactions WHERE created_at BETWEEN 'WINDOW_START_UTC' AND 'WINDOW_END_UTC')
   SELECT count(*) AS drifted, count(*) FILTER (WHERE d.id IN (SELECT user_id FROM w)) AS active_in_window, count(*) FILTER (WHERE d.id NOT IN (SELECT user_id FROM w)) AS no_activity_in_window FROM drift d
   EOF
   ) && scripts/db-oneoff.sh <api-tag> read "$SQL"
   ```
3. All drifted users `active_in_window` on the **first** run after a rollout → deploy artefact (old pods wrote between the
   backfill and the new pods): tell the developers, no page. Any `no_activity_in_window`, or any drift after one clean
   run → **bug**: page the backend owner.

## WithdrawalUnresolved
From the Loki ruler (gitops `platform/monitoring/loki-rules-withdrawals.yaml`): the worker re-checked a withdrawal with
Paystack `WITHDRAWAL_RECHECK_ALERT_AFTER_ATTEMPTS` times (3) and still cannot tell whether the transfer was sent. Logged
once per withdrawal as `{"event": "withdrawal_unresolved", "withdrawal_id": "..."}` by api-worker (Weysure-API #61). The
value is the number of such withdrawals in 30 min. The user's debit is held; the worker keeps re-checking up to
`WITHDRAWAL_RECHECK_MAX_ATTEMPTS` (10). **The alert resolves after 30 min; the withdrawal does not.**

**Never** re-send the transfer from the Paystack dashboard (double payment). Match in Paystack by reference
`wys_withdraw_<withdrawal_id>` (lowercase).

Triage:
1. Get the ids from Loki (Grafana Explore, or port-forward `svc/loki`):
   ```
   {namespace="weysure-prod", container=~"api|api-worker"} |= `"event": "withdrawal_unresolved"`
   ```
2. PII-free state per id (gitops on `main`; ids are not personal data):
   `scripts/db-oneoff.sh <api-tag> read "SELECT w.id, w.status, j.status AS job, j.attempts, j.outcome FROM withdrawals w LEFT JOIN jobs j ON j.kind = 'withdrawal.recheck' AND j.subject_id = w.id WHERE w.id IN ('<id>')"`
3. Paystack status page down → expected; the job keeps retrying, re-check later. Otherwise hand the ids to the backend
   owner: an admin settles it from the console (`/admin/withdrawals`), never by hand in SQL.

## WithdrawalRefundedByRecheck
Warning, from the same file: the worker refunded a withdrawal to the wallet because Paystack has no record of the
transfer. Logged as `{"event": "withdrawal_refunded_by_recheck", "withdrawal_id": "..."}`; value = refunds in 30 min.
Expected after a Paystack outage. The risk is a **double payment**: ask support whether any of these users was paid back
by hand. Ids: same Loki query with `withdrawal_refunded_by_recheck`. A burst (many refunds at once) means a Paystack or
network problem worth a look at `api-egress` and the Paystack status page.

## EKSEndOfStandardSupportApproaching
Static reminder from 2027-06-03: Kubernetes 1.36 leaves standard support on 2027-08-02 and the control plane then bills
at 6×. Run [EKS_UPGRADE.md](EKS_UPGRADE.md) one hop at a time before that date.

## MonitoringStackDegraded
Prometheus, Alertmanager, Grafana or Blackbox is down. `kubectl -n monitoring get pods`; PVC full
(`kubectl -n monitoring get pvc`); a system node roll. If **Prometheus** is down no other alert can fire — this is the
one to notice by its absence (dead-man's switch: follow-up, healthchecks.io ping on Watchdog). If **Loki** is down, the
log-based alerts (JobsQueueLagging, JobsDeadIncreased, JobsStatsMissing, WalletLotDrift, WithdrawalUnresolved,
WithdrawalRefundedByRecheck) cannot fire either.
