#!/usr/bin/env bash
# Restore drill, part 2: prove the production database can be restored to a point in time.
# Runbook: projects/weysure/docs/runbooks/RESTORE_DRILL.md
#
# Creates a SECOND instance, <db>-drill, from the automated backups; compares it with
# production from inside the cluster (read-only on both); deletes it.
# Production is never modified: this script has no command that names the
# production instance except "describe" and "restore FROM".
# Cost: db.t4g.micro for under an hour - a few cents.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER=beyric-prod; DB=${DB:-weysure-postgres-v2}; TARGET="$DB-drill"; NS=weysure-prod
MASTER_SECRET_ARN=${MASTER_SECRET_ARN:-"arn:aws:secretsmanager:us-east-1:767397877316:secret:rds!db-c396f13d-c4f7-4672-8d0f-4b9929190102-SIlkgw"}
JOB="db-restore-drill-$(date -u +%Y%m%d%H%M%S)"; T0=$(date +%s)
step() { echo; echo "[$1] $2  (+$(( ($(date +%s) - T0) / 60 ))m$(( ($(date +%s) - T0) % 60 ))s)"; }
status() { aws rds describe-db-instances --db-instance-identifier "$TARGET" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo absent; }

# The Job that compares the two databases. Same shape as the other one-shot database
# Jobs (ADR-022): ServiceAccount db-bootstrap reads the master secret through Pod
# Identity; label db-maintenance selects the NetworkPolicy that allows RDS + HTTPS.
# A point-in-time restore keeps the master password of the source, so one secret opens both.
render_job() {
cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
  labels: { beyric.io/purpose: restore-drill }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  template:
    metadata:
      labels: { app.kubernetes.io/name: db-maintenance }
    spec:
      serviceAccountName: db-bootstrap
      restartPolicy: Never
      nodeSelector: { node-role: workload }
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: scratch
          emptyDir: { medium: Memory }
      initContainers:
        - name: fetch-master-secret
          image: public.ecr.aws/aws-cli/aws-cli:2.22.35
          securityContext: &sc
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities: { drop: [ALL] }
          env:
            - { name: AWS_REGION, value: $AWS_REGION }
            - { name: HOME, value: /scratch }
            - { name: SECRET_ARN, value: "$MASTER_SECRET_ARN" }
          command: ["sh", "-ec"]
          args:
            - |
              umask 077
              aws secretsmanager get-secret-value --secret-id "\$SECRET_ARN" --query SecretString --output text > /scratch/master.json
              echo "master secret fetched"
          resources: { requests: { cpu: 50m, memory: 128Mi }, limits: { memory: 256Mi } }
          volumeMounts: [{ name: scratch, mountPath: /scratch }]
      containers:
        - name: compare
          image: postgres:16-alpine
          securityContext: *sc
          env:
            - { name: PROD_HOST, value: "$1" }
            - { name: DRILL_HOST, value: "$2" }
            - { name: PGPORT, value: "5432" }
            - { name: PGDATABASE, value: weysure }
            - { name: PGSSLMODE, value: require }
            - { name: PGCONNECT_TIMEOUT, value: "15" }
            # Both connections are read-only at the session level: a write would be refused.
            - { name: PGOPTIONS, value: "-c default_transaction_read_only=on" }
            - { name: HOME, value: /scratch }
          command: ["sh", "-ec"]
          args:
            - |
              export PGUSER=\$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' /scratch/master.json)
              export PGPASSWORD=\$(sed -n 's/.*"password":"\([^"]*\)".*/\1/p' /scratch/master.json | sed 's/\\\\\\\\/\\\\/g')
              rm -f /scratch/master.json
$(compare_script | sed 's/^/              /')
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { memory: 128Mi } }
          volumeMounts: [{ name: scratch, mountPath: /scratch }]
YAML
}

# Runs inside the Job. Needs PROD_HOST, DRILL_HOST and the PG* variables. Prints
# names and counts only. PASS = same schema version and the same set of tables.
# Row counts may differ by whatever was written after the restore point.
compare_script() {
cat <<'SH'
cat > /scratch/q.sql <<'SQL'
select 'schema_version=' || coalesce((select string_agg(version_num, ',' order by version_num) from alembic_version), 'none');
select 'tables=' || count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE';
select 'app_roles=' || count(*) from pg_roles where rolname in ('weysure_owner', 'weysure_app', 'vault');
select 'rows.' || table_name || '=' ||
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by table_name;
SQL
PGHOST="$PROD_HOST"  psql -v ON_ERROR_STOP=1 -At -f /scratch/q.sql > /scratch/prod.txt
PGHOST="$DRILL_HOST" psql -v ON_ERROR_STOP=1 -At -f /scratch/q.sql > /scratch/drill.txt
echo "--- restored copy"
grep -v '^rows\.' /scratch/drill.txt
echo "rows_total=$(grep '^rows\.' /scratch/drill.txt | awk -F= '{s+=$2} END {print s+0}')"
echo "--- differences from production"
awk -F= 'NR==FNR { p[$1]=$2; next } { d[$1]=$2 }
  END { for (k in p) if (!(k in d)) print k ": production=" p[k] " restored=MISSING"; else if (p[k] != d[k]) print k ": production=" p[k] " restored=" d[k]
        for (k in d) if (!(k in p)) print k ": production=MISSING restored=" d[k] }' /scratch/prod.txt /scratch/drill.txt | sort > /scratch/diff.txt
if [ -s /scratch/diff.txt ]; then cat /scratch/diff.txt; else echo "none"; fi
same() { [ "$(grep "^$1" /scratch/prod.txt)" = "$(grep "^$1" /scratch/drill.txt)" ]; }
names() { grep '^rows\.' "$1" | cut -d= -f1; }
if same schema_version= && same tables= && same app_roles= && [ "$(names /scratch/prod.txt)" = "$(names /scratch/drill.txt)" ] \
   && [ "$(grep '^tables=' /scratch/drill.txt)" != "tables=0" ]; then
  echo "DRILL_RESULT=PASS"
else
  echo "DRILL_RESULT=FAIL"; exit 1
fi
SH
}

if [[ "${1:-}" == "--render" ]]; then render_job "${2:-prod.example}" "${3:-drill.example}"; exit 0; fi
if [[ "${1:-}" == "--compare-script" ]]; then compare_script; exit 0; fi

ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS session expired - run: aws sso login --profile $AWS_PROFILE"; exit 1; }
[[ "$TARGET" == *-drill && "$TARGET" != "$DB" ]] || { echo "target name guard failed"; exit 1; }

step 1/6 "read the production instance (nothing is changed)"
read -r CLASS SUBNETS SG PARAMS PROD_HOST LATEST PSTATE <<< "$(aws rds describe-db-instances --db-instance-identifier "$DB" \
  --query 'DBInstances[0].[DBInstanceClass,DBSubnetGroup.DBSubnetGroupName,VpcSecurityGroups[0].VpcSecurityGroupId,DBParameterGroups[0].DBParameterGroupName,Endpoint.Address,LatestRestorableTime,DBInstanceStatus]' --output text)"
[[ "$PSTATE" == "available" ]] || { echo "  production is '$PSTATE', not available (asleep?) - wake it first"; exit 1; }
RPO_S=$(python3 -c "import sys,datetime as d; print(int((d.datetime.now(d.timezone.utc)-d.datetime.fromisoformat(sys.argv[1])).total_seconds()))" "$LATEST")
echo "  $DB: $CLASS, latest restorable time $LATEST  ($RPO_S s ago  <- the RPO)"

st=$(status)
if [[ "$st" == "absent" ]]; then
  read -r -p "  Create $TARGET from the backups of $DB (about 20 min, a few cents)? type 'drill': " a; [[ "$a" == "drill" ]] || exit 1
  step 2/6 "restore to the latest restorable time, as a new instance"
  T_RESTORE=$(date +%s)
  aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier "$DB" --target-db-instance-identifier "$TARGET" \
    --use-latest-restorable-time --db-instance-class "$CLASS" --db-subnet-group-name "$SUBNETS" --vpc-security-group-ids "$SG" \
    --db-parameter-group-name "$PARAMS" --no-multi-az --no-publicly-accessible --no-deletion-protection --no-auto-minor-version-upgrade \
    --backup-retention-period 0 --tags Key=purpose,Value=restore-drill Key=created-by,Value=drill-rds-restore.sh \
    --query 'DBInstance.DBInstanceStatus' --output text
else
  step 2/6 "$TARGET already exists (status: $st) - continuing a previous drill"
  T_RESTORE=$(date +%s)
fi
ARN=$(aws rds describe-db-instances --db-instance-identifier "$TARGET" --query 'DBInstances[0].DBInstanceArn' --output text)
aws rds list-tags-for-resource --resource-name "$ARN" --query 'TagList[?Key==`purpose`].Value' --output text | grep -qx restore-drill \
  || { echo "  $TARGET does not carry the tag purpose=restore-drill - this script did not create it. Stopping."; exit 1; }

step 3/6 "wait until it is available"
for i in $(seq 1 90); do
  st=$(status); [[ "$st" == "available" ]] && break
  (( i % 4 == 0 )) && echo "  $st ..."
  sleep 30
done
[[ "$st" == "available" ]] || { echo "  still '$st' after 45 min - look in the RDS console; run this script again to continue"; exit 1; }
DRILL_HOST=$(aws rds describe-db-instances --db-instance-identifier "$TARGET" --query 'DBInstances[0].Endpoint.Address' --output text)
T_READY=$(date +%s); echo "  available after $(( (T_READY - T_RESTORE) / 60 )) min"

step 4/6 "compare it with production, from inside the cluster (Job $JOB)"
render_job "$PROD_HOST" "$DRILL_HOST" | kubectl apply -f - >/dev/null
RESULT=""
for _ in $(seq 1 80); do
  c=$(kubectl get job "$JOB" -n $NS -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
  [[ "$c" == *Complete* || "$c" == *Failed* ]] && break; sleep 5
done
kubectl logs -n $NS "job/$JOB" -c compare 2>&1 | sed 's/^/  /' || true
kubectl logs -n $NS "job/$JOB" -c compare 2>/dev/null | grep -qx 'DRILL_RESULT=PASS' && RESULT=PASS || RESULT=FAIL
[[ "$RESULT" == "PASS" ]] || { echo "  init container:"; kubectl logs -n $NS "job/$JOB" -c fetch-master-secret 2>&1 | tail -3 | sed 's/^/    /' || true; }
kubectl delete job "$JOB" -n $NS --wait=false >/dev/null 2>&1 || true
T_VERIFIED=$(date +%s)

if [[ "$RESULT" != "PASS" || -n "${KEEP:-}" ]]; then
  step 5/6 "NOT deleting $TARGET (${KEEP:+KEEP is set}${KEEP:-the comparison did not pass}) - it costs about \$0.50 a day"
  echo "  delete it when done:"
  echo "  aws rds delete-db-instance --db-instance-identifier $TARGET --skip-final-snapshot --delete-automated-backups"
else
  step 5/6 "delete $TARGET"
  aws rds delete-db-instance --db-instance-identifier "$TARGET" --skip-final-snapshot --delete-automated-backups --query 'DBInstance.DBInstanceStatus' --output text
  aws rds wait db-instance-deleted --db-instance-identifier "$TARGET" && echo "  deleted"
fi

step 6/6 "result"
echo "  $RESULT  RDS restore drill"
echo "  RPO (newest restorable point): $RPO_S s    RTO (restore started -> data verified): $(( (T_VERIFIED - T_RESTORE) / 60 )) min"
echo "  Record both in RESTORE_DRILL.md -> Drill log."
[[ "$RESULT" == "PASS" ]]
