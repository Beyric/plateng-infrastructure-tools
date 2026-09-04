################################################################################
# RDS PostgreSQL — Phase 5
#
# Created AFTER Vault (ADR-014) so the application is born with Vault-issued
# credentials and there is never a standing password to migrate away from.
################################################################################

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds"
  description = "PostgreSQL - reachable only from EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  # From the node security group, not the VPC CIDR. Anything else in the VPC -
  # a compromised NAT instance, a future bastion - still cannot reach Postgres.
  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  # RDS initiates nothing outbound; no egress rule is needed.
  tags = merge(local.tags, { Name = "${var.project}-rds" })
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10"

  identifier = "${var.project}-postgres"

  engine               = "postgres"
  engine_version       = "16"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50 # storage autoscaling ceiling - grows on demand, never shrinks
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.project
  username = "postgres"
  port     = 5432

  # ADR-010: RDS generates the master password into Secrets Manager. It is
  # never in this file, never in state, never in git. Terraform cannot read it
  # back - which is the point.
  manage_master_user_password = true

  multi_az = false # ADR-004: accepted; PITR gives RPO ~5min, RTO ~20min
  # Same private subnets as the worker nodes. A dedicated database subnet tier
  # adds isolation we do not need at this scale; the security group already
  # restricts ingress to the node SG alone.
  create_db_subnet_group = true
  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00" # UTC; quietest hour for West Africa
  maintenance_window      = "Sun:04:00-Sun:05:00"
  copy_tags_to_snapshot   = true

  deletion_protection = true
  # Finding ⑱ is closed by the module itself: it names the final snapshot
  # "<prefix>-<identifier>-<random hex>" using its own random_id, so a second
  # destroy/create cycle never collides with the previous snapshot.
  skip_final_snapshot = false

  # Ships Postgres logs to CloudWatch; the upgrade log is what you read when a
  # maintenance window breaks something.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true

  parameters = [
    # Force TLS. Vault and the app connect with sslmode=require, but this makes
    # a plaintext connection impossible rather than merely unlikely.
    # apply_method must be declared as pending-reboot: rds.force_ssl is a static
    # parameter in PostgreSQL 16, so AWS records it that way regardless of what
    # is sent. Leaving the module default (immediate) produces a perpetual
    # 1-change plan that never converges, which defeats the drift check.
    { name = "rds.force_ssl", value = "1", apply_method = "pending-reboot" },
  ]

  tags = local.tags
}

################################################################################
# Who may read the master password
################################################################################

# Vault's existing role (vault.tf) additionally reads the RDS master secret, to
# configure its database engine. After rotate-root, Vault alone knows the
# password it actually uses; the Secrets Manager copy remains break-glass.
resource "aws_iam_role_policy" "vault_rds_secret" {
  name = "vault-read-rds-master-secret"
  role = aws_iam_role.vault.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [module.rds.db_instance_master_user_secret_arn]
    }]
  })
}

# One-shot bootstrap Job: creates the `vault` role and the application
# database. Runs once, then the ServiceAccount does nothing.
resource "aws_iam_role" "db_bootstrap" {
  name               = "${local.cluster_name}-db-bootstrap"
  assume_role_policy = data.aws_iam_policy_document.vault_assume.json # same trust: pods.eks.amazonaws.com
  tags               = local.tags
}

resource "aws_iam_role_policy" "db_bootstrap" {
  name = "read-rds-master-secret"
  role = aws_iam_role.db_bootstrap.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [module.rds.db_instance_master_user_secret_arn]
    }]
  })
}

resource "aws_eks_pod_identity_association" "db_bootstrap" {
  cluster_name    = module.eks.cluster_name
  namespace       = "weysure-prod"
  service_account = "db-bootstrap"
  role_arn        = aws_iam_role.db_bootstrap.arn
}
