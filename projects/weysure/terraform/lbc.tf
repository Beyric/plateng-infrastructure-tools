# AWS Load Balancer Controller (Phase 8, spec D1). Replaces the in-tree cloud
# provider for the Traefik NLB: pod-IP targets and readiness gates, so a node
# roll never leaves a terminated node registered (Finding 39).
#
# The controller runs as kube-system/aws-load-balancer-controller and gets its
# AWS permissions through EKS Pod Identity - the same mechanism as the EBS CSI
# driver and the Jenkins agents. The policy document is the upstream one for
# the pinned controller version; update lbc-iam-policy.json with the chart.

resource "aws_iam_policy" "lbc" {
  name        = "${local.cluster_name}-aws-load-balancer-controller"
  description = "AWS Load Balancer Controller v3.5.0 (upstream iam_policy.json)"
  policy      = file("${path.module}/lbc-iam-policy.json")
  tags        = local.tags
}

resource "aws_iam_role" "lbc" {
  name               = "${local.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.vault_assume.json # pods.eks.amazonaws.com trust
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
  tags            = local.tags
}
