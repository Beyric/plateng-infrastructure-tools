# One-time adoption of the RDS log group that AWS created before Terraform owned it
# (retention was "never expire"). rds.tf now manages it with 30 days of retention.
#
# Terraform 1.5+ import blocks show up in `plan` as "will be imported", so the
# adoption is reviewable before apply. After the apply lands, this file can be
# deleted: an import block that has already run is a no-op.
import {
  to = module.rds.module.db_instance.aws_cloudwatch_log_group.this["postgresql"]
  id = "/aws/rds/instance/weysure-postgres-v2/postgresql"
}
