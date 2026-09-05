################################################################################
# CI — Jenkins agent identity (Phase 6)
#
# Jenkins' only handoffs are an ECR push and a git commit (ADR-005). The push
# authenticates through pod identity on the agent ServiceAccount: no AWS keys
# exist anywhere in Jenkins, its configuration, or its credential store.
################################################################################

resource "aws_iam_role" "jenkins_agent" {
  name               = "${local.cluster_name}-jenkins-agent"
  assume_role_policy = data.aws_iam_policy_document.vault_assume.json # pods.eks.amazonaws.com
  tags               = local.tags
}

data "aws_iam_policy_document" "jenkins_agent" {
  # GetAuthorizationToken is account-scoped; ECR requires Resource = "*" for it.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push and pull on exactly the two application repositories. Not ecr:*.
  statement {
    sid    = "EcrPushPullAppRepos"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = [aws_ecr_repository.api.arn, aws_ecr_repository.web.arn]
  }
}

resource "aws_iam_role_policy" "jenkins_agent" {
  name   = "ecr-push-app-repos"
  role   = aws_iam_role.jenkins_agent.id
  policy = data.aws_iam_policy_document.jenkins_agent.json
}

# Namespace + ServiceAccount must match the Jenkins chart's
# serviceAccountAgent.name exactly. A mismatch fails with "no credentials",
# not with anything that names the association.
resource "aws_eks_pod_identity_association" "jenkins_agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = "jenkins"
  service_account = "jenkins-agent"
  role_arn        = aws_iam_role.jenkins_agent.arn
}
