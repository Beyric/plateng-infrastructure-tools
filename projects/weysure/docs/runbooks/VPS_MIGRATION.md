# Runbook — move Weysure from AWS to one plain VPS

**Who this is for:** Adebayo, in plain words. **Why it exists:** so leaving AWS is a planned weekend, not a crisis. The data comes from
the nightly encrypted Drive backup ([DB_OFFSITE_BACKUP.md](DB_OFFSITE_BACKUP.md)); the rest is a short list of files, all in
[`vps/`](vps/) next to this document.

> **How much to trust this.** The database restore, the compose file, the Caddy config and the VPS backup script were tested on a laptop
> (section 10, with the proof log). **Nobody has yet run the whole stack on a real server, issued the real certificates, or moved real DNS.**
> Do one full rehearsal on a cheap VPS before the real weekend (step 6). Anything marked *(not proven)* below is a reasoned expectation, not a result.

**Best time:** before launch, while the keys are still test keys and the data is test data. After launch the same steps work, but a mistake costs real money.

## 1. What moves, and what does not

| Thing | Moves? | How |
|---|---|---|
| **Postgres 16 data** (users, wallets, deals, ledger, every table) | **Yes** | The newest `.dump.age` file from Drive → decrypt with your private key → `pg_restore` into Postgres 16 on the VPS (step 7) |
| **Redis** | **No, nothing to carry** | It holds only rate-limit counters, live-message relays and short-lived retry counters, all of which expire. The VPS starts with an empty Redis. Checked in the code (`app/core/limiting.py`, `app/services/jobs.py`, `dva_inflow.py`, `dva_reconcile.py`) |
| **Uploaded documents / images** | **Stay on Cloudinary** | The database holds only references to them. **The Cloudinary account is the only copy.** It is not on AWS, so leaving AWS does not touch it, but nothing in this backup protects it: keep the account, its login and its API keys safe, and ask Cloudinary how to export it if you ever leave them too |
| **Secrets** (keys, tokens) | **Yes, by hand** | From Vault `secret/weysure/prod` + the plain settings in git into one file `/opt/weysure/.env` on the VPS (step 5). Names in section 2 and [`vps/env.example`](vps/env.example), no values anywhere in git |
| **Application images** (api, web) | **Yes** | Copy out of ECR to your Mac once, then onto the VPS; or rebuild from the repos (section 3) |
| **Vault itself** | **No** | Not needed on a VPS: the secrets live in `.env` (mode 600). The Vault snapshot in S3 is encrypted with an AWS key and cannot be read elsewhere |
| **DNS and TLS** | **Yes** | You flip two Cloudflare records; Caddy gets the certificates by itself |
| **Deploys** (Jenkins, Argo CD) | **Replaced by** two commands | `docker compose pull` / `up -d`. You need somewhere to keep images once ECR is gone (a private registry such as GitHub's, or `docker save` files) |
| **Monitoring** (Prometheus, Loki, Grafana, Slack alerts) | **No** | See "What you lose" below: you must replace some of it |

**What you lose when you leave the cluster** — be deliberate about this. The wallet-drift, withdrawal-stuck, auto-pause and Paystack
webhook alerts are *log* alerts in Loki, and `WeysureDbBackupMissing`, the pod alerts and the dashboards are Prometheus. None exist on a plain VPS.
Minimum replacement: an outside uptime monitor on `https://api.weysure.com/api/v1/health` and the web home page; the backup's `PING_URL`
(a healthchecks.io check that goes quiet if the backup stops); `docker compose ps` showing `healthy` for the worker; a disk-space alert from the VPS provider.
For the money alerts, the developers' log lines (`[LIVE AUTO PAUSE]`, `jobs_stats`, wallet reconciliation) would need a small log-watching job: say so before you move.

## 2. Settings the API, worker and web need (names only)

Authority: `Weysure-API/app/core/config.py` (165 settings, every one also listed in `Weysure-API/.env.example`) and
`plateng-gitops/projects/weysure/environments/prod/apps/api/values.yaml` (`commonEnv`: the plain settings live in prod today).
The **api and worker use the same file**; **web has no runtime settings** (see below). Template: [`vps/env.example`](vps/env.example).

| Group | Names | Secret? | Where the value comes from today |
|---|---|---|---|
| Must be set or the app refuses to start | `SECRET_KEY`, `DATABASE_URL`, `SERVER_HOST`, `EMAILS_FROM_EMAIL`, `ENVIRONMENT` | `SECRET_KEY` and `DATABASE_URL` | Vault `secret/weysure/prod` (`SECRET_KEY`); `DATABASE_URL` is dynamic in AWS, **set by the compose file on the VPS** |
| Addresses | `SERVER_HOST`, `FRONTEND_URL`, `BACKEND_CORS_ORIGINS`, `TRUSTED_PROXY_CIDRS`, `REFRESH_COOKIE_SECURE` | no | gitops values (`TRUSTED_PROXY_CIDRS` is set by the compose file on the VPS) |
| Email (Resend) | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `EMAILS_FROM_EMAIL`, `EMAILS_FROM_NAME`, `ADMIN_NOTIFICATION_EMAILS` | `SMTP_PASSWORD` | Vault + gitops |
| Paystack | `PAYSTACK_SECRET_KEY`, `PAYSTACK_PUBLIC_KEY`, `PAYSTACK_WEBHOOK_SECRET`, `PAYSTACK_TEST_SECRET_KEY`, `PAYSTACK_TEST_PUBLIC_KEY`, `PAYSTACK_LIVE_SECRET_KEY`, `PAYSTACK_LIVE_PUBLIC_KEY` | the secret keys and webhook secret | Vault |
| Cloudinary | `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET` | key and secret | Vault |
| SMS (Termii) | `TERMII_API_KEY`, `TERMII_BASE_URL`, `TERMII_SENDER_ID`, `TERMII_OTP_CHANNEL`, `TERMII_OTP_TEMPLATE`, `OTP_*` | `TERMII_API_KEY` | Vault + gitops |
| Identity (Dojah) | `DOJAH_ENVIRONMENT`, `DOJAH_BASE_URL`, `DOJAH_APP_ID`, `DOJAH_PUBLIC_KEY`, `DOJAH_BVN_WIDGET_ID`, `DOJAH_NIN_WIDGET_ID`, `DOJAH_FACE_MATCH_THRESHOLD`, `DOJAH_API_KEY`, `DOJAH_WEBHOOK_SECRET`, `KYC_FINGERPRINT_KEY`, `CAC_PROVIDER`, `DOJAH_SANDBOX_CAC_IN_PRELAUNCH` | `DOJAH_API_KEY`, `DOJAH_WEBHOOK_SECRET`, `KYC_FINGERPRINT_KEY` | Vault + gitops |
| Keys the existing data depends on | `RISK_SIGNAL_HASH_KEY`, `MFA_ENCRYPTION_KEY`, `MFA_CODE_PEPPER`, `KYC_FINGERPRINT_KEY` | all | Vault. **Copy the production values.** New ones silently break: stored device/IP matching, every enrolled authenticator, every BVN/NIN fingerprint |
| Sign-in and passkeys | `MFA_ENABLED`, `MFA_STEP_UP_ENFORCED`, `WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGINS`, `COOKIE_HOST_PREFIX`, `RISK_DEVICE_COOKIE_DOMAIN`, `ACCESS_COOKIE_MODE` | no | gitops. `WEBAUTHN_RP_ID` must stay the site's domain or every passkey stops working |
| Feature switches | `ORIGIN_RULES_ENFORCED`, `RISK_HOLDS_MODE`, `LIVE_AUTO_PAUSE_MODE`, `DVA_*`, `REFUND_TO_SOURCE_ENABLED`, `KYC_ENHANCED_ENABLED`, `KYB_APPLICATIONS_ENABLED`, `WS_ALLOW_URL_TOKEN`, … | no | gitops values: **it is the authority; copy it, do not retype from memory** |
| Worker only | `WALLET_RECONCILIATION_SCHEDULER_ENABLED`, `…_INTERVAL_MINUTES`, `…_NOTIFY_COOLDOWN_MINUTES`, `JOBS_*` | no | set in `vps/docker-compose.yaml` as in the cluster |
| Runtime | `WEB_CONCURRENCY`, `GUNICORN_*`, `RUN_MIGRATIONS`, `REDIS_URL` | no | `REDIS_URL` set by compose. Leave `VAULT_ENV_FILE` **unset** (the container would wait 60 s for a file that never comes) |
| Web (Next.js) | `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_WS_URL` — **baked into the image at build time**, not read at runtime | no | The image in ECR was built with `https://api.weysure.com/api/v1` and `wss://api.weysure.com/api/v1` (`Weysure/Jenkinsfile`). Same domains → reuse the image; different domains → rebuild |

To see which names Vault holds (names only, never values): `vault kv get -mount=secret -format=json weysure/prod | grep -o '"[A-Z_]*":' | sort`.

## 3. Images: get them out of ECR (or rebuild)

The tags live in prod are in `plateng-gitops` `projects/weysure/environments/prod/images.yaml` (`api.tag`, `web.tag`). The ECR images are single-architecture
(the cluster's workload nodes are x86-64, so most likely `amd64`: check below). **Choose an x86-64 VPS**, or rebuild for ARM.

**Option A — copy from ECR through your Mac (nothing AWS-related ever lands on the VPS).** Needs `aws sso login` and Docker Desktop:

```bash
API_TAG=<api tag from images.yaml>; WEB_TAG=<web tag from images.yaml>
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 767397877316.dkr.ecr.us-east-1.amazonaws.com
docker pull 767397877316.dkr.ecr.us-east-1.amazonaws.com/weysure-api:$API_TAG
docker pull 767397877316.dkr.ecr.us-east-1.amazonaws.com/weysure-web:$WEB_TAG
docker image inspect --format '{{.Architecture}}' 767397877316.dkr.ecr.us-east-1.amazonaws.com/weysure-api:$API_TAG   # expect: amd64
docker save 767397877316.dkr.ecr.us-east-1.amazonaws.com/weysure-api:$API_TAG 767397877316.dkr.ecr.us-east-1.amazonaws.com/weysure-web:$WEB_TAG | gzip > weysure-images-$API_TAG-$WEB_TAG.tar.gz
docker logout 767397877316.dkr.ecr.us-east-1.amazonaws.com
```
**Expect:** `amd64` and a file of roughly 300–500 MB. **Keep that file outside AWS too** (Drive): once the AWS account is closed, ECR is gone and this file is the only copy of the exact images that ran.
On the VPS: `gunzip -c weysure-images-….tar.gz | docker load`, then set `API_IMAGE` / `WEB_IMAGE` in `.env` to the full names shown by `docker load`.

**Option B — rebuild from the repos** (also how every later release is made once Jenkins is gone):

```bash
# API: Weysure-API/Dockerfile (python 3.11, gunicorn; runs migrations at boot)
docker build -t weysure-api:$(git rev-parse --short HEAD) .                       # in Weysure-API at the commit you want
# Web: Weysure/Dockerfile (Next.js standalone); the API address is baked in, so pass it:
docker build -t weysure-web:$(git rev-parse --short HEAD) \
  --build-arg NEXT_PUBLIC_API_URL=https://api.weysure.com/api/v1 \
  --build-arg NEXT_PUBLIC_WS_URL=wss://api.weysure.com/api/v1 .                  # in Weysure at the commit you want
```
Add `--platform linux/amd64` when building on an ARM Mac for an x86 VPS. A rebuild is **not** byte-identical to what ran in production
(base-image patches move): use A for the cutover, B for later releases.

## 4. What the developers' `docker-compose.yaml` lacks for production

`Weysure-API/docker-compose.yaml` is a local-development file (api, worker, redis). [`vps/docker-compose.yaml`](vps/docker-compose.yaml) starts from it and adds:

| Missing there | In `vps/docker-compose.yaml` |
|---|---|
| No Postgres: it expects a database elsewhere | `db`: Postgres 16 (digest-pinned), volume `pgdata`, health check, **no published port** |
| No web app | `web` (the Next.js image) |
| No TLS, no reverse proxy: api published on `0.0.0.0:8000` | `caddy` on 80/443 with automatic certificates; api, web, db, redis are **not** reachable from outside |
| Redis published on `0.0.0.0:6379` (open to the internet on a server) | no port; Redis on the internal network only; persistence off (disposable) |
| `./app` bind-mounted over the image's code (the image never really runs) | removed: the image is what runs |
| `build: .`, image `weysure-api:dev`, development reload switches | pinned `API_IMAGE` / `WEB_IMAGE` from `.env` |
| Containers can write anywhere, run with default privileges | `read_only`, `/tmp` as tmpfs, `cap_drop: ALL`, `no-new-privileges` (as in the cluster) |
| Client address trust: nothing (the app reads `CF-Connecting-IP` only from trusted peers) | fixed network `172.28.0.0/24`, Caddy at `172.28.0.10`, `TRUSTED_PROXY_CIDRS=172.28.0.10/32`; the Caddyfile overwrites the header with the real address |
| `DATABASE_URL` from a file | built from `POSTGRES_*` in `.env` |
| Memory limits are tiny (api 512m) | api 1g, worker 512m, db 1g, web 512m (estimate, **not load-tested**) |
| Both api and worker have no ordering against a database | worker waits for a healthy api; api waits for healthy db and redis |
| No backups, no firewall, no updates | sections 5 and 8 below |

One thing the file deliberately keeps: **one `api` container**. It runs the database migrations when it boots; two copies booting together would race.

## 5. Build the server (do this days before the cutover)

**Size (estimate, not measured):** x86-64, 2 vCPU, 4 GB RAM, 40 GB SSD, Ubuntu 24.04 LTS or Debian 12, pick a region close to your users (latency to Lagos matters more than price); a provider that snapshots the disk is a free extra safety net. Growth: watch the `pgdata` size.

```bash
# on the VPS, as root, once
adduser --disabled-password --gecos "" deploy && usermod -aG sudo deploy && mkdir -p /home/deploy/.ssh && cp ~/.ssh/authorized_keys /home/deploy/.ssh/ && chown -R deploy:deploy /home/deploy/.ssh
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/; s/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && systemctl restart ssh
apt-get update && apt-get install -y ufw fail2ban unattended-upgrades age rclone ca-certificates curl
ufw default deny incoming && ufw default allow outgoing && ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && ufw --force enable
dpkg-reconfigure -plow unattended-upgrades
# Docker: follow https://docs.docker.com/engine/install/ubuntu/ (official apt repository, includes the compose plugin)
install -d -o deploy -g deploy -m 750 /opt/weysure
```
**Test the new login from a second terminal before closing the first** (`ssh deploy@<ip>`): a mistake here locks you out.
The firewall allows only SSH, 80 and 443. Docker bypasses `ufw` for **published** ports, which is why the compose file publishes only Caddy's and nothing else.

Copy the folder and build `.env`:

```bash
# from your Mac, in plateng-infrastructure-tools/projects/weysure/docs/runbooks/vps
scp docker-compose.yaml Caddyfile backup.sh deploy@<ip>:/opt/weysure/ && ssh deploy@<ip> 'chmod 750 /opt/weysure/backup.sh'
```
The secrets go from Vault to the server without touching git, chat or a screen (port-forward Vault as in the backup runbook, step C). Values with a newline are refused:

```bash
vault kv get -format=json secret/weysure/prod | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]["data"]; [print(k + "=" + v) for k, v in sorted(d.items()) if "\n" not in v]' > .env.secrets
chmod 600 .env.secrets
```
Then assemble `/opt/weysure/.env` = the plain settings (from `vps/env.example`, with the live values from the gitops `commonEnv`) + `.env.secrets` + the compose-only names (`WEB_DOMAIN`, `API_DOMAIN`, `ACME_EMAIL`, `API_IMAGE`, `WEB_IMAGE`, `POSTGRES_PASSWORD` — a **new** 40-character password: the VPS database is not the AWS one). `scp` it, `chmod 600`, then `rm -P .env.secrets` on your Mac.
**Check before going on:** `cd /opt/weysure && docker compose config -q` prints nothing (that is success); a missing name stops with `required variable … is missing`. Check that every group in section 2 is present.
If an app setting is missing the API refuses to start and says which one in `docker compose logs api` (the boot guard names the setting, never its value).

## 6. Rehearse once (a cheap VPS, one afternoon)

Same server, a throwaway hostname pair instead of production (for example `rehearsal-api.weysure.com`, DNS only, pointed at the VPS); restore the newest Drive backup (step 7a–7c); start **only** `db redis api caddy`.
- **Do not start the worker or web in a rehearsal.** The worker on a copy of the production database with the real provider keys would process real jobs: send real emails and SMS and call Paystack. The same goes for calling money endpoints on the API. Use test keys, or leave the worker off.
- Prove: the certificate issues (Caddy log), `https://rehearsal-api…/api/v1/health` answers 200, `docker compose exec api alembic current` shows the same version as before, and the API's own start-up check passes with your `.env` (it refuses to boot if a key is wrong).
- Web cannot be rehearsed on other hostnames (its API address is baked in); rebuild it with test build arguments if you want that too.
- Time the restore and the whole sequence. Then throw the rehearsal DNS record away and `docker compose down -v` on the VPS (or rebuild it).

## 7. Cutover weekend

**Prerequisites:** gitops #108 live (so the final dump can be made on demand), one successful restore test from Drive, a rehearsal done, the images on the VPS, `.env` built, your **age private key at hand on your Mac** (it is never put on the VPS), a registry or file store decided for future images.
Keep the same domains (`weysure.com`, `www`, `api.weysure.com`): then **no provider webhook URL, CORS list, cookie domain or passkey setting changes** (see "If the domain changes" below).

| # | When | What |
|---|---|---|
| 0 | **T–1 week** | Providers (Paystack, Dojah, Termii, Resend, Cloudinary): in each dashboard check whether **IP allow-lists** are on for the API keys; if so, add the VPS's IP now. Tell the developers: no merges to `main` during the window |
| 1 | **T–1 day** | Cloudflare DNS: note the current records for `weysure.com`, `www` and `api` (screenshot) and set TTL to 1–5 min where the record is not proxied. Do the rehearsal above if not done. Take a fresh server snapshot at the provider |
| 2 | **T, start** | Announce the window (30–60 min). Freeze AWS writes (**you run these**, `kubectl` is human-gated): `kubectl -n weysure-prod scale deploy api api-worker web --replicas=0` and check `kubectl -n weysure-prod get pods` shows none of them. (Replicas return to 2 / 1 / 2 if you roll back.) |
| 3 | | Final dump, **after** the freeze: `kubectl -n weysure-prod create job --from=cronjob/weysure-db-backup final-cutover-1`, then `kubectl -n weysure-prod logs job/final-cutover-1 -c upload-retain` must show `BACKUP_OK object=daily/weysure-<timestamp>.dump.age`. Note the name and the `sha256` |
| 4 | | **Restore on the VPS.** On your Mac: download, decrypt there, stream into the VPS database over SSH, so the private key and the readable data never rest on the server (below) |
| 5 | | On the VPS: `docker compose up -d db redis api worker web` (**not** caddy yet). Wait for `healthy`: `docker compose ps`. Check `docker compose logs api | tail`: migrations ran (no-op if the image is the one that ran on AWS) and gunicorn started. The API talks to the new database through `DATABASE_URL` from compose |
| 6 | | Flip DNS in Cloudflare: `weysure.com`, `www` and `api` → the VPS IP (A records; **DNS only / grey cloud**: the Caddy layout assumes Cloudflare's proxy is off). Wait: `dig +short api.weysure.com @1.1.1.1` shows the VPS IP |
| 7 | | `docker compose up -d caddy`. It gets both certificates within about a minute *(not proven)*. If it logged ACME errors before DNS caught up: `docker compose restart caddy` |
| 8 | | **Verify (below) before anyone is told it is back** |
| 9 | | Update the providers *only if something changed* (below), tell the developers the window is over |
| 10 | **T+7 days** | If all is well: take the AWS side down (separate decision, not part of this runbook). Until then keep RDS (PITR keeps 7 days) and Vault untouched |

Step 4, from your Mac (private key stays here; download from Drive with `rclone`, or save the file from the Drive website):

```bash
rclone copyto gdrive:weysure-db-backups/daily/weysure-<timestamp>.dump.age ./final.dump.age
shasum -a 256 final.dump.age        # must equal the sha256 printed by the BACKUP_OK line
age -d -i ~/weysure-backup-age.key ./final.dump.age | ssh deploy@<vps-ip> 'docker exec -i weysure_db pg_restore -U weysure -d weysure --no-owner --no-privileges --exit-on-error'
```
**Expect:** no output and exit 0. **If it fails:** `pg_restore` stops at the first error (`--exit-on-error`) and says why; empty the database and retry: `ssh deploy@<vps-ip> 'docker exec weysure_db psql -U weysure -d postgres -c "DROP DATABASE weysure" -c "CREATE DATABASE weysure OWNER weysure"'`, then run the restore again. The database `weysure` and its owner `weysure` already exist (compose creates them). The restored tables belong to `weysure`; the AWS roles (`weysure_owner`, `weysure_app`, Vault users) are not needed on the VPS (`--no-owner`).
Quick check: `ssh deploy@<vps-ip> "docker exec weysure_db psql -U weysure -d weysure -c 'select version_num from alembic_version' -c 'select count(*) from users'"`; the count must equal what you read on AWS just before the freeze (`db-oneoff.sh … read`).

**Verify (step 8).** All on the live domains:
- `curl -sS https://api.weysure.com/api/v1/health` → 200; `https://weysure.com` loads; `www` redirects to the apex.
- Sign in with your own account (and with 2FA if on): proves the database, `SECRET_KEY`, cookies and MFA keys.
- A **test deal end to end** with test keys (create, pay in Paystack test mode, release): proves Paystack calls out *and* the webhook comes in. In the Paystack dashboard open the webhook log and confirm a delivery to `https://api.weysure.com/api/v1/wallet/paystack/webhook` answered 200.
- Dojah: a KYC step reaches the widget; the Dojah webhook is `https://api.weysure.com/api/v1/kyc/dojah/webhook` (dashboard shows delivery).
- A phone OTP arrives (Termii) and an email arrives (Resend; sender domain unchanged).
- `docker compose ps`: every service `healthy`, the worker too (its heartbeat file is checked); `docker compose logs --tail 50 worker` shows `jobs_stats` lines.
- Run the first backup by hand: `/opt/weysure/backup.sh` → `BACKUP_OK`, and the file is in Drive (step 8 of the setup below).

**If the domain changes** (not recommended: do it as a separate, later step): `SERVER_HOST`, `FRONTEND_URL`, `BACKEND_CORS_ORIGINS`, `WEBAUTHN_RP_ID`/`WEBAUTHN_ORIGINS` (**every passkey enrolled on the old domain stops working**; authenticator apps and SMS keep working), `RISK_DEVICE_COOKIE_DOMAIN`, rebuild the web image with new `NEXT_PUBLIC_*` build arguments, the Paystack webhook and callback URLs, the Dojah webhook URL, the Resend sender domain (SPF/DKIM) and the `EMAILS_FROM_EMAIL`.

## 8. Backups on the VPS (set up before the cutover, not after)

The same recipe as AWS: [`vps/backup.sh`](vps/backup.sh) dumps the `db` container, encrypts with your **public** key, uploads to the same Drive folder
layout, verifies size and checksum, keeps 30 daily + 12 monthly, and pings an optional healthchecks.io URL only after a verified success.

```bash
# on the VPS, as deploy; the PRIVATE key never comes here
install -d -m 700 /opt/weysure/backup
echo 'age1…your public key…' > /opt/weysure/backup/age-recipient.txt           # age-keygen -y ~/weysure-backup-age.key on your Mac prints it
# on your Mac:  the [gdrive] section of `rclone config file` -> /opt/weysure/backup/rclone.conf  (chmod 600)
(crontab -l 2>/dev/null; echo '30 2 * * * PING_URL=https://hc-ping.com/<your-check-uuid> /opt/weysure/backup.sh >> /var/log/weysure-backup.log 2>&1') | crontab -
/opt/weysure/backup.sh
```
**Expect:** `BACKUP_OK object=daily/weysure-….dump.age …`. (`/var/log/weysure-backup.log` needs `sudo touch` + `chown deploy` first.) Restore from it with the same commands as step 4.
Also keep the provider's disk snapshots on, and run one restore test from Drive every quarter.
Updates: `unattended-upgrades` patches the OS; for the containers, set the new tag in `.env` and `docker compose up -d api worker web` (the old tag stays one `.env` edit away: that is the rollback). Re-pin the Postgres/Caddy/Redis digests in `docker-compose.yaml` at least every few months.

## 9. Rollback

| Where you are | Rollback |
|---|---|
| Before the DNS flip (steps 2–5) | Nothing was moved on AWS except the freeze: bring it back: `kubectl -n weysure-prod scale deploy api web --replicas=2` and `kubectl -n weysure-prod scale deploy api-worker --replicas=1`, check pods are Ready and both sites answer. Delete the VPS data if you like. **No data is lost.** |
| After the flip, minutes in, nobody real has written on the VPS | Point the DNS records back (the screenshot from step 1), scale AWS back up as above. Anything written to the VPS in between is lost: check `select count(*)` of the busiest tables on the VPS first; if rows were added, treat it as the next row |
| After real users have written on the VPS | **Not a clean rollback.** Writes exist only on the VPS. Stop the VPS api and worker, dump the VPS database, and restore it into RDS as the RDS master (a one-off, human-run, rehearsed first); the approach is the reverse of step 4 and is **not written or rehearsed** here. Decide your point of no return in advance: the safest is "if it is not clearly healthy 60 minutes after the flip, roll back while it is still cheap" |

AWS stays the fallback for at least a week after the cutover: RDS keeps its snapshots and point-in-time recovery, and the nightly backup of the VPS data goes to Drive.

## 10. What was proven, and what was not (2026-11-20)

Evidence log: [evidence/2026-11-20-vps-migration-proof.txt](../evidence/2026-11-20-vps-migration-proof.txt). All on a laptop, throwaway containers, removed afterwards.

| Behaviour | Status |
|---|---|
| A dump made the way the cluster makes it, encrypted, decrypted with the private key, restored into the **`db` service of this compose file** (plain Postgres 16, owner `weysure`, `--no-owner`): 13/13 checks identical to the source (row counts and content hash of every table, sequences, indexes, constraints, columns, enum, view) | **proven locally** |
| `vps/backup.sh` against that container, unmodified: encrypts, uploads (rclone local backend), verifies size + MD5, monthly keeper, retention, temp files removed; the object restores into a third empty database, 13/13 identical; refuses a private key as recipient; fails cleanly with the db container missing | **proven locally** |
| `docker compose config` on `vps/docker-compose.yaml` (valid, required variables enforced); `caddy validate` on the `Caddyfile`; `shellcheck` on `backup.sh` | **proven** |
| The `db` service starts healthy with `cap_drop: ALL` plus the capabilities its entrypoint needs | **proven locally** |
| The api, worker, web and caddy containers running together; `read_only` + `tmpfs` being enough for api/web/worker; the web health check; migrations at boot on a restored database; Caddy issuing certificates; Cloudflare grey-cloud flip; firewall and SSH hardening steps; the ECR copy (needs your AWS login); real Drive upload; provider dashboards; the sizing | **not proven** — the rehearsal (step 6) is where they get proven |
| Rollback after real writes on the VPS | **not designed in detail, not rehearsed** |
| A "Cloudflare proxy on" variant | **not written**: Caddy would have to stop overwriting `CF-Connecting-IP`, and ports 80/443 be limited to Cloudflare's published ranges, or a caller could pick its own rate-limit bucket |
