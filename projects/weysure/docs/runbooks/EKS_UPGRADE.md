# Runbook — EKS minor version upgrade (one hop)

Spec: [2026-09-14-eks-upgrade-1.36](../specs/2026-09-14-eks-upgrade-1.36.md).
Working directory for Terraform: `projects/weysure/terraform`. Profile `beyric-admin`.

## 0. Preconditions
- No Jenkins build running (`jenkins.beyrictech.com` queue empty).
- Vault PDB absent: `kubectl get pdb -n vault` → No resources found.
- Insights pass for the target: `aws eks list-insights --cluster-name beyric-prod`.

## 1. Change
`terraform.tfvars`: `kubernetes_version = "1.3X"` via PR. Merge.

## 2. Plan (read, then paste the summary)
```bash
terraform plan -out=tfplan
```
Expect `Plan: 0 to add, N to change, 0 to destroy`. Any `destroy` → stop.

## 3. Apply
```bash
terraform apply tfplan
```
~20–25 min. Watch in a second terminal:
```bash
watch -n 20 'kubectl get nodes -L node-role; kubectl get pods -n vault; kubectl get app -n argocd | grep -v "Synced *Healthy"'
```

## 4. Verify
```bash
aws eks describe-cluster --name beyric-prod --query 'cluster.[version,status,upgradePolicy.supportType]' --output text
kubectl get nodes -o custom-columns=N:.metadata.name,V:.status.nodeInfo.kubeletVersion,ROLE:.metadata.labels.node-role
aws eks list-addons --cluster-name beyric-prod --output text
kubectl exec -n vault vault-0 -- vault status | grep -E 'Sealed|HA Mode'
kubectl get app -n argocd
curl -s -o /dev/null -w '%{http_code}\n' https://weysure-api.beyrictech.com/api/v1/health
```

## 5. If the node group update stalls
`aws eks describe-update` shows `PodEvictionFailure` → a PDB is blocking:
`kubectl get pdb -A` → fix the budget → `terraform apply` again.
