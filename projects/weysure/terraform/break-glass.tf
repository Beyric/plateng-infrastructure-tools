################################################################################
# Break-glass copies of secrets that can never be regenerated
#
# Vault is the source of truth for application secrets. Almost all of them can
# be reissued by the provider if Vault were lost. KYC_FINGERPRINT_KEY cannot:
# it is the HMAC key behind the one-identity-per-account check, and a different
# key would make every already-verified BVN/NIN look new. The developers' rule
# (platform note 2026-10-02): different per environment, never rotated.
#
# Vault's own protection is a daily snapshot, encrypted with one KMS key. This is
# a second copy that depends on neither: AWS Secrets Manager, next to Vault's
# recovery keys.
#
# Terraform creates the container only. The VALUE is never in Terraform, its
# state or git: it is piped from Vault by hand, once (runbooks/SECRETS_ROTATION.md).
################################################################################

resource "aws_secretsmanager_secret" "kyc_fingerprint_key" {
  name                    = "platform/weysure/prod/kyc-fingerprint-key"
  description             = "Break-glass copy of KYC_FINGERPRINT_KEY. Source of truth: Vault secret/weysure/prod. NEVER rotate, never delete."
  recovery_window_in_days = 30
  tags                    = local.tags

  lifecycle {
    prevent_destroy = true
  }
}
