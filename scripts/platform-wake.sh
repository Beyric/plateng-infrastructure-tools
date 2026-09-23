#!/usr/bin/env bash
# Wake beyric-prod after platform-sleep.sh. ~10-15 minutes to all-green.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=beyric-prod; DB=weysure-postgres
ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
NG=$(aws eks list-nodegroups --cluster-name $CLUSTER --query 'nodegroups[0]' --output text)

echo "[1/5] start RDS"
st=$(aws rds describe-db-instances --db-instance-identifier $DB --query 'DBInstances[0].DBInstanceStatus' --output text)
[[ "$st" == "stopped" ]] && aws rds start-db-instance --db-instance-identifier $DB --query 'DBInstance.DBInstanceStatus' --output text || echo "  rds is '$st'"
echo "[2/5] system node group -> 2"
aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name "$NG" --scaling-config minSize=2,maxSize=2,desiredSize=2 >/dev/null
echo "[3/5] wait for two system nodes"
until [[ $(kubectl get nodes -l node-role=system --no-headers 2>/dev/null | grep -c ' Ready') -ge 2 ]]; do sleep 15; done
echo "[4/5] wait for Vault to auto-unseal and Karpenter to run"
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=10m
kubectl rollout status deploy/karpenter -n kube-system --timeout=10m
echo "[5/5] restore what sleep changed (values from git: plateng-gitops); expire the sleep silence"
AM=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$AM" ]] && for id in $(kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 silence query -q -a platform-sleep 2>/dev/null); do kubectl exec -n monitoring "$AM" -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 silence expire "$id"; done || true
kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"32"}}}'   # value in plateng-gitops platform/karpenter/nodepool.yaml
kubectl annotate app karpenter-nodepools weysure-prod -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null
kubectl scale statefulset redis -n weysure-prod --replicas=1
aws rds wait db-instance-available --db-instance-identifier $DB
echo "awake. Check: kubectl get app -n argocd ; curl -s -o /dev/null -w '%{http_code}\n' https://weysure-api.beyrictech.com/api/v1/health"
