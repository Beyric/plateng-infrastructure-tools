# Phase 9 - observability (spec 2026-09-21). Two things only AWS can provide:
# object storage for Loki, and alarms on the one component that is not in the
# cluster (RDS). Everything else is GitOps.

# ── Loki: chunks and index in S3 ─────────────────────────────────────────────
resource "aws_s3_bucket" "loki" {
  bucket = "${var.organisation}-loki-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Loki's compactor enforces the 7-day retention (spec D3). This rule is the
# backstop: nothing outlives 14 days even if the compactor is broken, and
# abandoned multipart uploads do not accumulate.
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration { days = 14 }
    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
}

data "aws_iam_policy_document" "loki" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.loki.arn]
  }
  statement {
    sid       = "Objects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }
}

resource "aws_iam_role" "loki" {
  name               = "${local.cluster_name}-loki"
  assume_role_policy = data.aws_iam_policy_document.vault_assume.json # pods.eks.amazonaws.com trust
  tags               = local.tags
}

resource "aws_iam_role_policy" "loki" {
  name   = "loki-s3"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki.json
}

resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "loki"
  role_arn        = aws_iam_role.loki.arn
  tags            = local.tags
}

# ── RDS: CloudWatch alarms -> SNS ────────────────────────────────────────────
# Three alarms cost nothing (first 10 are free) and need no exporter pod. The
# topic is subscribed to Slack by AWS Chatbot or a forwarder in a later task;
# until then the alarm state is visible in the console and via the CLI.
resource "aws_sns_topic" "platform_alerts" {
  name = "${local.cluster_name}-platform-alerts"
  tags = local.tags
}

locals {
  rds_alarms = {
    cpu-high = {
      metric    = "CPUUtilization", stat = "Average", op = "GreaterThanThreshold",
      threshold = 80, periods = 3, desc = "RDS CPU above 80% for 15 minutes"
    }
    storage-low = {
      metric    = "FreeStorageSpace", stat = "Minimum", op = "LessThanThreshold",
      threshold = 2147483648, periods = 1, desc = "RDS free storage below 2 GiB"
    }
    connections-high = {
      # db.t4g.micro: max_connections is about 85
      metric    = "DatabaseConnections", stat = "Maximum", op = "GreaterThanThreshold",
      threshold = 68, periods = 2, desc = "RDS connections above 80% of max_connections"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each            = local.rds_alarms
  alarm_name          = "${var.project}-rds-${each.key}"
  alarm_description   = each.value.desc
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  statistic           = each.value.stat
  comparison_operator = each.value.op
  threshold           = each.value.threshold
  period              = 300
  evaluation_periods  = each.value.periods
  treat_missing_data  = "notBreaching" # a stopped instance (sleep mode) is not an incident
  dimensions          = { DBInstanceIdentifier = module.rds.db_instance_identifier }
  alarm_actions       = [aws_sns_topic.platform_alerts.arn]
  ok_actions          = [aws_sns_topic.platform_alerts.arn]
  tags                = local.tags
}
