locals {
  # ADR-018: the cluster is organisation-scoped. Products are namespaces within it,
  # so naming it for one product would be wrong the moment a second one arrives.
  cluster_name = "${var.organisation}-${var.environment}"

  # Karpenter discovers subnets and security groups by tag rather than by id,
  # so it can provision nodes without Terraform knowing about them.
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

################################################################################
# Network
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = var.availability_zones

  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true # ADR-004: accepted single point of failure, ~$33/mo saved
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Kubernetes finds subnets for load balancers through these tags.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.cluster_name
  }

  tags = local.tags
}

# Free, and removes NAT data-processing charges for ECR layer pulls,
# which are the dominant NAT traffic in a Kubernetes cluster.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags              = merge(local.tags, { Name = "${local.cluster_name}-s3" })
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint so we can reach the API from a laptop; private access stays on
  # so in-cluster traffic never leaves the VPC. Phase 10 restricts the public CIDRs.
  endpoint_public_access  = true
  endpoint_private_access = true

  # Finding ④: without this, only the creating principal can ever reach the cluster.
  # API_AND_CONFIG_MAP keeps the legacy aws-auth ConfigMap working for anything
  # that still expects it, while access entries become the reviewable source of truth.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Finding ⑤: without vpc-cni pods get no IPs, without coredns nothing resolves,
  # and without the EBS CSI driver no PersistentVolume ever binds — which would
  # silently break Prometheus, Grafana, Vault and Redis.
  addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    aws-ebs-csi-driver = {
      # The controller calls EC2 to create and attach volumes, so it needs an
      # AWS identity. enable_irsa below creates the OIDC provider - the trust
      # anchor - but grants nothing on its own. Without this association the
      # controller crash-loops on "no EC2 IMDS role found" and the add-on never
      # reaches ACTIVE.
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # Finding ⑤: the OIDC provider that makes IRSA possible at all.
  enable_irsa = true

  eks_managed_node_groups = {
    # ADR-003/012: this group exists only to break Karpenter's chicken-and-egg —
    # Karpenter is a Kubernetes controller and cannot provision the node it runs on.
    system = {
      instance_types = [var.system_node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = var.system_node_min
      max_size     = var.system_node_max
      desired_size = var.system_node_desired

      labels = { "node-role" = "system" }
    }
  }

  tags = merge(local.tags, {
    # Karpenter finds the cluster security group through this tag.
    "karpenter.sh/discovery" = local.cluster_name
  })
}

################################################################################
# EBS CSI driver identity
################################################################################

# Pod Identity rather than IRSA: the trust policy is a fixed two-line document
# instead of an OIDC condition that has to name the exact cluster issuer, and
# it survives cluster recreation. IRSA remains available for workloads whose
# Helm charts only support it.
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

################################################################################
# Karpenter — IAM, SQS interruption queue, node role (ADR-012)
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # Karpenter handles spot interruption natively through this queue,
  # which replaces the AWS Node Termination Handler entirely.
  enable_spot_termination = true

  # Pod Identity is simpler than IRSA for Karpenter itself and is what the
  # module now defaults to; application workloads still use IRSA.
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

################################################################################
# Container registry
################################################################################

resource "aws_ecr_repository" "api" {
  name = "${var.project}-api"

  # Finding ⑪: mutable tags mean "we deployed v1.2.3" stops being verifiable
  # and rollback becomes unreliable.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_repository" "web" {
  name                 = "${var.project}-web"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# Untagged images accumulate on every build and are pure cost.
resource "aws_ecr_lifecycle_policy" "expire_untagged" {
  for_each   = { api = aws_ecr_repository.api.name, web = aws_ecr_repository.web.name }
  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
      action       = { type = "expire" }
    }]
  })
}
