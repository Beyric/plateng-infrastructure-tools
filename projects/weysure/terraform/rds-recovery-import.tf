# 2026-10-08 database recovery: bring the restored instance under Terraform.
#
# Order (runbook RESTORE_DRILL.md -> "Real recovery"):
#   1. terraform state rm 'module.rds.module.db_instance.aws_db_instance.this[0]'
#      (the OLD instance leaves state only; AWS is not touched)
#   2. terraform plan  -> "1 to import", no destroy of any aws_db_instance
#   3. terraform apply
# Remove this block in a later PR once applied (import blocks are one-shot).
import {
  to = module.rds.module.db_instance.aws_db_instance.this[0]
  id = "weysure-postgres-v2"
}
