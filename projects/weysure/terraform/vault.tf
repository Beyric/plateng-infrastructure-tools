################################################################################
# Vault — KMS auto-unseal key
#
# Vault boots SEALED. Its storage is encrypted with a master key that Vault
# itself cannot read until it is unsealed. Without auto-unseal, every restart
# requires a human to enter 3-of-5 Shamir key shares by hand — which is the
# single most common cause of self-hosted Vault outages, because it turns any
# pod eviction, node replacement or spot reclaim into a manual intervention.
#
# With awskms seal, Vault asks KMS to decrypt its master key at startup and
# unseals itself. This is why ADR-007 calls auto-unseal non-negotiable.
################################################################################

resource "aws_kms_key" "vault_unseal" {
  description             = "Vault auto-unseal — ${local.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.tags, { Name = "${local.cluster_name}-vault-unseal" })
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${local.cluster_name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

################################################################################
# Vault — Raft snapshot destination
#
# Backing up Vault is our job, not AWS's. Raft keeps its data on a PVC; if that
# volume is lost, every secret goes with it. A CronJob ships snapshots here.
################################################################################

resource "aws_s3_bucket" "vault_snapshots" {
  bucket = "${var.organisation}-vault-snapshots-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "vault_snapshots" {
  bucket = aws_s3_bucket.vault_snapshots.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "vault_snapshots" {
  bucket                  = aws_s3_bucket.vault_snapshots.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_snapshots" {
  bucket = aws_s3_bucket.vault_snapshots.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

# Snapshots older than 30 days are noise; the useful ones are recent.
resource "aws_s3_bucket_lifecycle_configuration" "vault_snapshots" {
  bucket = aws_s3_bucket.vault_snapshots.id
  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

################################################################################
# Vault — pod identity
#
# The Vault pod assumes this role through its ServiceAccount. No access keys
# exist anywhere; the eks-pod-identity-agent (installed in Phase 1) brokers it.
################################################################################

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "vault_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vault" {
  name               = "${local.cluster_name}-vault"
  assume_role_policy = data.aws_iam_policy_document.vault_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "vault" {
  # Exactly the four actions the awskms seal needs. Not kms:*.
  statement {
    sid       = "AutoUnseal"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [aws_kms_key.vault_unseal.arn]
  }

  statement {
    sid       = "SnapshotWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.vault_snapshots.arn, "${aws_s3_bucket.vault_snapshots.arn}/*"]
  }
}

resource "aws_iam_role_policy" "vault" {
  name   = "vault-unseal-and-snapshot"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.vault.json
}

resource "aws_eks_pod_identity_association" "vault" {
  cluster_name    = module.eks.cluster_name
  namespace       = "vault"
  service_account = "vault"
  role_arn        = aws_iam_role.vault.arn
}
