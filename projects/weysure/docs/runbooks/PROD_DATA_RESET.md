# Runbook — wipe the test data from production (keep only the owner's admin account)

**What this does, in plain words:** production still holds the testers' accounts, deals, wallets, ledger entries,
KYC and KYB records and partners from the time it ran on test keys. This one-off Job deletes all of it, **except**

- your admin account `beyrichq@gmail.com`, with its password, passkey, authenticator app and recovery codes
  (so you sign in and use the admin console exactly as before), and
- the settings the platform needs to run (fees, KYC limits, delivery timers, risk-hold rules, the database version).

It runs in **one transaction**: it finishes completely or changes nothing. The **dry run** does everything, shows you
the numbers, and then undoes it. **Run the dry run first, read it, then do the real one.**
What is kept and what is deleted, table by table, and the questions you should answer:
[SOP 2026-11-20](../sop/2026-11-20-prod-data-reset.md). Proof it works:
[evidence log](../evidence/2026-11-20-prod-data-reset-proof.txt).

> **This cannot be undone except from a backup.** That is why steps 1 and 2 come first and the script refuses to
> run the real reset without them. Do it before live Paystack/Dojah keys go in, never after real money has moved.

Everything below runs on your Mac. Per [HUMAN_GATED_COMMANDS](../../../../docs/conventions/HUMAN_GATED_COMMANDS.md)
nobody else runs these. Work from:

```bash
cd ~/Documents/Beyric/projects/plateng-infra/plateng-infrastructure-tools
```

## 0. Before you start (one time)

- The gitops PR with the Job ([plateng-gitops #110](https://github.com/Beyric/plateng-gitops/pull/110)) is **merged** and your gitops checkout is on `main`:
  `git -C ../plateng-gitops switch main && git -C ../plateng-gitops pull --ff-only`.
  (Merging it does **not** run anything: the file sits outside every path Argo CD watches.)
- You are signed in to AWS: `aws sso login --profile beyric-admin`; `kubectl config current-context` ends in `beyric-prod`.
- You have answered the open questions in the SOP (what happens to test-edited settings, other admins).

## 1. Take a fresh RDS snapshot (inside AWS)

```bash
aws rds create-db-snapshot --db-instance-identifier weysure-postgres-v2 \
  --db-snapshot-identifier weysure-pre-reset-$(date -u +%Y%m%d-%H%M) --profile beyric-admin --region us-east-1
```

Wait until it is `available` (a few minutes; use the same identifier the command printed):

```bash
aws rds wait db-snapshot-available --db-snapshot-identifier weysure-pre-reset-<the date-time you used> --profile beyric-admin --region us-east-1
```

**Expect:** the wait returns with no output. `aws rds describe-db-snapshots --db-snapshot-identifier <id> --query 'DBSnapshots[0].Status'`
says `"available"`.

## 2. Make sure a copy exists outside AWS

Preferred: run the nightly backup now ([DB_OFFSITE_BACKUP.md](DB_OFFSITE_BACKUP.md), step E; its setup PRs, `plateng-gitops` #108 and the docs branch `docs/prod-db-offsite-backup`, must already be merged and set up):

```bash
kubectl -n weysure-prod create job --from=cronjob/weysure-db-backup weysure-db-backup-prereset
```

After about a minute:

```bash
kubectl -n weysure-prod logs job/weysure-db-backup-prereset -c upload-retain | grep BACKUP_OK
```

**Expect:** a line `BACKUP_OK object=daily/weysure-….dump.age bytes=…` and the file in your Google Drive folder. Then clean up:
`kubectl -n weysure-prod delete job weysure-db-backup-prereset`.
If the backup is not set up yet, take a manual dump (restore steps in the same runbook) and tell the script so with
`OFFSITE_DUMP_DONE=yes` in step 4. The script also accepts a nightly backup that succeeded in the last 26 hours.

## 3. DRY RUN (changes nothing)

```bash
scripts/db-reset-prod.sh dry
```

It shows the Job, asks `Run the dry run? [y/N]`, type `y`. It waits (Vault login, then the SQL), then prints the output.

**Expect, in this order:**

1. `MODE: DRY RUN. Everything below runs, then ROLLS BACK.` and `guard passed: database weysure, 1 owner admin, N active second factor(s)`.
   If you see `REFUSED: …` instead, nothing was touched; the message says why (table below).
2. A table: for every table its **class** (`keep` / `owner` / `audit` / `wipe`) and **rows before / after**. Check that
   `admins` goes to **1**, `mfa_factors` goes to **your** factors (at least 1), every `wipe` table ends at **0**, every `keep` table is unchanged.
3. The values of the settings that stay (fees, limits, timers). **If any is a test value you don't want live, note it now and change it in the admin console after the reset** (nothing in this Job edits them).
4. Last line: `RESET_DRY_RUN_ROLLED_BACK: nothing was changed.`

## 4. The real run

Only after the dry run table looks right **and** steps 1 and 2 are done:

```bash
scripts/db-reset-prod.sh real
```

(`OFFSITE_DUMP_DONE=yes scripts/db-reset-prod.sh real` if you used a manual dump in step 2.)

The script checks, and refuses with the fix if any fails: a manual RDS snapshot younger than 6 hours and `available`; an off-AWS
backup in the last 26 hours (or your `OFFSITE_DUMP_DONE=yes`); a successful dry run in the last 24 hours. Then it asks you to type `RESET`.

**Expect:** the same table with the real result, then `RESET_COMMITTED: all other data is gone. Restart api-worker next`, then
`OK: job/db-reset-prod-v1-real-… completed`. A second `real` run prints `NOTHING_TO_RESET` and changes nothing.

## 5. Restart the worker (required)

The worker re-creates its recurring chores (wallet reconciliation, retention, DVA reconcile, auto-pause sweep, …) **only when it starts**, and the reset
emptied the `jobs` table. Without this step those chores silently stop.

```bash
kubectl -n weysure-prod rollout restart deployment/api-worker
kubectl -n weysure-prod rollout status deployment/api-worker
```

**Expect:** `successfully rolled out`. Then
`kubectl -n weysure-prod logs deployment/api-worker --since=5m | grep "startup sweep"` shows lines like
`[WORKER] startup sweep ensure_wallet_reconciliation: 1 job(s) scheduled` (about 20 sweeps).

## 6. Check it worked

| # | Check | Expect |
|---|---|---|
| 1 | `curl -s -o /dev/null -w '%{http_code}\n' https://api.weysure.com/api/v1/health` | `200` |
| 2 | Open the admin console, sign in as `beyrichq@gmail.com`, password, then your passkey or authenticator code | you are in. Every old session was ended on purpose, so a fresh sign-in is expected |
| 3 | Admin console dashboard | loads, with zeros: no users, deals, wallets |
| 4 | Admin → fee / escrow settings | the values the dry run showed |
| 5 | Open `weysure.com`, sign up a **new** test user with an email that is not yours | the signup works; the admin dashboard shows 1 user |
| 6 | `kubectl -n weysure-prod get pods` | api ×2, api-worker, web ×2 all `Running`, no restarts increasing |
| 7 | Optional exact counts (a read): `scripts/db-oneoff.sh <current api tag from gitops images.yaml> read "SELECT (SELECT count(*) FROM users) users, (SELECT count(*) FROM admins) admins, (SELECT count(*) FROM escrow_transactions) deals"` | `0`, `1`, `0` (1 if step 5 already ran) |

Then **delete the test signup** from step 5 only if you want a perfectly empty system (admin console, or leave it: it is harmless).

### Redis and sessions: what to clear

Nothing needs clearing. Sign-in sessions and refresh tokens live in Postgres (`auth_sessions`, `refresh_tokens`) and were emptied by the reset, so a
stale token of a deleted user can no longer be used (its session row is gone and its user no longer exists). Redis holds only counters that
expire by themselves: per-account sign-in backoff (at most 30 minutes, `login_backoff:*`), per-IP rate-limit buckets (about a minute),
DVA verify counters and the worker wake-up list. If you were locked out while testing (`429 LOGIN_LOCKED`) wait up to 15 minutes. If you
ever must clear it, restart Redis through gitops (a PR), never by running commands inside a production pod.

## When something is wrong

| You see | Meaning and what to do |
|---|---|
| `REFUSED: connected to database "X", this reset is for "weysure"` | wrong database. Stop and tell the platform owner |
| `REFUSED: expected exactly 1 admin with email …, found 0` (or 2) | the owner's admin is missing or duplicated. Nothing touched. Fix the admin row first |
| `REFUSED: the owner admin is not a superadmin / not active / has not set a password / has no confirmed second factor` | you would be locked out or lose power after the reset. Fix in the console (enrol a factor), then dry run again |
| `REFUSED: database user "…" lacks the privilege this reset needs on: …` | the Vault role used cannot truncate those tables (an owner mismatch). Nothing touched. Tell the platform owner |
| `REFUSED: tables not classified in this script: …` | a newer release added tables. Someone must classify them (PR) first |
| `ERROR: cannot truncate a table referenced in a foreign key constraint` | a table that stays now points at one that goes. Nothing was changed. Needs a code fix (PR) |
| `canceling statement due to lock timeout` | the app held a lock for 30 s. Nothing changed. Run the same command again |
| `POST-CHECK FAILED …` | the result did not match the promise, so the transaction was rolled back. Send the output to the platform owner |
| Job `Failed`, no output | `kubectl describe job <name> -n weysure-prod`; `kubectl logs -n weysure-prod job/<name> -c vault-agent-init` (Vault login) |
| You ran `real` by mistake or want it undone | restore the snapshot from step 1 into a new instance and repoint the app: [2026-10-08 database recovery SOP](../sop/2026-10-08-database-recovery.md), [RESTORE_DRILL.md](RESTORE_DRILL.md). Everything done after the reset is lost with it |

## What the reset cannot reach (do by hand, none of it is urgent)

The database stores only **references** to these, so deleting rows leaves them behind:

| Where | What is left | What to do |
|---|---|---|
| **Cloudinary** | test KYC/KYB documents, dispute evidence and chat attachments, stored privately under folders `weysure/kyc_enhanced_document/`, `weysure/kyb_document/`, `weysure/dispute_evidence/`, `weysure/chat_attachment/`, and profile images under `weysure/kyc/<user-id>/` | Cloudinary → Assets (Media Library) → open the `weysure` folder → delete those sub-folders (check first that your own admin profile picture is not inside; if it is, upload it again afterwards). If the Cloudinary account is shared with other projects, delete only the `weysure/` tree |
| **Paystack (test mode)** | test customers, test dedicated accounts, test transactions | harmless; test mode data cannot affect live. Leave it |
| **Paystack webhook settings** | the test webhook URL, if one is still set | Dashboard → Settings → API Keys & Webhooks: make sure only the URL you want for **live** is set when live keys go in |
| **Dojah (sandbox)** | sandbox lookups | nothing, sandbox only |
| **Vault** | `secret/weysure/*` values | leave. The reset never reads or changes Vault |
| **Email / SMS providers** | their own sent-message logs | nothing |
| **S3** | nothing: the app stores no user data in S3 | nothing |
| **The data you just removed still exists in backups** | the pre-reset RDS snapshot, RDS automatic backups (7 days), the off-AWS dump in Drive | they hold testers' personal data. Keep the pre-reset snapshot for 30 days in case you regret it, then delete it: `aws rds delete-db-snapshot --db-snapshot-identifier <id>`; delete the matching Drive file when you are sure |

## After it has run

The Job is kept for 7 days for its logs (`kubectl logs -n weysure-prod job/<name> -c reset`) and then deleted by Kubernetes. The audit table keeps one row,
`production_data_reset`, written by the owner admin, with the text "production data reset, kept 1 admin".
