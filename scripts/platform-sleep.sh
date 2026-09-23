#!/usr/bin/env bash
# Put beyric-prod to sleep: keep every piece of state (Vault, RDS, PVCs, DNS, certs, NLB),
# stop everything that bills by the hour for compute. ~ $12.5/day -> ~ $4.5/day.
# The sites are DOWN while asleep. Only for the pre-launch period (no users).
# Runbook: projects/weysure/docs/runbooks/SLEEP_WAKE.md
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=beyric-prod; DB=weysure-postgres
ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
NG=$(aws eks list-nodegroups --cluster-name $CLUSTER --query 'nodegroups[0]' --output text)
read -r -p "Sleep $CLUSTER (sites go DOWN until platform-wake.sh)? type 'sleep': " a; [[ "$a" == "sleep" ]] || exit 1

echo "[0/5] silence Alertmanager for 12h so the shutdown does not fill Slack (persisted on its PVC; expires on its own)"
AM=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$AM" ]] && kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 silence add -a platform-sleep -d 12h -c "platform asleep (scripts/platform-sleep.sh)" 'alertname=~".+"' || echo "  (no Alertmanager found - continuing)"
echo "[1/5] stop Karpenter from provisioning (NodePool cpu limit 0)"
kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"0"}}}'
echo "[2/5] release the do-not-disrupt cache so its node can drain"
kubectl scale statefulset redis -n weysure-prod --replicas=0
echo "[3/5] remove Karpenter's spot nodes (while Karpenter is still alive to terminate them)"
kubectl delete nodeclaims --all --wait=true --timeout=10m || true
left=$(aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=running,pending" --query 'length(Reservations[].Instances[])' --output text)
[[ "$left" == "0" ]] || { echo "  $left Karpenter instance(s) still running - NOT scaling the system nodes down (Karpenter must stay up to remove them). Re-run."; exit 1; }
echo "[4/5] system node group -> 0"
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name "$NG" --scaling-config minSize=0,maxSize=2,desiredSize=0 >/dev/null
echo "[5/5] stop RDS (AWS restarts a stopped instance after 7 days)"
aws rds stop-db-instance --db-instance-identifier $DB --query 'DBInstance.DBInstanceStatus' --output text
echo "asleep. Wake with scripts/platform-wake.sh. Do not run 'terraform apply' while asleep: it would set the node group minimum back to 2."
