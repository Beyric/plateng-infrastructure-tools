################################################################################
# RDS PostgreSQL for STAGING (weysure-stage namespace)
#
# A second, separate instance, never a second database on the production
# instance: a migration, a reset or a runaway query on stage must not be able to
# touch the production database. Mirrors rds.tf (encrypted, 7-day backups,
# single-AZ, deletion protection, TLS forced, RDS-managed master password, its
# own security group, subnet group and parameter group). Differences are listed
# in docs/sop/2026-11-20-staging-environment.md and are all deliberate:
#   - maintenance window is the day BEFORE production's, so an automatic minor
#     version upgrade lands on stage first;
#   - storage autoscaling ceiling 30 GB (production 50 GB).
#
# Nothing here is applied by an agent. Adebayo runs `terraform apply`
# (docs/conventions/HUMAN_GATED_COMMANDS.md); the exact commands are in
# docs/runbooks/STAGING_ENVIRONMENT.md.
################################################################################

variable "db_stage_instance_class" {
  description = "Stage database size. Same class as production so a query plan or a memory problem shows up on stage first; single-AZ."
  type        = string
  default     = "db.t3.micro"
}

locals {
  stage_tags = merge(local.tags, { Environment = "stage" })
}

resource "aws_security_group" "rds_stage" {
  name        = "${var.project}-stage-rds"
  description = "PostgreSQL (stage) - reachable only from EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  # Same rule as production: from the node security group, not the VPC CIDR.
  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  tags = merge(local.stage_tags, { Name = "${var.project}-stage-rds" })
}

module "rds_stage" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10"

  identifier = "${var.project}-stage-postgres"

  db_subnet_group_name = "${var.project}-stage-postgres"
  parameter_group_name = "${var.project}-stage-postgres"

  engine               = "postgres"
  engine_version       = "16"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = var.db_stage_instance_class

  allocated_storage     = 20
  max_allocated_storage = 30 # autoscaling ceiling: grows on demand, never shrinks
  storage_type          = "gp3"
  storage_encrypted     = true

  # The empty database is created here (owned by the RDS master), exactly as on
  # production; the bootstrap Job in gitops (stage/bootstrap) makes the vault
  # role and the group roles and grants.
  db_name  = var.project
  username = "postgres"
  port     = 5432

  # ADR-010: RDS generates the master password into Secrets Manager. Never in
  # this file, never in state, never in git.
  manage_master_user_password = true

  multi_az = false # same trade-off as production (ADR-004); stage data is disposable
  # Same private subnets as the worker nodes, as production.
  create_db_subnet_group = true
  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds_stage.id]
  publicly_accessible    = false

  backup_retention_period = 7
  backup_window           = "01:00-02:00" # UTC, must not overlap the maintenance window
  maintenance_window      = "Sat:03:00-Sat:04:00"
  copy_tags_to_snapshot   = true

  deletion_protection = true
  skip_final_snapshot = false

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true

  parameters = [
    # Force TLS (see rds.tf for why apply_method is pending-reboot).
    { name = "rds.force_ssl", value = "1", apply_method = "pending-reboot" },
  ]

  tags = local.stage_tags
}

################################################################################
# Bootstrap Job access: the stage db-bootstrap ServiceAccount may read the STAGE
# master secret and nothing else. It cannot read production's.
################################################################################

resource "aws_iam_role" "db_bootstrap_stage" {
  name               = "${local.cluster_name}-db-bootstrap-stage"
  assume_role_policy = data.aws_iam_policy_document.vault_assume.json # same trust: pods.eks.amazonaws.com
  tags               = local.stage_tags
}

resource "aws_iam_role_policy" "db_bootstrap_stage" {
  name = "read-rds-stage-master-secret"
  role = aws_iam_role.db_bootstrap_stage.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [module.rds_stage.db_instance_master_user_secret_arn]
      },
      {
        # The master secret's ARN carries a random suffix that does not exist until
        # the instance does, so the Job asks RDS for it by instance name instead of
        # having it pasted into git after the apply. One instance, one action.
        Effect   = "Allow"
        Action   = ["rds:DescribeDBInstances"]
        Resource = [module.rds_stage.db_instance_arn]
      },
    ]
  })
}

# The namespace + ServiceAccount pair must match gitops
# projects/weysure/environments/stage/namespace.yaml exactly.
resource "aws_eks_pod_identity_association" "db_bootstrap_stage" {
  cluster_name    = module.eks.cluster_name
  namespace       = "weysure-stage"
  service_account = "db-bootstrap"
  role_arn        = aws_iam_role.db_bootstrap_stage.arn
}

output "rds_stage_endpoint" {
  description = "host:port of the stage database. The api values and the bootstrap Job in gitops stage/ name this host."
  value       = module.rds_stage.db_instance_endpoint
}

output "rds_stage_master_secret_arn" {
  description = "Secrets Manager ARN of the stage master password (for reference; the bootstrap Job finds it through rds:DescribeDBInstances)."
  value       = module.rds_stage.db_instance_master_user_secret_arn
}
