#!/usr/bin/env bash
# Put beyric-prod to sleep: keep every piece of state (Vault, RDS, PVCs, DNS, certs, NLB),
# stop everything that bills by the hour for compute. ~ $13/day -> ~ $4.5/day.
# The sites are DOWN while asleep. Only for the pre-launch period (no users).
# Runbook: projects/weysure/docs/runbooks/SLEEP_WAKE.md
#
# GitOps rule (Finding 44): Argo CD owns the cluster. Every change this script
# makes is reverted within seconds unless automated sync is switched OFF first -
# and "root" (selfHeal: true) owns the child Applications, so pausing a child
# without pausing root is itself reverted. Root is paused FIRST, and the script
# proves the pause held before it changes anything else.
#
# If this script stops half-way for any reason: run platform-wake.sh. It returns
# the platform to the state in git from any intermediate state.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=beyric-prod; DB=weysure-postgres
PAUSE_APPS="root karpenter-nodepools weysure-prod weysure-api weysure-web"   # root first - order matters
SILENCE=${SILENCE:-12h}
SAVED=beyric.io/sleep-automated

ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS session expired - run: aws sso login --profile $AWS_PROFILE"; exit 1; }
NG=$(aws eks list-nodegroups --cluster-name $CLUSTER --query 'nodegroups[0]' --output text)
read -r -p "Sleep $CLUSTER (sites go DOWN until platform-wake.sh)? type 'sleep': " a; [[ "$a" == "sleep" ]] || exit 1

automated() { kubectl get app "$1" -n argocd -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null; }

# healthchecks.io: pause every check in the project so the dead-man's switch does
# not report DOWN all night. A paused check resumes by itself on the next ping,
# so wake needs no key. The key is never printed; curl reads it from stdin so it
# is not visible in the process list.
hc_pause() {
  [[ -n "${HC_KEY:-}" ]] || return 0
  local list
  list=$(printf 'header = "X-Api-Key: %s"\n' "$HC_KEY" | curl -s --max-time 15 --config - https://healthchecks.io/api/v3/checks/ \
    | python3 -c 'import sys,json; [print(c["name"] or "(unnamed)", c["pause_url"], sep="\t") for c in json.load(sys.stdin)["checks"]]' 2>/dev/null) || true
  [[ -n "$list" ]] || { echo "  healthchecks: could not list checks (key wrong or read-only?) - not paused"; return 0; }
  while IFS=$'\t' read -r name url; do
    code=$(printf 'header = "X-Api-Key: %s"\n' "$HC_KEY" | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST --data "" --config - "$url")
    echo "  healthchecks: '$name' pause -> HTTP $code"
  done <<< "$list"
}

echo "[1/10] Vault snapshot, and read the healthchecks key, while Vault is still up"
HC_KEY=${HC_API_KEY:-}
[[ -n "$HC_KEY" ]] || HC_KEY=$(kubectl exec -n vault vault-0 -- vault kv get -field=api_key secret/platform/healthchecks 2>/dev/null || true)
[[ -n "$HC_KEY" ]] && echo "  healthchecks key: loaded (${#HC_KEY} chars)" \
  || echo "  healthchecks key: NOT available (vault login expired, or secret/platform/healthchecks missing) - expect one DOWN notification"
J=vault-snapshot-sleep-$(date -u +%Y%m%d%H%M%S)
kubectl create job -n vault --from=cronjob/vault-snapshot "$J" >/dev/null
for i in $(seq 1 36); do
  c=$(kubectl get job "$J" -n vault -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
  [[ "$c" == *Complete* ]] && break
  [[ "$c" == *Failed* || "$i" == 36 ]] && { echo "  snapshot did not complete - NOTHING has been changed; aborting."; echo "  look: kubectl logs -n vault job/$J -c snapshot ; then: kubectl delete job -n vault $J"; exit 1; }
  sleep 5
done
kubectl logs -n vault "job/$J" -c upload --tail=1 | sed 's/^/  /'

echo "[2/10] silence Alertmanager for $SILENCE (this also stops the Watchdog pings to healthchecks.io)"
AM=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$AM" ]] && kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 silence add -a platform-sleep -d "$SILENCE" -c "platform asleep (scripts/platform-sleep.sh)" 'alertname=~".+"' || echo "  (no Alertmanager found - continuing)"

echo "[3/10] pause Argo CD automated sync, root first: $PAUSE_APPS"
for app in $PAUSE_APPS; do
  cur=$(automated "$app")
  if [[ -z "$cur" ]]; then echo "  $app: already paused"; continue; fi
  kubectl annotate app "$app" -n argocd --overwrite "$SAVED=$cur" >/dev/null
  kubectl patch app "$app" -n argocd --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null
  echo "  $app: paused (was $cur)"
done

echo "[4/10] prove the pause held for 45s (Argo reverts within seconds when it is going to)"
for i in 1 2 3; do
  sleep 15
  for app in $PAUSE_APPS; do
    [[ -z "$(automated "$app")" ]] || { echo "  $app has automated sync again - something re-applied it. Nothing is scaled down yet. Run platform-wake.sh, then investigate."; exit 1; }
  done
done
echo "  held"

echo "[5/10] stop Karpenter from provisioning (NodePool cpu limit 0)"
kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"0"}}}'

echo "[6/10] scale the application to 0 (PDBs would otherwise block the last eviction; Redis carries do-not-disrupt)"
kubectl -n weysure-prod scale deploy api api-scheduler web --replicas=0
kubectl -n weysure-prod scale statefulset redis --replicas=0
kubectl -n weysure-prod wait --for=delete pod -l 'app.kubernetes.io/name in (api,api-scheduler,web)' --timeout=5m || true
kubectl -n weysure-prod wait --for=delete pod/redis-0 --timeout=3m || true

echo "[7/10] remove Karpenter's spot nodes (while Karpenter is still alive to terminate them)"
kubectl delete nodeclaims --all --wait=true --timeout=10m || true
for i in $(seq 1 12); do
  left=$(aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=running,pending,shutting-down" --query 'length(Reservations[].Instances[])' --output text)
  [[ "$left" == "0" ]] && break; echo "  waiting: $left Karpenter instance(s) still terminating..."; sleep 15
done
[[ "$left" == "0" ]] || { echo "  $left Karpenter instance(s) still running - NOT scaling the system nodes down (Karpenter must stay up to remove them). Investigate: kubectl get nodeclaims; kubectl get events -A --field-selector reason=DisruptionBlocked. To go back: platform-wake.sh"; exit 1; }

echo "[8/10] pause healthchecks.io, then system node group -> 0"
hc_pause
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name "$NG" --scaling-config minSize=0,maxSize=2,desiredSize=0 >/dev/null

echo "[9/10] stop RDS (AWS restarts a stopped instance after 7 days)"
aws rds stop-db-instance --db-instance-identifier $DB --query 'DBInstance.DBInstanceStatus' --output text

echo "[10/10] wait until the cluster has no instances left (EKS drains first; PDBs on the last node make this take up to ~15 min)"
for i in $(seq 1 80); do
  left=$(aws ec2 describe-instances --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" "Name=instance-state-name,Values=running,pending,shutting-down,stopping" --query 'length(Reservations[].Instances[])' --output text)
  [[ "$left" == "0" ]] && break; (( i % 4 == 0 )) && echo "  $left instance(s) left..."; sleep 15
done
hc_pause   # again: a last ping from Alertmanager while the nodes drained would have resumed the check
[[ "$left" == "0" ]] && echo "asleep: 0 instances. Wake with scripts/platform-wake.sh." \
  || echo "WARNING: $left instance(s) still exist after 20 min - check the EC2 console; they are still billing."
echo "Do not 'terraform apply' while asleep (it sets the node group minimum back to 2)."
