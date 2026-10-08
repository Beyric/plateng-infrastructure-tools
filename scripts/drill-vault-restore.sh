#!/usr/bin/env bash
# Restore drill, part 1: prove the newest Vault snapshot in S3 can be restored and read.
# Runbook: projects/weysure/docs/runbooks/RESTORE_DRILL.md
#
# Runs a scratch Vault in a local Docker container - NOT in the cluster. A restored
# Vault is a live clone of production: it holds the lease table and the database
# engine's connection, and would revoke "expired" leases by running DROP ROLE
# against the production database. On this machine it has no route to RDS.
# It can reach one AWS service: KMS, to decrypt (same key as production).
#
# Nothing is written to disk by Vault (tmpfs). The snapshot file and the container
# are removed on exit, however the script ends. No secret value is printed.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
BUCKET=${BUCKET:-beyric-vault-snapshots-767397877316}
KMS_KEY=${KMS_KEY:-05f4bdf7-0a2d-4432-827f-2509e4845e29}   # plateng-gitops platform/vault/values.yaml
IMAGE=${IMAGE:-hashicorp/vault:1.20.4}                      # keep equal to production
DB=${DB:-weysure-postgres-v2}
CHECK_PATH=${CHECK_PATH:-secret/weysure/prod}; EXPECT_KEYS=${EXPECT_KEYS:-15}
VAULT_USER=${VAULT_USER:-adebayo}
NAME=vault-drill; T0=$(date +%s)
WORK=$(mktemp -d); chmod 700 "$WORK"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; echo "cleanup: container and snapshot copy removed"; }
trap cleanup EXIT
v() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 "$@"; }
step() { echo; echo "[$1] $2  (+$(( $(date +%s) - T0 ))s)"; }

docker info >/dev/null 2>&1 || { echo "Docker is not running - start Docker Desktop"; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS session expired - run: aws sso login --profile $AWS_PROFILE"; exit 1; }

step 1/7 "find and download the newest snapshot"
if [[ -n "${SNAPSHOT_FILE:-}" ]]; then
  cp "$SNAPSHOT_FILE" "$WORK/vault.snap"; KEY="(local file)"; MOD=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
else
  read -r KEY MOD <<< "$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix raft/ --query 'sort_by(Contents,&LastModified)[-1].[Key,LastModified]' --output text)"
  [[ -n "$KEY" && "$KEY" != "None" ]] || { echo "no snapshot in s3://$BUCKET/raft/ - FAIL"; exit 1; }
  aws s3 cp "s3://$BUCKET/$KEY" "$WORK/vault.snap" --only-show-errors
fi
AGE_MIN=$(python3 -c "import sys,datetime as d; print(int((d.datetime.now(d.timezone.utc)-d.datetime.fromisoformat(sys.argv[1])).total_seconds()//60))" "$MOD")
echo "  $KEY  $(wc -c < "$WORK/vault.snap" | tr -d ' ') bytes, taken $AGE_MIN min ago  <- this is the RPO: changes newer than this are lost"
tar -tzf "$WORK/vault.snap" >/dev/null || { echo "  snapshot is not a readable archive - FAIL"; exit 1; }

step 2/7 "start a scratch Vault (same version, same KMS seal, storage in memory, RDS hostname black-holed)"
cat > "$WORK/config.hcl" <<HCL
disable_mlock = true
api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "http://127.0.0.1:8201"
listener "tcp" { address = "127.0.0.1:8200"  tls_disable = 1 }
storage "raft" { path = "/vault/file"  node_id = "drill" }
seal "awskms" { region = "$AWS_REGION"  kms_key_id = "$KMS_KEY" }
HCL
RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true)
docker rm -f "$NAME" >/dev/null 2>&1 || true
# Temporary credentials of this SSO session, for KMS only. Passed as an env file
# through a pipe: never on disk, never on a command line, never printed.
docker run -d --name "$NAME" --env-file <(aws configure export-credentials --format env-no-export) \
  -e AWS_REGION="$AWS_REGION" -e SKIP_SETCAP=1 --tmpfs /vault/file:uid=100,gid=1000 \
  ${RDS_HOST:+--add-host "$RDS_HOST:127.0.0.1"} \
  -v "$WORK/config.hcl:/vault/config/config.hcl:ro" -v "$WORK/vault.snap:/drill/vault.snap:ro" \
  "$IMAGE" server >/dev/null
# vault status exit codes: 0 = unsealed, 2 = sealed or not initialised yet (what we expect here), 1 = not reachable
rc=1; for _ in $(seq 1 30); do rc=0; v "$NAME" vault status >/dev/null 2>&1 || rc=$?; [[ $rc == 0 || $rc == 2 ]] && break; sleep 1; done
[[ $rc == 0 || $rc == 2 ]] || { echo "  scratch Vault did not start:"; docker logs "$NAME" 2>&1 | tail -5; exit 1; }

step 3/7 "initialise it (throw-away keys, kept in memory only)"
ROOT=$(v "$NAME" vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json | python3 -c 'import sys,json; print(json.load(sys.stdin)["root_token"])')
[[ -n "$ROOT" ]] || { echo "  init failed (KMS access?)"; docker logs "$NAME" 2>&1 | tail -5; exit 1; }
for _ in $(seq 1 30); do v "$NAME" vault status >/dev/null 2>&1 && break; sleep 1; done
echo "  initialised and unsealed through KMS"

step 4/7 "restore the snapshot over it"
v -e VAULT_TOKEN="$ROOT" "$NAME" vault operator raft snapshot restore -force /drill/vault.snap
unset ROOT   # the scratch root token died with the scratch data
ok=0; for _ in $(seq 1 60); do
  s=$(v "$NAME" vault status -format=json 2>/dev/null || true)
  [[ "$(python3 -c 'import sys,json; d=json.loads(sys.argv[1] or "{}"); print(d.get("initialized") and not d.get("sealed") and d.get("leader_address","")!="")' "$s" 2>/dev/null)" == "True" ]] && { ok=1; break; }
  sleep 2
done
[[ $ok == 1 ]] || { echo "  Vault did not come back unsealed with the restored data - FAIL"; docker logs "$NAME" 2>&1 | tail -8; exit 1; }
echo "  restored; unsealed with the production KMS key = the snapshot's keyring decrypts"

step 5/7 "log in as a PRODUCTION user ($VAULT_USER) - proves the auth data came back"
if [[ -n "${VAULT_PASSWORD_FILE:-}" ]]; then PW=$(cat "$VAULT_PASSWORD_FILE"); else read -r -s -p "  Vault password for $VAULT_USER: " PW; echo; fi
TOKEN=$(printf '%s' "$PW" | docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 "$NAME" vault write -field=token "auth/userpass/login/$VAULT_USER" password=-) || { unset PW; echo "  login failed - FAIL"; exit 1; }
unset PW
echo "  logged in"

step 6/7 "read the restored data (names and counts only)"
v -e VAULT_TOKEN="$TOKEN" "$NAME" vault kv get -format=json "$CHECK_PATH" | python3 -c '
import sys,json
d=json.load(sys.stdin)["data"]; keys=sorted(d["data"]); m=d["metadata"]; exp=int(sys.argv[1])
print("  %s: %d keys, version %s, written %sZ" % (sys.argv[2], len(keys), m["version"], m["created_time"][:19]))
print("  keys:", ", ".join(keys))
sys.exit(0 if len(keys)==exp else 3)' "$EXPECT_KEYS" "$CHECK_PATH" || { echo "  expected $EXPECT_KEYS keys - FAIL"; exit 1; }
for what in "policy list" "auth list" "secrets list"; do
  n=$(v -e VAULT_TOKEN="$TOKEN" "$NAME" vault $what -format=json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d), ":", ", ".join(sorted(d)))')
  echo "  $what -> $n"
done
unset TOKEN

step 7/7 "result"
echo "  PASS  Vault restore drill"
echo "  RPO (age of the snapshot): $AGE_MIN min    time for this drill: $(( $(date +%s) - T0 )) s"
echo "  Record both in RESTORE_DRILL.md -> Drill log."
