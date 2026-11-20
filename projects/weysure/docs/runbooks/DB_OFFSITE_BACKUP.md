# Runbook — nightly off-AWS database backup (Google Drive)

**Why:** RDS keeps its own snapshots (7 days, inside AWS). This is the copy **you** hold outside AWS, so you can
move to another cloud at any time, or recover if the AWS account itself is lost, without losing data.

| | |
|---|---|
| What | `pg_dump` of database `weysure`, locked with your **public** key (age), uploaded to Google Drive |
| When | every night 02:30 UTC (03:30 Lagos): after the Vault snapshot (02:00), before the RDS window (03:00–04:00) |
| Where | your Google Drive, folder `weysure-db-backups`: `daily/` and `monthly/` |
| Kept | last **30 nightly** copies; the **first copy of each month for 12 months** |
| Who can open it | only the holder of the age **private key** (you). Not Google, not AWS, not us |
| Runs as | CronJob `weysure-prod/weysure-db-backup`; database login `weysure_backup` (read-only) |
| Alert | `WeysureDbBackupMissing`: no success in 26 h → [ALERTS.md](ALERTS.md#weysuredbbackupmissing) |
| Code | `plateng-gitops` `projects/weysure/environments/prod/backup/` + `network/allow.yaml` (`db-backup-egress`) |
| Secrets | Vault `secret/weysure/backup` (below). Never in git |

```mermaid
flowchart LR
  subgraph aws[AWS - weysure-prod]
    R[(RDS<br/>weysure)] -->|pg_dump<br/>read-only role| P[pipe]
    P -->|age: public key| E[/encrypted file<br/>emptyDir scratch/]
    E -->|rclone + check size and MD5| U((upload))
  end
  U --> D[(Google Drive<br/>weysure-db-backups)]
  subgraph you[Your Mac - offline]
    K[age PRIVATE key<br/>password manager + 2nd copy]
  end
  D -->|download| X[age -d -i key]
  K -.-> X
  X --> PR[pg_restore into<br/>any Postgres 16]
```

The plaintext dump is a pipe: it is never written to disk. Only the encrypted file touches the pod's scratch
space, and that disappears with the pod.

## One-time setup (Adebayo's steps, in this order)

Everything runs on your Mac. Secrets go from your Mac straight into Vault; never into chat, a PR or git.
The same steps are in gitops PR #108.

**A. Key pair.** `brew install age rclone`, then `age-keygen -o ~/weysure-backup-age.key`. The file is the
**private key**: put the whole contents in your password manager **and** a second place (USB/printed, in a
safe). Lose it and every backup is unreadable forever. Never put it in the cluster, Vault, GitHub or Drive.
`age-keygen -y ~/weysure-backup-age.key` re-prints the public key (`age1...`) any time.

**B. Google login (own OAuth client, free).** rclone's shared client is being retired during 2026, so create
your own in https://console.cloud.google.com: new project `weysure-backup` → *Library* → **Google Drive API** →
Enable → *Google Auth platform → Get started* (audience **External**) → *Data Access* → add scope
`https://www.googleapis.com/auth/drive.file` → *Clients → Create client → Desktop app* → note Client ID and secret →
*Audience → **Publish app***. **Publishing matters:** left in "Testing", Google expires the grant after 7 days and
the backups silently stop. (Publish greyed out: *Branding* → add a home-page and privacy-policy link → Save.)
Then `rclone config`: new remote `gdrive`, storage `drive`, your client ID and secret, scope **3 = drive.file**,
no service account, browser sign-in (Google warns "hasn't verified this app": *Advanced → Go to weysure-backup*),
not a shared drive. Check: `rclone mkdir gdrive:weysure-db-backups && rclone lsd gdrive:`.
`drive.file` means the backup sees **only files it created**, nothing else in your Drive; the folder must therefore
be created by rclone (that command), not by hand in the Drive website.

**C. Vault.** Port-forward (`kubectl -n vault port-forward svc/vault 8200:8200`), `export
VAULT_ADDR=http://127.0.0.1:8200`, `vault login -method=userpass username=adebayo`.

| Vault path (KV v2, mount `secret`) | Key | Value |
|---|---|---|
| `secret/weysure/backup` | `PGPASSWORD` | random, 40 letters/digits: the `weysure_backup` database password |
| | `AGE_RECIPIENT` | your age **public** key `age1...` |
| | `RCLONE_CONFIG_GDRIVE_CLIENT_ID` | your Google OAuth client ID |
| | `RCLONE_CONFIG_GDRIVE_CLIENT_SECRET` | your Google OAuth client secret |
| | `RCLONE_CONFIG_GDRIVE_TOKEN` | the token JSON from `rclone config show gdrive` (the `token = {...}` line) |

`vault kv get -mount=secret weysure/backup` must say `No value found` first. The path is new, so the first write is one
`vault kv put` (`kv patch` cannot create a path); every later change uses `kv patch`, never `put`:

```bash
rclone config show gdrive | sed -n 's/^token = //p' > ~/weysure-gdrive-token.json
CID=$(rclone config show gdrive | sed -n 's/^client_id = //p')
CSEC=$(rclone config show gdrive | sed -n 's/^client_secret = //p')
vault kv put -mount=secret weysure/backup \
  PGPASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)" \
  AGE_RECIPIENT="$(age-keygen -y ~/weysure-backup-age.key)" \
  RCLONE_CONFIG_GDRIVE_CLIENT_ID="$CID" \
  RCLONE_CONFIG_GDRIVE_CLIENT_SECRET="$CSEC" \
  RCLONE_CONFIG_GDRIVE_TOKEN=@"$HOME/weysure-gdrive-token.json"
rm -P ~/weysure-gdrive-token.json; unset CID CSEC
```

Expect `version 1`. Names only: `vault kv get -mount=secret -format=json weysure/backup | grep -o '"[A-Z_]*":' | sort`
must list the five keys. The ESO policy `weysure-read` already covers `secret/weysure/*`: no policy change.

**D. Merge gitops #108** (only after C). Argo applies it. Check (read-only):
`kubectl -n weysure-prod get externalsecret weysure-backup` → `SecretSynced True`;
`kubectl -n weysure-prod logs job/db-backup-role-v1 -c create-backup-role` → ends `backup role ready: weysure_backup (read-only)`.

**E. First backup now:** `kubectl -n weysure-prod create job --from=cronjob/weysure-db-backup weysure-db-backup-first`;
after ~1 min `logs job/weysure-db-backup-first -c upload-retain` must contain `BACKUP_OK object=daily/weysure-….dump.age bytes=…`,
and the file is in Drive. Then `kubectl -n weysure-prod delete job weysure-db-backup-first`.

**F. Restore test** (next section): do it once now, then quarterly, and after any change to the key, the Drive login or the job.

## Restore: any Postgres 16, anywhere

Needs: `age` and `rclone` (or just the Drive website for the download), the private key, Docker or any Postgres 16.

```bash
# 1. get the file (Drive website works too: open weysure-db-backups/daily/, download)
rclone lsf gdrive:weysure-db-backups/daily | tail -3
rclone copyto gdrive:weysure-db-backups/daily/weysure-<timestamp>.dump.age ./backup.dump.age
# 2. unlock it with YOUR private key (file from your password manager)
age -d -i ~/weysure-backup-age.key -o backup.dump backup.dump.age
# 3. a throwaway Postgres 16 (or use any server you have)
docker run -d --name restore-pg -e POSTGRES_PASSWORD=restore-test -p 5433:5432 postgres:16
sleep 5; docker exec restore-pg createdb -U postgres weysure_restored
# 4. restore
pg_restore --no-owner --no-privileges --exit-on-error \
  --dbname "postgresql://postgres:restore-test@127.0.0.1:5433/weysure_restored" backup.dump
# 5. look at it
docker exec restore-pg psql -U postgres -d weysure_restored -c '\dt' -c 'select count(*) from users;' -c 'select * from alembic_version;'
# 6. clean up (backup.dump is the readable data: delete it)
docker rm -f restore-pg; rm -P backup.dump backup.dump.age
```

`pg_restore` here is the client from Postgres 16 or newer (`brew install postgresql@16`, or `docker run --rm -i postgres:16 pg_restore …`
reading from stdin). `age -d -i KEY file | pg_restore …` works without writing `backup.dump` at all.
The restored tables belong to the user you restored as (`--no-owner`): on a real new server create the
roles first (the layout is in `db-grants-v2-job.yaml`: `weysure_owner` owns the tables, `weysure_app` has DML), or point the
API's migrate/app users at it as the new provider's setup requires.

**Moving to another cloud:** restore as above into the new Postgres 16, run the API's migrations check (`alembic current` must equal
the `alembic_version` shown in step 5), point `DATABASE_URL` at it. **This backup is the database only.** You also need the application
secrets (Vault `secret/weysure/*`: the Vault snapshot in S3 is encrypted by an AWS key and cannot be read elsewhere) and uploaded files
(Cloudinary). See Follow-ups in the SOP.

## What was proven, and what was not (2026-11-20)

A throwaway Postgres 16 (Docker, removed afterwards) running the exact scripts from the gitops manifests in the same pinned images
and security flags. Evidence log: [evidence/2026-11-20-db-offsite-backup-proof.txt](../evidence/2026-11-20-db-offsite-backup-proof.txt).

| Behaviour | Status |
|---|---|
| Role Job: creates read-only role, grants, self-check, idempotent, login ok, writes refused; later tables readable | **proven locally** (prod-like role layout) |
| `pg_dump \| age` produces `age-encryption.org/v1` ciphertext, no plaintext inside; real age release download verified by sha256 | **proven locally** |
| Restore into a second fresh Postgres 16: 16/16 checks identical (row counts + content hashes of 7 tables, 80,301 rows; sequences, indexes, constraints, columns, enum, view) | **proven locally** |
| Retention 30 daily / 12 monthly, monthly keeper once a month, foreign files untouched | **proven locally** (rclone `local` backend, seeded old files) |
| Failure cases exit non-zero without `BACKUP_OK`: private key as recipient, wrong DB password, tampered age download, broken Drive login | **proven locally** |
| `WeysureDbBackupMissing` rule | **proven with promtool** (4 scenarios); delivery to Slack **not exercised** |
| Upload to real Google Drive (OAuth refresh, `drive.file`, Drive MD5) | **not proven**: first live run is the test (step E) |
| Role Job against real RDS `weysure-postgres-v2` | **not proven**: mirrors `db-grants-v2` SQL; self-check fails the Job loudly |
| Admission by live Kyverno, ESO sync, Argo order | **not proven live**; Kyverno CLI v1.19.1 (cluster version) 18 pass / 0 fail, kubeconform strict 0 invalid |

## When something is wrong

| Sign | Meaning / fix |
|---|---|
| `WeysureDbBackupMissing` | [ALERTS.md](ALERTS.md#weysuredbbackupmissing) |
| `BACKUP_FAILED stage=dump-encrypt reason=AGE_RECIPIENT-is-not-an-age-public-key…` | the Vault value is not `age1…` (never paste the private key). `vault kv patch -mount=secret weysure/backup AGE_RECIPIENT="$(age-keygen -y ~/weysure-backup-age.key)"` |
| `reason=database-unreachable` | wrong `PGPASSWORD` (role Job and Vault disagree: rotate, below), RDS down, or egress: `kubectl -n weysure-prod get networkpolicy db-backup-egress` |
| `reason=age-download` / `age-sha256-mismatch` | GitHub unreachable (retry later) / the pinned hash no longer matches: **do not bypass**; check the release page, update version and both hashes in `scripts-configmap.yaml` in a PR |
| `pg_dump: error: … permission denied for table X` | a new table not readable by `weysure_backup` (owned by someone other than `weysure_owner`). Fix the owner or add `db-backup-role-v2` (copy of v1: re-grants and re-checks) |
| `reason=drive-mkdir-daily` + `invalid_grant` | Google login expired or revoked. Common cause: consent screen still in *Testing* (7 days). Publish it, `rclone config reconnect gdrive:` on the Mac, `vault kv patch … RCLONE_CONFIG_GDRIVE_TOKEN=@file` |
| `reason=size-mismatch` / `md5-mismatch` | upload corrupted: Job retries once; if it repeats, check Drive space (15 GB free on a personal account) |
| Pod `CreateContainerConfigError` | a key is missing in Vault `secret/weysure/backup` (all five required); `kubectl -n weysure-prod get externalsecret weysure-backup` |
| Drive almost full | each file is about the compressed size of the database; 30 + 12 copies. Free space or lower retention in `upload-retain.sh` |

## Rotation

| What | How |
|---|---|
| Google token / client | `rclone config reconnect gdrive:` → `vault kv patch -mount=secret weysure/backup RCLONE_CONFIG_GDRIVE_TOKEN=@file` (next run uses it; Secret refreshes within 1 h, or wait a day) |
| Database password | `vault kv patch … PGPASSWORD=…`, then a PR adding `db-backup-role-v2` (copy of v1; Jobs are immutable) |
| age key | make a new pair, `vault kv patch … AGE_RECIPIENT=<new public key>`. **Keep the old private key** as long as any old backup (30 days + 12 months) may need opening |

## Security notes

- The pod can reach RDS (5432) and the internet on 443. The network plugin matches IPs, not names, and Google's addresses cannot be listed, so it is not
  restricted to Google. It runs only the pinned script, has no Vault and no Kubernetes API access, and holds no private key.
- The database login is read-only (and `default_transaction_read_only = on`), can read data but change nothing.
- A leaked Drive token exposes only the files the backup created (`drive.file`), and every file is encrypted.
