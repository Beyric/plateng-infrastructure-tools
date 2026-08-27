# SOP — Cost controls and state-backend hardening (Task 8)

## What shipped

Documentation only this pass: `projects/weysure/docs/runbooks/COST_CONTROLS.md`. It records
the verified state-backend controls, explains S3 native locking vs. the old DynamoDB lock
table, and hands Adebayo the exact `aws budgets create-budget` command and JSON payload
($250/mo, alerts at ACTUAL 50%/80% and FORECASTED 100%, notifying `<your-alert-email>`).

Two things this task set out to prove — the budget existing, and a live `terraform plan`
exercising the S3 backend end to end — are **not yet done**. Both require a human step; see
"Follow-ups."

## Why

Task 8 is Phase 0's last gate before Phase 1 is allowed to spend money: a cost ceiling with
alerting, and proof the Terraform state backend (S3 bucket + native lock file) works before
anything real depends on it.

## How

- Confirmed Steps 1–2 of the brief (bucket exists, versioning `Enabled`, all four
  public-access-block settings `true`, encryption `AES256`) were already verified by Adebayo —
  not repeated.
- Confirmed `projects/weysure/terraform/versions.tf` declares `use_lockfile = true` and no
  `profile` argument (ADR-017), and that the installed toolchain (`terraform v1.15.8`) meets
  the `>= 1.10` floor `use_lockfile` needs.
- Attempted the Step 9 dry run (`export AWS_PROFILE=beyric-admin && terraform init`) and hit a
  hard blocker — see "What's involved."
- Wrote `COST_CONTROLS.md` covering the verified backend controls, the prepared-but-not-run
  budget command, an explanation of S3 native locking, the expected steady-state cost table,
  the alert-triage procedure, and cost levers — all carried over from the brief's template,
  adapted to show real vs. pending state honestly rather than asserting completion.

## What's involved

- `projects/weysure/docs/runbooks/COST_CONTROLS.md` — new.
- `projects/weysure/terraform/versions.tf` — read only, not modified (backend/locking config
  already correct from Task 4/ADR-017).
- No AWS resources created or modified this pass. No Terraform state written.

## The blocker: SSO session expired mid-task

`beyric-admin` has a 1-hour IAM Identity Center session duration. The cached SSO OIDC token
(`~/.aws/sso/cache/afb9d1dc*.json`) expired at `2026-08-27T19:18:55Z`; `terraform init` was
attempted at `19:27Z`, ~9 minutes later, and failed:

```
Error: failed to refresh cached credentials, refresh cached SSO token failed,
unable to refresh SSO token, operation error SSO OIDC: CreateToken ...
InvalidGrantException: ...
```

`aws sts get-caller-identity --profile beyric-admin` kept working at the same time because the
AWS CLI was still serving a separately cached short-lived STS credential from earlier in the
session; Terraform's Go SDK refreshes against the SSO OIDC token cache directly and that one
had already expired. This will recur every time the 1-hour window lapses — it is not a one-off
fluke, and the fix is always the same: re-authenticate.

This blocked every remaining live AWS/Terraform step in Task 8 (budget verification, the
`terraform init`/`plan` dry run, confirming the `.tflock` object appears and clears). None of
them could be completed this session.

## Verification

- Read the live `versions.tf` and confirmed `use_lockfile = true`, no `profile` argument.
- Ran `terraform version` → `Terraform v1.15.8` (meets `>= 1.10`).
- Ran `terraform init` against the real bucket → failed on SSO token refresh (see above);
  captured the error verbatim in `COST_CONTROLS.md` and this SOP.
- Confirmed `git status --short` stayed clean throughout (no stray `terraform.tfvars` or
  `.terraform/` artifacts tracked).

## Operate / roll back

Nothing was applied; there is nothing to roll back. `terraform.tfvars` (copied from the
`.example` file, gitignored) and the local `.terraform/` provider cache are left in place in
`projects/weysure/terraform/` so Adebayo doesn't have to redo `terraform init`'s provider
download once SSO is refreshed — both are already excluded from git.

## Follow-ups (all human, all documented in `COST_CONTROLS.md`'s "Open items for Adebayo")

1. `aws sso login --profile beyric-admin` to refresh the session, then re-run
   `terraform init && terraform plan -out=/tmp/phase0-dryrun.tfplan` and confirm the `.tflock`
   object appears/clears in the bucket during the run. Record the outcome (resource counts or
   the verbatim error) — either is an acceptable result for Phase 0, nothing gets applied.
2. Run the `aws budgets create-budget` command in `COST_CONTROLS.md`, then verify with
   `describe-budgets` / `describe-notifications-for-budget`.
3. Once both land, update `COST_CONTROLS.md`'s "Dry-run status" and "Budget" sections with the
   real outcome and tick the matching lines in
   `projects/weysure/docs/checklist/BUILD_CHECKLIST.md` (`Cost guardrails` /
   `use_lockfile behaviour` / bucket policy restriction is Step 8 of the brief, `[HUMAN]`,
   still fully outstanding and not attempted this pass).
