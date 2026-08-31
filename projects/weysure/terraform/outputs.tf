output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_oidc_issuer_url" {
  description = "The IRSA trust anchor. Every pod-level IAM role's trust policy references this."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "Passed to any module creating an IRSA role in later phases."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "karpenter_node_iam_role_name" {
  description = "Referenced by the Karpenter EC2NodeClass in Phase 2."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  description = "SQS queue Karpenter watches for spot interruption notices."
  value       = module.karpenter.queue_name
}

output "ecr_api_url" {
  value = aws_ecr_repository.api.repository_url
}

output "ecr_web_url" {
  value = aws_ecr_repository.web.repository_url
}

output "configure_kubectl" {
  description = "Credentials come from AWS_PROFILE in the environment (ADR-017)."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
