#!/usr/bin/env bash
# Wake beyric-prod after platform-sleep.sh. ~10-15 minutes to all-green.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=beyric-prod; DB=weysure-postgres
ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
NG=$(aws eks list-nodegroups --cluster-name $CLUSTER --query 'nodegroups[0]' --output text)

echo "[1/6] start RDS"
st=$(aws rds describe-db-instances --db-instance-identifier $DB --query 'DBInstances[0].DBInstanceStatus' --output text)
[[ "$st" == "stopped" ]] && aws rds start-db-instance --db-instance-identifier $DB --query 'DBInstance.DBInstanceStatus' --output text || echo "  rds is '$st'"
echo "[2/6] system node group -> 2"
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name "$NG" --scaling-config minSize=2,maxSize=2,desiredSize=2 >/dev/null
echo "[3/6] wait for two system nodes, Vault (auto-unseal), Karpenter, Argo CD"
until [[ $(kubectl get nodes -l node-role=system --no-headers 2>/dev/null | grep -c ' Ready') -ge 2 ]]; do sleep 15; done
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=10m
kubectl rollout status deploy/karpenter -n kube-system --timeout=10m
kubectl rollout status deploy/argocd-server -n argocd --timeout=10m
echo "[4/6] restore Karpenter capacity, then let git put everything back: re-sync root (restores the Applications' automated sync), then the paused apps"
kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"32"}}}'   # value in plateng-gitops platform/karpenter/nodepool.yaml
kubectl patch app root -n argocd --type merge -p '{"operation":{"sync":{}}}'
sleep 20
for app in karpenter-nodepools weysure-prod weysure-api weysure-web; do
  kubectl patch app "$app" -n argocd --type merge -p '{"operation":{"sync":{}}}' 2>/dev/null || true
done
aws rds wait db-instance-available --db-instance-identifier $DB
echo "[5/6] expire the sleep silence"
AM=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$AM" ]] && for id in $(kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 silence query -q 2>/dev/null); do kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 silence expire "$id"; done || true
echo "[6/6] awake. Check: kubectl get app -n argocd (all Synced/Healthy in ~5 min); curl -s -o /dev/null -w '%{http_code}\n' https://weysure-api.beyrictech.com/api/v1/health"
