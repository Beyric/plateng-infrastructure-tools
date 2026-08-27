# SOP — Phase 0: Foundations & guardrails

**Shipped:** 2026-08-27 · **Branch:** `feature/phase-0-foundations` · **AWS spend: $0**

## What shipped

Every guardrail that has to exist *before* infrastructure does. No AWS resources were created
beyond an S3 state bucket and a budget — both free at this scale.

| Area | Outcome |
|---|---|
| **Identity** | AWS Organization `o-rl5xds5n7p`, IAM Identity Center `d-90667d5a87`, profile `beyric-admin`, **1-hour** sessions. Static access key deactivated. |
| **State** | `beyric-tfstate-767397877316` — versioned, AES256, public access fully blocked, S3 native locking. |
| **Cost** | Account-wide $250/mo budget, alerts at 50% / 80% actual and 100% forecast. |
| **Secrets** | Every credential rotated. gitleaks + pre-commit on both platform repos. A YAML-parsing hook blocks plaintext Kubernetes Secrets. |
| **IaC** | Terraform under version control, modules extracted, plaintext DB password eliminated, ECR set to `IMMUTABLE`. |
| **Governance** | Both platform repos public with active rulesets: PR required, no force-push, no deletion. `CODEOWNERS` on both. |

## Why

The original state: Terraform in an untracked directory containing a plaintext database
password, an EKS module that would lock out everyone but its creator, no secret scanning, and
AWS accessed through non-expiring static keys. Building on that would have meant rebuilding
later — infrastructure mistakes compound, because everything above them inherits them.

## Key decisions

| ADR | Decision |
|---|---|
| 014 | Phase order: GitOps and Secrets before Ingress — one bootstrap secret instead of three |
| 015 | State bucket renamed `beyric-tfstate-767397877316` while it held zero resources |
| 016 | SSO profiles named for the **account**, not the project — `beyric-admin` |
| 017 | **No `profile` in Terraform.** Credentials come from the environment, so the same config works on a laptop (`AWS_PROFILE`), in CI (IRSA) and break-glass (env vars) |

## What the guardrails caught

Not theoretical. During Phase 0 itself:

- **Three silently-broken gitleaks rules.** A `path` regex that never matched `.tf`; a
  `[rules.allowlist]` section gitleaks 8.x ignores entirely; and a `(?s)` missing its `m` flag.
  All produced green scans indistinguishable from a clean repository.
- **A total scanner bypass.** Eight ordinary annotations pushed `stringData` 897 characters past
  `kind: Secret`, and a real plaintext credential scanned clean — `no leaks found`, exit 0.
  Root cause was categorical: a regex cannot answer a structural question about nested data.
  Replaced with `scripts/no-plaintext-secrets.py`, which parses the YAML. 10/10 adversarial.
- **A `.gitignore` rule that silently deleted work.** `*-secret.yaml` excluded legitimate
  `ExternalSecret` manifests — never staged, never in `git status`, never reconciled, no error.
- **A hardcoded AWS profile** that would have broken Phase 6, where Jenkins uses IRSA and has no
  `~/.aws/config` at all.
- **`.env` committed across nine commits**, not one. `git log --diff-filter=A` reports only the
  first add and is blind to every later modification.

Every one of these fails *silently*, in the direction that looks like success. That is the
general lesson of this phase: a security control's failure mode almost always resembles working
correctly, so the only proof is making it fire on demand.

## Verification

- 18 commits, all pre-commit hooks passing.
- **0 gitleaks findings across full history** on both platform repos.
- Adversarial canaries for every scanner; both directions tested, not just detection.
- Branch rulesets confirmed active via `GET /repos/{repo}/rules/branches/main`.

## Rollback

Nothing to roll back — no infrastructure exists. Revert the branch and delete the S3 bucket and
budget, both free.

## Follow-ups

| Item | Where |
|---|---|
| Delete the deactivated access key after a clean SSO session | Task 7 |
| `terraform init` / `plan` dry-run against the real backend | Task 8 (blocked on SSO refresh) |
| Per-project budgets with `Project` tag filters | Once Phase 1 tags resources |
| Finding ⑱ — static `final_snapshot_identifier` collides on re-create | Phase 5 |
| Supabase history rewrite — recommended **against**; all credentials rotated | `SECRET_EXPOSURE_HISTORY.md` |
