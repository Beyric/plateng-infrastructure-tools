#!/usr/bin/env bash
# Proves db-reset-prod-v1 on a THROWAWAY Postgres 16 (Docker), never on a real database.
#
#   scripts/weysure-data-reset/prove-local.sh <job.yaml> <api-repo-dir> <python-with-alembic-and-psycopg2>
#
# job.yaml  : plateng-gitops projects/weysure/manual/prod/db-reset-prod-v1-job.yaml. The harness takes
#             the Job's own `args` script out of it and runs THAT, unchanged, in the Job's pinned image
#             with the Job's security flags (non-root, read-only rootfs, drop ALL). What is proven is
#             what ships.
# api-repo  : a Weysure-API checkout at the commit running in prod (its alembic head is the schema).
# Output    : an evidence log on stdout (tee it); exit 0 only if every check passed.
# Cleans up : removes its container and the temp files, also on failure.
set -euo pipefail
JOB=${1:?job yaml}; API=${2:?api repo dir}; PY=${3:?python}
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=${CONTAINER:-weysure-reset-proof}; PORT=${PORT:-55433}
IMG='postgres:16.16-alpine3.23@sha256:a23cda8ed4733a74cd0a328fcb525a43c35cdbaa845b6fdb8f343646f995cc1e'
WORK=$(mktemp -d); FAILS=0
cleanup(){ docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

pg(){ docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q -X "$@"; }
val(){ docker exec "$NAME" psql -U postgres -d "$1" -At -X -c "$2"; }
check(){ if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2', want '$3')"; FAILS=$((FAILS+1)); fi; }
section(){ printf '\n== %s ==\n' "$1"; }

# --- pull the Job's script out of the YAML (python: -I, no site dirs from cwd) -------------------
"$PY" -I - "$JOB" "$WORK" <<'PYEOF'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))
c = job["spec"]["template"]["spec"]["containers"][0]
assert c["command"] == ["sh", "-ec"], c["command"]
open(sys.argv[2] + "/job-script.sh", "w").write(c["args"][0])
sc = c["securityContext"]
assert sc["readOnlyRootFilesystem"] and sc["runAsNonRoot"] and sc["capabilities"]["drop"] == ["ALL"] and not sc["allowPrivilegeEscalation"]
print("image in Job:", c["image"])
open(sys.argv[2] + "/job-image", "w").write(c["image"])
PYEOF
[[ "$(cat "$WORK/job-image")" == "$IMG" ]] || { echo "Job image differs from the image this harness pins"; exit 1; }

# --- server ----------------------------------------------------------------------------------
section "0. throwaway postgres 16 + the prod role layout (weysure_owner owns tables, weysure_app has DML only)"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=localtest -p "127.0.0.1:$PORT:5432" "$IMG" >/dev/null
for _ in $(seq 1 30); do docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
val postgres "select version()" | cut -c1-40
pg -d postgres <<'SQL'
CREATE ROLE weysure_owner NOLOGIN;
CREATE ROLE weysure_app NOLOGIN;
CREATE ROLE v_migrate_local LOGIN PASSWORD 'localtest' IN ROLE weysure_owner;   -- like Vault's weysure-migrate
ALTER ROLE v_migrate_local SET role = 'weysure_owner';
CREATE ROLE v_app_local LOGIN PASSWORD 'localtest' IN ROLE weysure_app;         -- like Vault's weysure-app
CREATE DATABASE weysure_tpl;
SQL
pg -d weysure_tpl <<'SQL'
GRANT ALL PRIVILEGES ON DATABASE weysure_tpl TO weysure_owner;
GRANT ALL ON SCHEMA public TO weysure_owner;
GRANT USAGE ON SCHEMA public TO weysure_app;
ALTER DEFAULT PRIVILEGES FOR ROLE weysure_owner IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO weysure_app;
ALTER DEFAULT PRIVILEGES FOR ROLE weysure_owner IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO weysure_app;
SQL
(cd "$API" && DATABASE_URL="postgresql://v_migrate_local:localtest@127.0.0.1:$PORT/weysure_tpl" "$PY" -m alembic upgrade head >/dev/null 2>&1)
HEAD=$(val weysure_tpl "select version_num from alembic_version")
echo "alembic upgrade head from an empty database -> $HEAD ; tables: $(val weysure_tpl "select count(*) from pg_tables where schemaname='public'")"
check "all tables owned by weysure_owner, not a superuser" "$(val weysure_tpl "select string_agg(distinct tableowner, ',') from pg_tables where schemaname='public'")" "weysure_owner"

mkdb(){ pg -d postgres -c "CREATE DATABASE $1 TEMPLATE weysure_tpl"; }
seed(){ "$PY" -I "$HERE/seed_sample_data.py" "postgresql://v_migrate_local:localtest@127.0.0.1:$PORT/$1" | tail -2; }

# run the Job's script, as shipped, against database $1 as db user $2 with DRY_RUN=$3; output to $WORK/out.txt
runjob(){
  local db=$1 user=$2 dry=$3; shift 3
  printf 'DATABASE_URL=postgresql://%s:localtest@127.0.0.1:5432/%s?sslmode=disable\n' "$user" "$db" > "$WORK/vault-env"
  chmod 644 "$WORK/vault-env"
  set +e
  docker run --rm --network "container:$NAME" --read-only --tmpfs /tmp:uid=1000,gid=1000 --user 1000:1000 \
    --cap-drop ALL --security-opt no-new-privileges \
    -v "$WORK/vault-env:/vault/secrets/env:ro" -v "$WORK/job-script.sh:/job-script.sh:ro" \
    -e VAULT_ENV_FILE=/vault/secrets/env -e HOME=/tmp -e DRY_RUN="$dry" \
    -e OWNER_EMAIL=beyrichq@gmail.com -e EXPECT_DB="$db" "$@" \
    "$IMG" sh -ec "$(cat "$WORK/job-script.sh")" > "$WORK/out.txt" 2>&1
  RC=$?
  set -e
}
counts(){ docker exec "$NAME" psql -U postgres -d "$1" -At -X -c "
  select string_agg(tablename||'='||(xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I', tablename), false, true, '')))[1]::text, ' ' order by tablename)
  from pg_tables where schemaname='public'"; }
kept_hash(){ val "$1" "select md5(coalesce((select string_agg(a::text, '|' order by id) from admins a where lower(email)='beyrichq@gmail.com'),'')
   || coalesce((select string_agg(f::text, '|' order by id) from mfa_factors f where subject_type='admin' and subject_id=(select id from admins where lower(email)='beyrichq@gmail.com')),'')
   || coalesce((select string_agg(c::text, '|' order by id) from mfa_recovery_codes c where subject_type='admin' and subject_id=(select id from admins where lower(email)='beyrichq@gmail.com')),'')
   || coalesce((select string_agg(s::text, '|' order by key) from settings s),'')
   || coalesce((select string_agg((to_jsonb(e) - 'updated_by_id')::text, '|' order by id) from escrow_settings e),'')
   || coalesce((select string_agg((to_jsonb(d) - 'updated_by_id')::text, '|' order by method) from delivery_method_settings d),'')
   || coalesce((select string_agg((to_jsonb(t) - 'updated_by_admin_id')::text, '|' order by tier) from kyc_tier_limits t),'')
   || coalesce((select string_agg((to_jsonb(r) - 'updated_by_id')::text, '|' order by id) from risk_hold_settings r),'')
   || coalesce((select version_num from alembic_version),''))"; }

# Content fingerprint of a whole database: per table, md5 of its rows sorted as text; then md5 of those.
dumpsum(){ val "$1" "select md5(string_agg(tablename || '=' || (xpath('/row/h/text()', query_to_xml(format('select md5(coalesce(string_agg(t::text, ''|'' order by t::text), '''')) h from public.%I t', tablename), false, true, '')))[1]::text, ',' order by tablename)) from pg_tables where schemaname='public'"; }
# ---------------------------------------------------------------------------------------------
section "1. seed realistic sample data into EVERY table (fake values only)"
mkdb weysure_seeded
seed weysure_seeded
check "every one of the 72 public tables holds rows" "$(val weysure_seeded "select count(*) from pg_tables where schemaname='public'")" "72"
pg -d postgres -c "CREATE DATABASE weysure TEMPLATE weysure_seeded"
echo "rows by class before: $(val weysure "select 'total=' || sum((xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I', tablename), false, true, '')))[1]::text::int) from pg_tables where schemaname='public'")"
check "fingerprint is stable (two dumps of an untouched database agree)" "$(dumpsum weysure)" "$(dumpsum weysure)"
SIGNIN_URL="postgresql://v_migrate_local:localtest@127.0.0.1:$PORT/weysure"
(cd "$API" && "$PY" "$HERE/owner_signin_check.py" prepare "$SIGNIN_URL" "$WORK/totp-secret") 2>&1 | tail -1
BEFORE_COUNTS=$(counts weysure); BEFORE_HASH=$(kept_hash weysure)
BEFORE_SEQ=$(val weysure "select count(*) from pg_sequences where schemaname='public' and last_value is not null")
OWNER_ID=$(val weysure "select id from admins where lower(email)='beyrichq@gmail.com'")
OWNER_FACTORS=$(val weysure "select count(*) from mfa_factors where subject_id='$OWNER_ID'"); OWNER_CODES=$(val weysure "select count(*) from mfa_recovery_codes where subject_id='$OWNER_ID'")
echo "owner admin: id=$OWNER_ID factors=$(val weysure "select count(*) from mfa_factors where subject_id='$OWNER_ID'") recovery codes=$(val weysure "select count(*) from mfa_recovery_codes where subject_id='$OWNER_ID'"); other admins=$(val weysure "select count(*) from admins where id<>'$OWNER_ID'")"

# ---------------------------------------------------------------------------------------------
section "2. DRY RUN (DRY_RUN=true): the full output the owner sees, then proof nothing changed"
runjob weysure v_migrate_local true
cat "$WORK/out.txt"
check "dry run exits 0" "$RC" "0"
check "dry run ends with RESET_DRY_RUN_ROLLED_BACK" "$(grep -c RESET_DRY_RUN_ROLLED_BACK "$WORK/out.txt")" "1"
check "dry run changed nothing (every table's row count identical)" "$(counts weysure)" "$BEFORE_COUNTS"
check "dry run left no temp objects behind" "$(val weysure "select count(*) from pg_class where relname in ('reset_class','reset_counts')")" "0"

# ---------------------------------------------------------------------------------------------
section "3. REAL RUN (DRY_RUN=false)"
runjob weysure v_migrate_local false
sed -n '/^--- per table/,/^--- what stays: the owner/p' "$WORK/out.txt" | grep -v '^TRUNCATE'
tail -3 "$WORK/out.txt"
check "real run exits 0" "$RC" "0"
check "real run ends with RESET_COMMITTED" "$(grep -c RESET_COMMITTED "$WORK/out.txt")" "1"
AFTER_COUNTS=$(counts weysure)
echo "after: $AFTER_COUNTS" | fold -w 200
WIPED_NONEMPTY=0
for t in $(val weysure "select tablename from pg_tables where schemaname='public' and tablename not in ('alembic_version','settings','delivery_method_settings','kyc_tier_limits','risk_hold_settings','escrow_settings','admins','mfa_factors','mfa_recovery_codes','admin_audit_logs')"); do
  n=$(val weysure "select count(*) from public.\"$t\""); [[ "$n" == 0 ]] || { echo "  not empty: $t=$n"; WIPED_NONEMPTY=$((WIPED_NONEMPTY+1)); }
done
check "no wipe table has a row left" "$WIPED_NONEMPTY" "0"
check "owner admin row, his factors and recovery codes, all config rows (apart from the updated_by pointers) and alembic_version are byte-identical" "$(kept_hash weysure)" "$BEFORE_HASH"
check "exactly 1 admin remains and it is the owner" "$(val weysure "select count(*)||':'||min(email) from admins")" "1:beyrichq@gmail.com"
check "owner keeps his $OWNER_FACTORS factors (authenticator app + passkey) and $OWNER_CODES recovery codes; nobody else's remain" "$(val weysure "select (select count(*) from mfa_factors)||'/'||(select count(*) from mfa_recovery_codes)")" "$OWNER_FACTORS/$OWNER_CODES"
check "alembic_version still $HEAD" "$(val weysure "select version_num from alembic_version")" "$HEAD"
check "config rows point at no deleted admin (updated_by cleared)" "$(val weysure "select (select count(*) from kyc_tier_limits where updated_by_admin_id is not null)+(select count(*) from risk_hold_settings where updated_by_id is not null)+(select count(*) from delivery_method_settings where updated_by_id is not null)+(select count(*) from escrow_settings where updated_by_id is not null)")" "0"
check "one audit row: production_data_reset, by the owner" "$(val weysure "select count(*)||':'||min(action)||':'||(min(admin_id)=max(admin_id) and min(admin_id)='$OWNER_ID')::text||':'||min(details) from admin_audit_logs")" "1:production_data_reset:true:production data reset, kept 1 admin"
check "foreign keys are intact (no orphan: every FK in the catalog still validated)" "$(val weysure "select count(*) from pg_constraint where contype='f' and not convalidated")" "0"
check "sessions and refresh tokens of the owner are gone (fresh sign-in required)" "$(val weysure "select (select count(*) from auth_sessions)+(select count(*) from refresh_tokens)")" "0"
AFTER1_HASH_ALL=$(dumpsum weysure)

# ---------------------------------------------------------------------------------------------
section "4. SECOND REAL RUN: idempotent, changes nothing (not even a second audit row)"
runjob weysure v_migrate_local false
grep -E "NOTHING_TO_RESET|RESET_COMMITTED" "$WORK/out.txt"
check "second run exits 0" "$RC" "0"
check "second run says NOTHING_TO_RESET" "$(grep -c NOTHING_TO_RESET "$WORK/out.txt")" "1"
check "whole-database data dump identical before/after the second run" "$(dumpsum weysure)" "$AFTER1_HASH_ALL"
check "still exactly one audit row" "$(val weysure "select count(*) from admin_audit_logs")" "1"
runjob weysure v_migrate_local true
check "a dry run after the real run also says NOTHING_TO_RESET" "$(grep -c NOTHING_TO_RESET "$WORK/out.txt")" "1"

# ---------------------------------------------------------------------------------------------
section "4b. the owner can sign in and use the console on the wiped database (the app's own HTTP routes)"
set +e
(cd "$API" && "$PY" "$HERE/owner_signin_check.py" verify "$SIGNIN_URL" "$WORK/totp-secret") 2>&1 | grep -v -i -E "^(INFO|WARNING|DEBUG)|deprecat"
SIGNIN_RC=${PIPESTATUS[0]}
set -e
check "owner sign-in script exit code" "$SIGNIN_RC" "0"

# ---------------------------------------------------------------------------------------------
section "5. GUARDS: each refusal exits non-zero and leaves every row where it was"
refuse(){  # name, db, user, dry, expected message fragment, [extra docker env]
  local name=$1 db=$2 user=$3 dry=$4 frag=$5; shift 5
  local pre; pre=$(dumpsum "$db")
  runjob "$db" "$user" "$dry" "$@"
  echo "  output: $(grep -m1 -E 'REFUSED|ERROR|POST-CHECK' "$WORK/out.txt" | cut -c1-170)"
  check "$name: exit non-zero" "$([[ $RC -ne 0 ]] && echo yes || echo no)" "yes"
  check "$name: message mentions '$frag'" "$(grep -c -- "$frag" "$WORK/out.txt" | sed 's/^[1-9].*/found/')" "found"
  check "$name: no RESET_COMMITTED printed" "$(grep -c RESET_COMMITTED "$WORK/out.txt")" "0"
  check "$name: data unchanged" "$(dumpsum "$db")" "$pre"
}
# 5a. the owner's email is not an admin in this database
pg -d postgres -c "CREATE DATABASE g_noadmin TEMPLATE weysure_seeded" >/dev/null
pg -d g_noadmin -c "UPDATE admins SET email='someone-else@example.test' WHERE lower(email)='beyrichq@gmail.com'" >/dev/null
refuse "owner admin missing from a database full of data" g_noadmin v_migrate_local false "expected exactly 1 admin"
# 5b. a fresh migrated schema (no admin at all) with one probe row that must survive
mkdb g_fresh; pg -d g_fresh -c "INSERT INTO settings (key, value) VALUES ('probe','1')" >/dev/null
refuse "fresh schema without any admin" g_fresh v_migrate_local false "expected exactly 1 admin"
check "probe row still there" "$(val g_fresh "select value from settings where key='probe'")" "1"
# 5c. wrong database name
pg -d postgres -c "CREATE DATABASE weysure_other TEMPLATE weysure_seeded" >/dev/null
refuse "database name is not weysure" weysure_other v_migrate_local false "connected to database" -e EXPECT_DB=weysure
# 5d. DRY_RUN garbage
refuse "DRY_RUN=maybe" weysure_seeded v_migrate_local maybe "DRY_RUN must be exactly true or false"
refuse "DRY_RUN empty" weysure_seeded v_migrate_local "" "DRY_RUN must be exactly true or false"
# 5e. owner not superadmin / inactive / pending / no factor
for case in "role|UPDATE admins SET role='admin' WHERE lower(email)='beyrichq@gmail.com'|not \"superadmin\"" \
            "inactive|UPDATE admins SET is_active=false WHERE lower(email)='beyrichq@gmail.com'|is not active" \
            "password pending|UPDATE admins SET password_pending=true WHERE lower(email)='beyrichq@gmail.com'|not set a password" \
            "no factor|UPDATE mfa_factors SET disabled_at=now() WHERE subject_type='admin' AND subject_id=(SELECT id FROM admins WHERE lower(email)='beyrichq@gmail.com')|no confirmed second factor" \
            "two admins with the owner email|INSERT INTO admins (id,email,hashed_password,role,created_at,updated_at) VALUES ('dup','BeyrichQ@Gmail.com','x','admin',now(),now())|found 2"; do
  IFS='|' read -r label sql frag <<<"$case"
  db="g_$(echo "$label" | tr -c '[:lower:]' '_' | cut -c1-12)"
  pg -d postgres -c "CREATE DATABASE $db TEMPLATE weysure_seeded" >/dev/null; pg -d "$db" -c "$sql" >/dev/null
  refuse "owner admin: $label" "$db" v_migrate_local false "$frag"
done
# 5f. a table nobody classified (a future migration)
pg -d postgres -c "CREATE DATABASE g_newtable TEMPLATE weysure_seeded" >/dev/null
pg -d g_newtable -c "SET ROLE weysure_owner; CREATE TABLE brand_new_feature (id int)" >/dev/null
refuse "an unclassified table exists (future migration)" g_newtable v_migrate_local false "not classified"
# 5g. a kept table gained a foreign key to a wiped table: TRUNCATE (no CASCADE) refuses, rolls back
pg -d postgres -c "CREATE DATABASE g_fk TEMPLATE weysure_seeded" >/dev/null
pg -d g_fk -c "ALTER TABLE settings ADD COLUMN owner_ref text REFERENCES users(id)" >/dev/null
refuse "a kept table references a wiped table (no CASCADE: Postgres refuses)" g_fk v_migrate_local false "cannot truncate a table referenced in a foreign key"
# 5g2. a table the Job's database user does not own (so cannot TRUNCATE)
pg -d postgres -c "CREATE DATABASE g_notowner TEMPLATE weysure_seeded" >/dev/null
pg -d g_notowner -c "ALTER TABLE users OWNER TO postgres" >/dev/null
refuse "the database user lacks TRUNCATE on a table" g_notowner v_migrate_local false "lacks the privilege"
# 5h. the API's own login (weysure_app: DML only) cannot do this
refuse "run as weysure_app (DML only: the guard refuses before any change)" weysure_seeded v_app_local false "lacks the privilege"

# 5i. positive: a stale reset record written by another admin must not block deleting that admin
pg -d postgres -c "CREATE DATABASE g_stale TEMPLATE weysure_seeded" >/dev/null
pg -d g_stale -c "INSERT INTO admin_audit_logs (id, admin_id, action, timestamp, details) VALUES ('stale-reset', 'adm-qa-0002', 'production_data_reset', now(), 'someone else')" >/dev/null
runjob g_stale v_migrate_local false
check "stale reset record by another admin: real run exits 0" "$RC" "0"
check "  and leaves 1 admin and exactly the new audit row by the owner" "$(val g_stale "select (select count(*) from admins)||':'||(select count(*) from admin_audit_logs where admin_id='adm-owner-0001')||':'||(select count(*) from admin_audit_logs)")" "1:1:1"

# ---------------------------------------------------------------------------------------------
section "6. what the reset leaves behind works: the app's own write paths on the wiped database"
pg -d weysure -c "INSERT INTO jobs (id, kind, subject_type, subject_id, dedupe_key, payload, run_at, status, attempts, max_attempts, created_at, updated_at) VALUES ('j1','wallet.reconciliation','wallet','wallet.reconciliation','wallet.reconciliation','{}',now(),'pending',0,8,now(),now())" >/dev/null
check "a job can be inserted again (jobs table usable, dedupe index intact)" "$(val weysure "select count(*) from jobs")" "1"
echo "  sequences in use before the reset: $BEFORE_SEQ"
check "RESTART IDENTITY: sequences were reset" "$(val weysure "select count(*) from pg_sequences where schemaname='public' and last_value is not null")" "0"
pg -d weysure -c "DELETE FROM jobs" >/dev/null

section "RESULT"
if [[ $FAILS -eq 0 ]]; then echo "ALL CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; exit 1; fi
