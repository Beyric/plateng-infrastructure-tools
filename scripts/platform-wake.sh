#!/usr/bin/env bash
# Wake beyric-prod after platform-sleep.sh. ~20-25 minutes to all-green.
# Safe to run from any half-asleep state, and safe to run twice.
# Runbook: projects/weysure/docs/runbooks/SLEEP_WAKE.md
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=beyric-prod; DB=${DB:-weysure-postgres-v2}   # -v2 since the 2026-10-08 recovery
CHILD_APPS="karpenter-nodepools weysure-prod weysure-api weysure-web"
SAVED=beyric.io/sleep-automated
ROOT_DEFAULT='{"prune":true,"selfHeal":true}'     # plateng-gitops bootstrap/root-app.yaml
SITES="https://weysure-api.beyrictech.com/api/v1/health https://weysure.beyrictech.com/"

ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS session expired - run: aws sso login --profile $AWS_PROFILE"; exit 1; }
NG=$(aws eks list-nodegroups --cluster-name $CLUSTER --query 'nodegroups[0]' --output text)
amtool() { kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 "$@"; }

echo "[1/8] start RDS"
# A stopped instance has no hardware: starting asks AWS for capacity again, and on
# 2026-10-08 there was none for hours (InsufficientDBInstanceCapacity). Retry that
# for 20 min; any other failure, or still no capacity, stops HERE - before anything
# else is changed - instead of waiting forever in step 6.
st=$(aws rds describe-db-instances --db-instance-identifier $DB --query 'DBInstances[0].DBInstanceStatus' --output text)
if [[ "$st" == "stopped" ]]; then
  for i in $(seq 1 20); do
    if out=$(aws rds start-db-instance --db-instance-identifier $DB --query 'DBInstance.DBInstanceStatus' --output text 2>&1); then echo "  rds: $out"; break; fi
    if [[ "$out" == *InsufficientDBInstanceCapacity* && "$i" -lt 20 ]]; then echo "  no capacity for $DB yet (try $i/20) - retrying in 60 s"; sleep 60; continue; fi
    echo "  could not start $DB: $(echo "$out" | tail -1 | cut -c1-200)"
    echo "  Nothing has been changed."
    [[ "$out" == *InsufficientDBInstanceCapacity* ]] && echo "  AWS has no capacity for this instance class: SLEEP_WAKE.md -> 'RDS cannot start'."
    exit 1
  done
else
  echo "  rds is '$st'"
fi

echo "[2/8] system node group -> 2"
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name "$NG" --scaling-config minSize=2,maxSize=2,desiredSize=2 >/dev/null 2>&1 \
  || echo "  node group is busy with a previous update - continuing (it will be re-checked below)"

echo "[3/8] wait for two system nodes, Vault (auto-unseal), Karpenter, Argo CD"
until [[ $(kubectl get nodes -l node-role=system --no-headers 2>/dev/null | grep -c ' Ready') -ge 2 ]]; do sleep 15; done
until kubectl get pod vault-0 -n vault >/dev/null 2>&1; do sleep 5; done
# Vault's volumes are zonal: it fits on one system node only. If that node filled
# up before Vault was scheduled (first wake, 2026-10-01), say so instead of
# timing out silently. gitops gives Vault a priority class so this should not recur.
for i in $(seq 1 90); do
  kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=10s >/dev/null 2>&1 && break
  if (( i % 9 == 0 )) && [[ "$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}')" == "Pending" ]]; then
    echo "  vault-0 is still Pending: $(kubectl get events -n vault --field-selector involvedObject.name=vault-0,reason=FailedScheduling --sort-by=.lastTimestamp -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep 'nodes are available' | tail -1 | cut -c1-160)"
    echo "  if 'Insufficient cpu': runbook SLEEP_WAKE.md -> 'Vault cannot be scheduled on wake'"
  fi
  [[ "$i" == 90 ]] && { echo "  vault-0 not Ready after 15 min - stopping. Nothing below would work without Vault."; exit 1; }
done
echo "  vault-0 Ready"
kubectl rollout status deploy/karpenter -n kube-system --timeout=10m
kubectl rollout status deploy/argocd-server -n argocd --timeout=10m
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=10m

echo "[4/8] silence Alertmanager for 30m while everything converges"
AM=""
for i in $(seq 1 40); do
  AM=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$AM" ]] && amtool silence add -a platform-wake -d 30m -c "platform waking (scripts/platform-wake.sh)" 'alertname=~".+"' 2>/dev/null && break
  AM=""; sleep 15
done
[[ -n "$AM" ]] || echo "  Alertmanager not up after 10 min - continuing without a wake silence (expect alerts in Slack)"

echo "[5/8] wait until secrets can be fetched, then give the cluster back to git"
# The application's first sync step is an ExternalSecret. External Secrets started
# before Vault and keeps a dead client for a few minutes: a sync fired now fails,
# exhausts its retries, and Argo never retries the same commit by itself (API
# stayed at 0 pods for 45 min on 2026-10-01).
for i in $(seq 1 40); do
  [[ "$(kubectl get clustersecretstore vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && break
  [[ "$i" == 12 ]] && { echo "  secret store not ready after 3 min - restarting External Secrets (it holds a dead Vault client)"; kubectl rollout restart deploy/external-secrets -n external-secrets >/dev/null; }
  [[ "$i" == 40 ]] && { echo "  ClusterSecretStore 'vault' not Ready after 10 min - stopping before syncing the applications."; exit 1; }
  sleep 15
done
echo "  ClusterSecretStore vault: Ready"
kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"32"}}}'   # git value; the sync below is what makes it authoritative
saved=$(kubectl get app root -n argocd -o jsonpath="{.metadata.annotations.beyric\.io/sleep-automated}" 2>/dev/null || true)
kubectl patch app root -n argocd --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":${saved:-$ROOT_DEFAULT}}}}" >/dev/null
kubectl patch app root -n argocd --type merge -p '{"operation":{"sync":{}}}' >/dev/null
for i in $(seq 1 24); do
  paused=""; for app in $CHILD_APPS; do [[ -n "$(kubectl get app "$app" -n argocd -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)" ]] || paused="$paused $app"; done
  [[ -z "$paused" ]] && break; sleep 5
done
[[ -z "$paused" ]] && echo "  automated sync is back on root and on: $CHILD_APPS" \
  || { echo "  still paused after 2 min:$paused - root has not re-applied them. Look: kubectl get app root -n argocd -o yaml | tail -40"; exit 1; }
for app in $CHILD_APPS; do kubectl patch app "$app" -n argocd --type merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 || true; done
for app in root $CHILD_APPS; do kubectl annotate app "$app" -n argocd "$SAVED-" >/dev/null 2>&1 || true; done

echo "[6/8] wait for RDS"
aws rds wait db-instance-available --db-instance-identifier $DB

echo "[7/8] wait until every Argo app is Synced/Healthy and both sites answer 200 (up to 20 min)"
ok=0
for i in $(seq 1 80); do
  bad=$(kubectl get app -n argocd --no-headers 2>/dev/null | awk '$2!="Synced"||$3!="Healthy"{printf "%s ",$1}')
  codes=""; for u in $SITES; do codes="$codes$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u") "; done
  [[ -z "$bad" && "$codes" == "200 200 " ]] && { ok=1; break; }
  for app in $CHILD_APPS; do      # Argo does not retry a failed sync of the same commit by itself
    ph=$(kubectl get app "$app" -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
    if [[ "$ph" == "Failed" || "$ph" == "Error" ]]; then
      echo "  $app: last sync $ph - syncing again"
      kubectl patch app "$app" -n argocd --type merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 || true
    fi
  done
  (( i % 4 == 0 )) && echo "  sites: $codes| not ready: ${bad:-none}"
  sleep 15
done

echo "[8/8] snapshot if the last one is older than 20h, then lift the silences"
# The 02:00 schedule fires while asleep, finds no node, and fails at its deadline.
for j in $(kubectl get job -n vault -o json 2>/dev/null | python3 -c 'import sys,json; [print(j["metadata"]["name"]) for j in json.load(sys.stdin)["items"] if j["metadata"]["name"].startswith("vault-snapshot-") and any(c["type"]=="Failed" and c["status"]=="True" for c in j.get("status",{}).get("conditions",[]))]' || true); do
  kubectl delete job -n vault "$j" >/dev/null 2>&1 && echo "  removed failed job $j (ran while asleep)"
done
last=$(kubectl get cronjob vault-snapshot -n vault -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)
age=$(python3 -c "import sys,datetime as d; t=sys.argv[1]; print(int((d.datetime.now(d.timezone.utc)-d.datetime.fromisoformat(t.replace('Z','+00:00'))).total_seconds()//3600) if t else 999)" "$last")
if (( age >= 20 )); then kubectl create job -n vault --from=cronjob/vault-snapshot "vault-snapshot-wake-$(date -u +%Y%m%d%H%M%S)" >/dev/null && echo "  snapshot job started (last success ${age}h ago)"; else echo "  last snapshot ${age}h ago - fine"; fi
if [[ "$ok" == 1 && -n "$AM" ]]; then
  for id in $(amtool silence query -o json 2>/dev/null | python3 -c 'import sys,json; [print(s["id"]) for s in json.load(sys.stdin) if s.get("createdBy") in ("platform-sleep","platform-wake") and s["status"]["state"]=="active"]'); do amtool silence expire "$id"; done
  echo "awake: all apps Synced/Healthy, sites 200, silences lifted. healthchecks.io resumes on the next Watchdog ping (~5 min)."
else
  echo "NOT fully awake after 20 min. The wake silence is left to expire on its own (30m). Look: kubectl get app -n argocd"
  exit 1
fi
