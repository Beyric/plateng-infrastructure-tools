# CD into the project dir, and init terraform
## 1. cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform && export AWS_PROFILE=beyric-admin && terraform init

## 2. terraform validate

# Upgrade init
## cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform && terraform init -upgrade
## terraform validate

## cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform && terraform plan -out=tfplan
## terraform show -json tfplan | python3 -c "import sys,json,collections; d=json.load(sys.stdin); c=collections.Counter(a['type'] for a in d['resource_changes'] if 'create' in a['change']['actions']); print(f'CREATE {sum(c.values())} resources'); [print(f'  {n:>3}  {t}') for t,n in c.most_common()]; print('DESTROY:', sum(1 for a in d['resource_changes'] if 'delete' in a['change']['actions']))"

## terraform show -json tfplan | jq -r '.resource_changes[] | select(.change.actions[0]=="create") | .type' | sort | uniq -c | sort -rn
## terraform show -json tfplan | jq -r '.resource_changes[] | select(.change.actions | index("delete")) | .address'
## terraform show -json tfplan | jq -r '.resource_changes[] | select(.type|test("nat_gateway|eks_cluster|db_instance|instance$")) | .address'
## terraform show -json tfplan | jq -r '.resource_changes[] | select(.type=="aws_eks_cluster") | .change.after | {version, name}'

# Apply
## cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform && terraform apply tfplan
## aws eks update-kubeconfig --region us-east-1 --name weysure-prod && kubectl get nodes -o wide && kubectl get pods -A

## cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform && export AWS_PROFILE=beyric-admin && terraform plan -out=tfplan -replace='module.eks.aws_eks_addon.this["aws-ebs-csi-driver"]'
## terraform apply tfplan
## kubectl get pods -n kube-system -l app=ebs-csi-controller
