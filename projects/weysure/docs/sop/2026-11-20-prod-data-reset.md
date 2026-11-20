# SOP — production data reset (`db-reset-prod-v1`): keep only the owner's admin account

**Status:** built and proven locally, **not run on production**. Prepared 2026-11-20; the owner runs it, after the
RDS snapshot and an off-AWS backup exist ([runbook](../runbooks/PROD_DATA_RESET.md)).
**Shipped as:** [plateng-gitops #110](https://github.com/Beyric/plateng-gitops/pull/110) `chore/prod-data-reset` (head `ed055001b12c`, the Job, outside every Argo path) and this repo's `docs/prod-data-reset` (script, runbook, harness, this SOP, evidence).
**Kind:** destructive one-off data tooling, no migration, no app change · **Cost delta:** $0 (a pre-reset RDS snapshot costs a few cents a month until deleted).

## Why

Production ran on test keys (Paystack test, Dojah sandbox), so it holds only testers' data. Before live keys go in, the owner decided
(2026-11-20): keep **only** his admin account `beyrichq@gmail.com` (with its second factors and whatever it needs to sign in and use the console) and
wipe everything else, so the first real user starts on an empty, honest system.

## What is kept and what is deleted (read this part)

The database has **72 tables**. Every one is classified in the script; the script **refuses to run** if it finds a table it does not know
(so a future release cannot add data that is silently kept or lost).

| Class | Tables | What happens |
|---|---|---|
| **KEEP** (6) | `alembic_version` (database version), `settings` (KYC threshold, DVA provider and card caps), `kyc_tier_limits` (the tier 0–3 limits), `delivery_method_settings` (the 4 delivery timers), `risk_hold_settings` (risk-hold rules), `escrow_settings` (the platform fee schedule) | rows stay **exactly** as they are. Migrations seed four of them; the fee schedule (`escrow_settings`) has **no seed** and exists only because an admin created it, so deleting it would lose your fees. Any "last edited by" pointer to an admin who is being deleted is cleared (set empty) so the row stays valid |
| **OWNER** (3) | `admins`, `mfa_factors`, `mfa_recovery_codes` | only **your** rows stay: your admin row (password hash, role, profile), **all** your second factors (authenticator app, passkeys) and your recovery codes. Every other admin, and every user's factor and recovery code, is deleted |
| **AUDIT** (1) | `admin_audit_logs` | everything deleted, then **one** new row `production_data_reset` by you, "production data reset, kept 1 admin". Earlier reset rows written by you (if it is ever run twice for real) are kept |
| **WIPE** (62) | `users`, `wallet_*` (wallet_transactions, wallet_lots, wallet_lot_allocations, wallet_holds), `escrow_transactions`, `escrow_transaction_history`, `withdrawals`, `manual_payout_requests`, `source_refunds`, `disputes`, `dispute_audit_logs`, `chargeback_*` (4), `account_freezes`, `dva_*` (dva_credits, dva_return_requests, dva_bvn_attempts), `dedicated_accounts`, `kyc_records`, `kyc_reviews`, `kyc_limit_overrides`, `identity_fingerprints`, `business_*` (profiles, documents, events, limits), `bank_accounts`, `bank_account_*` (2), `payout_account_*` (2), `payment_methods`, `partners`, `partner_*` (5), `deal_invites`, `ratings`, `messages`, `message_threads`, `notifications`, `admin_notifications`, `admin_notification_states`, `support_tickets`, `api_keys`, `usage_logs`, `webhooks`, `webhook_deliveries`, `developer_escrow_settings`, `security_audit_logs`, `risk_signal_sightings`, `otp_codes`, `mfa_challenges`, `mfa_recovery_requests`, `auth_sessions`, `refresh_tokens`, `trusted_devices`, `user_sessions`, `jobs` | every row deleted; ids restart from 1 |

The full list, one table per line, is the `INSERT INTO reset_class` block inside the Job (`projects/weysure/manual/prod/db-reset-prod-v1-job.yaml` in `plateng-gitops`).
Where admins live: a **separate `admins` table** (not `users` with a role). Your second factors are **not** foreign-keyed to it; they sit in `mfa_factors` and
`mfa_recovery_codes` keyed by `subject_type='admin'` and `subject_id`, which is why the OWNER class filters by that pair. Seventeen foreign keys point at `admins`; all sit in wiped tables
except `kyc_tier_limits`, `risk_hold_settings` (cleared first, above) and the audit row (which points at you).

### Decisions taken, and questions for the owner

| # | Decision (default taken) | Why | Your call |
|---|---|---|---|
| 1 | **Sessions and refresh tokens are wiped, including yours.** You sign in again after the reset | a deleted user's token could otherwise survive; a forced fresh sign-in is cheap | none needed |
| 2 | **`escrow_settings`, `settings`, `kyc_tier_limits`, `delivery_method_settings`, `risk_hold_settings` are kept as they are, test edits included** | wiping them would remove a fee schedule that has no seed, or reset limits you set | **Q1.** Were any of these changed for testing only (a tiny fee, a high limit)? The dry run prints every kept value; fix any you don't want in the admin console after the reset |
| 3 | **Every other admin is deleted**, including any QA or second superadmin | you said "keep only my admin account" | **Q2.** Is anyone else an admin who should survive (a developer, a support person)? If so say so now: the script keeps exactly one |
| 4 | **The audit trail is deleted** (security and admin audit logs, including yours) apart from the one reset row | it is test-time activity; a reset that kept it would keep tester emails and IPs | **Q3.** Do you want the old audit logs exported first (off-AWS backup already holds them)? |
| 5 | **`jobs` is wiped, so the worker must be restarted** (runbook step 5) | the table holds queued work about deleted users; the worker re-seeds its recurring chores only at start-up | none |
| 6 | The reset **refuses** unless your admin is `superadmin`, active, has set a password and has at least one confirmed second factor | otherwise the reset could leave you with no way in | none |
| 7 | **Your regular `users` account, if you ever had one with the same email, is wiped** | not an admin row | none; sign up a test user with a different email afterwards |
| 8 | **Ambiguous table?** None: all 72 decided. If a future release adds one, the script stops and lists it (default would be wipe) | fail closed | none |

## How

| Choice | Why, and what was rejected |
|---|---|
| **One psql script in one transaction** (`BEGIN … COMMIT`), embedded in a Kubernetes Job | a failure at any point leaves the database untouched. A **post-check** inside the transaction (kept tables unchanged, wiped tables empty, exactly the owner left) rolls back a real run that does not match its own promise |
| **`DRY_RUN=true` is the default and runs the identical statements, then `ROLLBACK`** | the owner sees the exact before/after numbers. Anything other than exactly `true`/`false` is refused before a transaction starts (a typo cannot turn a dry run into a real one) |
| **Guards first:** database name is `weysure`; exactly one admin with the owner's email (case-insensitive), active, superadmin, password set, ≥1 confirmed active factor; exactly one `alembic_version` row; **every table is classified**; every kept table exists; the database user holds TRUNCATE/DELETE/UPDATE on the tables it must change | the brief asked for guards on the database and the owner's row. The "unclassified table" guard is the main protection against a later migration changing what "everything" means |
| **Explicit `TRUNCATE` list, no `CASCADE`**, built from the classification table, echoed in the log before it runs | the brief suggested `… CASCADE`. Without `CASCADE`, if a kept table ever gets a foreign key to a wiped table, Postgres **refuses** (proven: `cannot truncate a table referenced in a foreign key constraint`, nothing changed); with `CASCADE` it would silently empty the kept table. Rejected: a dynamic "all tables" list (would catch `alembic_version`) |
| **Idempotent:** when there is nothing to delete, it prints `NOTHING_TO_RESET`, writes nothing (no second audit row), exits 0 | a re-run after a half-remembered first run is safe |
| **Identity = the migration's:** ServiceAccount `db-migrate`, Vault role `weysure-migrate` (30-minute credential, member of `weysure_owner`, which owns every table) | the API's own role `weysure_app` has DML only, so it **cannot** truncate (proven: the guard refuses it, `lacks the privilege`, before changing anything). The RDS master would work but is far more power than needed (the other bootstrap Jobs fetch it from Secrets Manager; this one never does). Least privilege that can do the job |
| **Job lives outside Argo's path** (`projects/weysure/manual/prod/`), applied by `scripts/db-reset-prod.sh`, never synced | Argo's `weysure-prod` app syncs `projects/weysure/environments/prod` **recursively and automatically**: a Job under `…/bootstrap/` (where the other one-shot Jobs sit) would run **the moment its PR merges**. For a data wipe, "merge = run" is unacceptable, so merging changes nothing in the cluster |
| **The script is the gate:** a real run refuses unless a manual RDS snapshot < 6 h old is `available`, a nightly off-AWS backup < 26 h old succeeded (or the owner states a manual dump), a dry run succeeded < 24 h ago, and the owner types `RESET` | turns the owner's two preconditions into checks the machine enforces |
| **Kyverno-compliant:** non-root 1000, read-only root filesystem, drop ALL, `RuntimeDefault` seccomp, requests and limits, image pinned by tag **and** digest (`postgres:16.16-alpine3.23@sha256:a23cda8e…`, the same image as the backup CronJob) | verified with the cluster's Kyverno CLI version (v1.19.1): 9 pass, 0 fail; kubeconform strict: valid |
| `backoffLimit: 0`, `activeDeadlineSeconds: 900`, `ttlSecondsAfterFinished: 604800` | a destructive Job is never retried by Kubernetes; logs kept a week (Loki keeps them too) |

## What's involved

| Where | What |
|---|---|
| `plateng-gitops` `projects/weysure/manual/prod/db-reset-prod-v1-job.yaml` | the Job: SQL embedded in `args`, DB URL from the Vault agent file (never printed), params `DRY_RUN` / `OWNER_EMAIL` / `EXPECT_DB` |
| `plateng-gitops` `projects/weysure/manual/prod/README.md` | why this directory is not synced |
| this repo `scripts/db-reset-prod.sh` | owner's wrapper: renders the Job (two substitutions), runs the safety checks, waits, prints the output |
| this repo `scripts/weysure-data-reset/` | `prove-local.sh` (the proof harness), `seed_sample_data.py` (rows in all 72 tables), `owner_signin_check.py` (the owner's real sign-in on the wiped database) |
| this repo `projects/weysure/docs/runbooks/PROD_DATA_RESET.md`, `…/evidence/2026-11-20-prod-data-reset-proof.txt` | the owner's steps; the captured proof |
| Production | read once by the Job (guards and counts), then written once (the reset). No config, flag, secret or migration changes |

## Verification (local, 2026-11-20; nothing was run against production)

`scripts/weysure-data-reset/prove-local.sh` on a throwaway `postgres:16.16-alpine3.23` (Docker), with the prod role layout (`weysure_owner` owns the tables,
`weysure_app` has DML, a Vault-style login user that switches into the owner role). The schema comes from a real `alembic upgrade head` of Weysure-API `de5e9d06ff92`
(head `c9e1f3a5b7d2`, 72 tables). The harness extracts the Job's own `args` script from the YAML and runs **that**, unchanged, in the Job's pinned image with
its security flags (non-root, read-only rootfs, drop ALL). **98 checks, all passed**; log: [evidence](../evidence/2026-11-20-prod-data-reset-proof.txt).

| Proved | How |
|---|---|
| All 72 tables hold sample rows (≈ 380), including 3 admins, 5 factors, config rows edited by another admin, an escrow fee row | seeder |
| **Dry run**: prints the per-table before/after table, exit 0, then **every table's row count identical**, no temp objects left | counts before/after |
| **Real run**: 62 wipe tables empty; owner admin row, **both** his factors (authenticator + passkey record) and his recovery codes, all config rows (apart from the cleared "edited by" pointers) and `alembic_version` **byte-identical**; exactly 1 admin; one audit row; every foreign key still validated; sessions and tokens gone | content hashes |
| **Second real run and a dry run after it**: `NOTHING_TO_RESET`, whole-database content fingerprint unchanged, still exactly one audit row | fingerprint |
| **The owner can sign in on the wiped database** through the app's own HTTP routes: password → second factor required (passkey, authenticator and recovery code offered) → TOTP accepted → `/admin/me` is the owner (superadmin) → dashboard, fee settings and analytics answer 200 → a brand-new user signs up → exactly 1 user → wrong password still refused → `/health` 200 | `owner_signin_check.py` (FastAPI TestClient, real Postgres) |
| **Guards refuse** (14 cases) and leave every row unchanged (content fingerprint equal): owner email missing; a fresh schema with no admin; wrong database name; `DRY_RUN=maybe` and empty; owner not superadmin; inactive; password pending; no confirmed factor; two admins with the owner's email; an unclassified table; a kept table with a foreign key to a wiped table; a table the database user cannot truncate; run as `weysure_app`. **Plus** one positive case: a stale reset record written by another admin does not block deleting that admin | `refuse()` cases |
| The existing API unit/integration test files were **not** run against the wiped database | they build their own database from the models (`create_all`) and insert their own rows, so they would prove nothing about the wiped data; the sign-in check above is the stronger test. No full suite, per the machine rule |

**Not proven, and why**

| Gap | Why |
|---|---|
| Run against real RDS `weysure-postgres-v2` | prod is human-gated; the dry run **is** the first live test and changes nothing |
| Vault credential flow, NetworkPolicy, Kyverno admission by the live cluster, Docker Hub pull from the node | mirrors the chart's migration Job and the backup CronJob's image; checked statically (`helm template` of the chart, Kyverno CLI v1.19.1 9/9, kubeconform). `DRY_SERVER=1 scripts/db-reset-prod.sh dry` makes the API server validate it |
| The prod data's own shape | prod holds testers' data; if it has a row the seeder could not imagine (e.g. an admin with a different role, two owner rows), the guards stop the run and say so |
| `rollout restart api-worker` re-seeding the chores | the sweep code was read, not run; the runbook checks the worker log for `startup sweep … scheduled` |
| Cloudinary clean-up | by hand, in the runbook |

## Operate / roll back

Run order, expected output and after-checks: [runbook](../runbooks/PROD_DATA_RESET.md). **Roll back** a committed reset only by restoring the pre-reset RDS snapshot (new instance, repoint) per the
[2026-10-08 recovery SOP](2026-10-08-database-recovery.md) or the off-AWS dump per [DB_OFFSITE_BACKUP.md](../runbooks/DB_OFFSITE_BACKUP.md); anything written after the reset is lost with it. A *failed* run commits nothing.
Retire the Job by deleting `projects/weysure/manual/prod/` in gitops once the reset has happened and the 30-day snapshot is deleted.

## Follow-ups

- Owner answers Q1–Q3 above before the real run.
- Delete the pre-reset RDS snapshot and Drive dump after 30 days (they hold testers' personal data).
- Clean the Cloudinary `weysure/` folders (runbook).
- If a migration adds a table before the reset runs, add it to the `reset_class` block (the Job refuses until then) and re-run `prove-local.sh`.
- Not covered: a Paystack/Dojah data-deletion request, and live-key cut-over itself (separate checklist).
