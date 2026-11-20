#!/usr/bin/env bash
# Nightly encrypted off-server backup of the VPS database: the same recipe as the AWS CronJob
# (plateng-gitops projects/weysure/environments/prod/backup/), run from cron on the server.
#
#   pg_dump (inside the db container) | age (YOUR public key) -> temp file -> Google Drive
#   -> verify size + MD5 on Drive -> keep 30 daily + 12 monthly -> optional "I'm alive" ping
#
# One-time setup on the VPS (see VPS_MIGRATION.md step 8):
#   apt install -y age rclone                        # age >= 1.1, rclone from apt or rclone.org
#   install -d -m 700 /opt/weysure/backup
#   echo 'age1...your PUBLIC key' > /opt/weysure/backup/age-recipient.txt
#   cp rclone.conf /opt/weysure/backup/rclone.conf    # the [gdrive] remote from your Mac, chmod 600
#   crontab:  30 2 * * *  /opt/weysure/backup.sh >> /var/log/weysure-backup.log 2>&1
# The PRIVATE age key is never on this server.
set -euo pipefail
umask 077

DB_CONTAINER="${DB_CONTAINER:-weysure_db}"
DB_USER="${DB_USER:-weysure}"
DB_NAME="${DB_NAME:-weysure}"
BACKUP_DIR="${BACKUP_DIR:-/opt/weysure/backup}"
RCLONE_CONFIG="${RCLONE_CONFIG:-$BACKUP_DIR/rclone.conf}"
BACKUP_REMOTE="${BACKUP_REMOTE:-gdrive:weysure-db-backups}"
# Optional dead-man's switch, e.g. a healthchecks.io URL: pinged only after a fully verified backup.
PING_URL="${PING_URL:-}"
export RCLONE_CONFIG

fail() { echo "BACKUP_FAILED reason=$1"; exit 1; }

AGE_RECIPIENT="$(tr -d '[:space:]' < "$BACKUP_DIR/age-recipient.txt")" || fail "age-recipient-missing"
case "$AGE_RECIPIENT" in age1*) ;; *) fail "age-recipient-is-not-an-age1-public-key" ;; esac

WORK="$(mktemp -d "$BACKUP_DIR/run.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT          # the temp (encrypted) file never outlives the run

NAME="weysure-$(date -u +%Y-%m-%dT%H%M%SZ).dump.age"
FILE="$WORK/$NAME"
TABLES="$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -Atq -c "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema')")" || fail "database-unreachable"
[ "${TABLES:-0}" -gt 0 ] || fail "database-has-no-tables"

# Plaintext is a pipe only. pipefail: a failed pg_dump fails the whole run and nothing is uploaded.
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=custom --compress=6 --no-owner --no-privileges --lock-wait-timeout=120s \
  | age --recipient "$AGE_RECIPIENT" --output "$FILE.part" || fail "pg_dump-or-age"
SIZE="$(wc -c < "$FILE.part" | tr -d ' ')"
[ "$SIZE" -gt 1024 ] || fail "dump-implausibly-small-${SIZE}-bytes"
mv "$FILE.part" "$FILE"
LOCAL_MD5="$(md5sum "$FILE" | cut -d' ' -f1)"
SHA256="$(sha256sum "$FILE" | cut -d' ' -f1)"
PATTERN='weysure-*.dump.age'

rclone mkdir "$BACKUP_REMOTE/daily"   || fail "drive-mkdir-daily"
rclone mkdir "$BACKUP_REMOTE/monthly" || fail "drive-mkdir-monthly"
rclone copyto "$FILE" "$BACKUP_REMOTE/daily/$NAME" --retries 3 --low-level-retries 10 || fail "upload"

REMOTE_SIZE="$(rclone lsf --files-only --format s --include "$NAME" "$BACKUP_REMOTE/daily" | head -n 1)"
[ "$REMOTE_SIZE" = "$SIZE" ] || fail "size-mismatch-local-${SIZE}-remote-${REMOTE_SIZE:-none}"
REMOTE_MD5="$(rclone hashsum MD5 "$BACKUP_REMOTE/daily" --include "$NAME" | awk 'NR==1 {print $1}')"
[ "$REMOTE_MD5" = "$LOCAL_MD5" ] || fail "md5-mismatch"

MONTH="$(date -u +%Y-%m)"
if [ -z "$(rclone lsf --files-only --include "weysure-${MONTH}-*.dump.age" "$BACKUP_REMOTE/monthly" | head -n 1)" ]; then
  rclone copyto "$BACKUP_REMOTE/daily/$NAME" "$BACKUP_REMOTE/monthly/$NAME" || fail "monthly-copy"
  echo "monthly keeper stored: $NAME"
fi

# Retention only after the new object is verified; matches only our own file names.
rclone delete "$BACKUP_REMOTE/daily"   --min-age 30d  --include "$PATTERN" || fail "prune-daily"
rclone delete "$BACKUP_REMOTE/monthly" --min-age 366d --include "$PATTERN" || fail "prune-monthly"

DAILY_N="$(rclone lsf --files-only --include "$PATTERN" "$BACKUP_REMOTE/daily"   | wc -l | tr -d ' ')"
MONTHLY_N="$(rclone lsf --files-only --include "$PATTERN" "$BACKUP_REMOTE/monthly" | wc -l | tr -d ' ')"
echo "BACKUP_OK object=daily/$NAME bytes=$SIZE sha256=$SHA256 md5=$LOCAL_MD5 tables=$TABLES daily_kept=$DAILY_N monthly_kept=$MONTHLY_N"
if [ -n "$PING_URL" ]; then curl -fsS -m 10 --retry 3 -o /dev/null "$PING_URL" || echo "ping failed (backup itself is fine)"; fi
