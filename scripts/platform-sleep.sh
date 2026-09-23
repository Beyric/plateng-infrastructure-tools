#!/usr/bin/env bash
# Put beyric-prod to sleep: keep every piece of state (Vault, RDS, PVCs, DNS, certs, NLB),
# stop everything that bills by the hour for compute. ~ $13/day -> ~ $4.5/day.
# The sites are DOWN while asleep. Only for the pre-launch period (no users).
# Runbook: projects/weysure/docs/runbooks/SLEEP_WAKE.md
#
# GitOps rule (Finding 44): Argo CD re-applies git on every new commit, and
# karpenter-nodepools self-heals - so every change this script makes to the
# cluster is reverted within seconds unless the owning Applications have their
# automated sync switched OFF first. Wake switches it back on by re-syncing root.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=beyric-prod; DB=weysure-postgres
PAUSE_APPS="karpenter-nodepools weysure-prod weysure-api weysure-web"
ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
NG=$(aws eks list-nodegroups --cluster-name $CLUSTER --query 'nodegroups[0]' --output text)
read -r -p "Sleep $CLUSTER (sites go DOWN until platform-wake.sh)? type 'sleep': " a; [[ "$a" == "sleep" ]] || exit 1

echo "[0/7] silence Alertmanager for 12h (persisted on its PVC; expires on its own)"
AM=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$AM" ]] && kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 silence add -a platform-sleep -d 12h -c "platform asleep (scripts/platform-sleep.sh)" 'alertname=~".+"' || echo "  (no Alertmanager found - continuing)"

echo "[1/7] pause Argo CD automated sync on: $PAUSE_APPS"
for app in $PAUSE_APPS; do
  kubectl patch app "$app" -n argocd --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || echo "  $app: automated sync already off"
done

echo "[2/7] stop Karpenter from provisioning (NodePool cpu limit 0)"
kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"0"}}}'

echo "[3/7] scale the application to 0 (PDBs would otherwise block the last eviction; Redis carries do-not-disrupt)"
kubectl -n weysure-prod scale deploy api api-scheduler web --replicas=0
kubectl -n weysure-prod scale statefulset redis --replicas=0
kubectl -n weysure-prod wait --for=delete pod -l 'app.kubernetes.io/name in (api,api-scheduler,web)' --timeout=5m || true

echo "[4/7] remove Karpenter's spot nodes (while Karpenter is still alive to terminate them)"
kubectl delete nodeclaims --all --wait=true --timeout=10m || true
for i in $(seq 1 12); do
  left=$(aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=running,pending,shutting-down" --query 'length(Reservations[].Instances[])' --output text)
  [[ "$left" == "0" ]] && break; echo "  waiting: $left Karpenter instance(s) still terminating..."; sleep 15
done
[[ "$left" == "0" ]] || { echo "  $left Karpenter instance(s) still running - NOT scaling the system nodes down (Karpenter must stay up to remove them). Investigate: kubectl get nodeclaims; kubectl get events -A --field-selector reason=DisruptionBlocked"; exit 1; }

echo "[5/7] system node group -> 0"
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name "$NG" --scaling-config minSize=0,maxSize=2,desiredSize=0 >/dev/null

echo "[6/7] stop RDS (AWS restarts a stopped instance after 7 days)"
aws rds stop-db-instance --db-instance-identifier $DB --query 'DBInstance.DBInstanceStatus' --output text

echo "[7/7] asleep. Wake with scripts/platform-wake.sh. Do not 'terraform apply' while asleep (it sets the node group minimum back to 2)."
echo "  healthchecks.io will report the watchdog DOWN in ~5 min - expected while asleep."
