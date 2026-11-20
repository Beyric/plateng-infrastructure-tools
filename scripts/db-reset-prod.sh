#!/usr/bin/env bash
# Run the one-off Weysure PRODUCTION DATA RESET (db-reset-prod-v1): wipes every table except the config
# tables and the owner's admin account. The SQL and what it keeps: docs/sop/2026-11-20-prod-data-reset.md.
#
#   scripts/db-reset-prod.sh dry     # runs everything, ROLLS BACK, prints per-table before/after counts
#   scripts/db-reset-prod.sh real    # the real run; refuses unless every safety check below passes
#
# The Job is the manifest in plateng-gitops (projects/weysure/manual/prod/db-reset-prod-v1-job.yaml), changed in
# two places only: its name and DRY_RUN. It runs as ServiceAccount db-migrate with a 30-minute Vault credential
# (role weysure-migrate), exactly like a migration. Argo CD does not manage it.
#
# `real` refuses unless ALL of these hold (each prints how to fix it):
#   1. a manual RDS snapshot of weysure-postgres-v2 younger than SNAPSHOT_MAX_AGE_H (default 6) and `available`
#   2. an off-AWS copy: the nightly backup CronJob succeeded in the last 26 h, or you set OFFSITE_DUMP_DONE=yes
#      after taking a manual dump (runbook DB_OFFSITE_BACKUP.md)
#   3. a `dry` run of this reset completed successfully in the last 24 h
#   4. you type RESET
# PRINT=1 prints the Job and exits (no cluster or AWS calls). DRY_SERVER=1 validates it against the API server
# (including Kyverno) and creates nothing. Results can name the owner's email: they stay in your terminal.
# Runbook: projects/weysure/docs/runbooks/PROD_DATA_RESET.md
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
NS=weysure-prod; CLUSTER=beyric-prod; RDS_ID=weysure-postgres-v2
MODE=${1:-}
case "$MODE" in dry|real) ;; *) sed -n '3,6p' "$0" | sed 's/^# *//'; exit 2 ;; esac
GITOPS=${GITOPS:-$(cd "$(dirname "$0")/../../plateng-gitops" 2>/dev/null && pwd || true)}
MANIFEST=$GITOPS/projects/weysure/manual/prod/db-reset-prod-v1-job.yaml
[[ -n "$GITOPS" && -f "$MANIFEST" ]] || { echo "plateng-gitops (with the merged reset Job) not found next to this repo; set GITOPS=/path/to/plateng-gitops"; exit 1; }
SNAPSHOT_MAX_AGE_H=${SNAPSHOT_MAX_AGE_H:-6}

age_hours(){  # ISO-8601 timestamp -> whole hours ago (python3: no GNU date on macOS)
  python3 -c 'import sys,datetime as d; t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((d.datetime.now(d.timezone.utc)-t).total_seconds()//3600))' "$1"
}

if [[ "${PRINT:-}" != 1 ]]; then
  ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
  GB=$(git -C "$GITOPS" branch --show-current 2>/dev/null || true)
  if [[ "$GB" != main && "${ALLOW_BRANCH:-}" != 1 ]]; then
    echo "plateng-gitops is on '${GB:-detached}', not main: the Job must be the merged one."
    echo "  git -C $GITOPS switch main && git -C $GITOPS pull --ff-only   (or ALLOW_BRANCH=1 to override)"; exit 1
  fi
fi

NAME="db-reset-prod-v1-$MODE-$(date -u +%Y%m%d%H%M%S)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
python3 - "$MANIFEST" "$NAME" "$MODE" > "$WORK/job.yaml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
name, mode = sys.argv[2], sys.argv[3]
def sub_once(pattern, repl, s, flags=0):
    out, n = re.subn(pattern, repl, s, count=1, flags=flags)
    assert n == 1, f"manifest changed shape: {pattern}"
    return out
text = sub_once(r"^  name: db-reset-prod-v1$", f"  name: {name}", text, re.M)
text = sub_once(r'\{ name: DRY_RUN, value: "true" \}', '{ name: DRY_RUN, value: "%s" }' % ("false" if mode == "real" else "true"), text)
# label both the Job and its pod, so the script can find earlier dry runs
text, n = re.subn(r"^(\s+)beyric\.io/job: db-reset$", rf"\1beyric.io/job: db-reset\n\1beyric.io/reset-mode: {mode}", text, flags=re.M)
assert n == 2, "expected the db-reset label twice"
sys.stdout.write(text)
PY
[[ "${PRINT:-}" == 1 ]] && { cat "$WORK/job.yaml"; exit 0; }

if [[ "$MODE" == real ]]; then
  echo "Safety checks for a REAL run:"
  # shellcheck disable=SC2016  # the backticks are JMESPath string literals, not shell
  SNAP_QUERY='sort_by(DBSnapshots[?Status==`available`], &SnapshotCreateTime)[-1].[DBSnapshotIdentifier,SnapshotCreateTime]'
  snap=$(aws rds describe-db-snapshots --db-instance-identifier "$RDS_ID" --snapshot-type manual \
    --query "$SNAP_QUERY" --output text 2>/dev/null || true)
  if [[ -z "$snap" || "$snap" == None* ]] || [[ $(age_hours "$(awk '{print $2}' <<<"$snap")") -ge $SNAPSHOT_MAX_AGE_H ]]; then
    echo "  FAIL 1. no available manual RDS snapshot of $RDS_ID younger than ${SNAPSHOT_MAX_AGE_H} h (latest: ${snap:-none})."
    echo "       aws rds create-db-snapshot --db-instance-identifier $RDS_ID --db-snapshot-identifier weysure-pre-reset-\$(date -u +%Y%m%d-%H%M)"
    echo "       aws rds wait db-snapshot-available --db-snapshot-identifier <the identifier you used>"
    exit 1
  fi
  echo "  ok   1. RDS snapshot $(awk '{print $1}' <<<"$snap") ($(age_hours "$(awk '{print $2}' <<<"$snap")") h old)"
  last=$(kubectl -n $NS get cronjob weysure-db-backup -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)
  if [[ -n "$last" && $(age_hours "$last") -lt 26 ]]; then
    echo "  ok   2. nightly off-AWS backup succeeded $(age_hours "$last") h ago"
  elif [[ "${OFFSITE_DUMP_DONE:-}" == yes ]]; then
    echo "  ok   2. you confirmed a manual off-AWS dump (OFFSITE_DUMP_DONE=yes)"
  else
    echo "  FAIL 2. no successful nightly off-AWS backup in the last 26 h (cronjob weysure-db-backup: ${last:-not found})."
    echo "       Run it now: kubectl -n $NS create job --from=cronjob/weysure-db-backup weysure-db-backup-prereset"
    echo "       then: kubectl -n $NS logs job/weysure-db-backup-prereset -c upload-retain | grep BACKUP_OK"
    echo "       (or take a manual dump per DB_OFFSITE_BACKUP.md and re-run with OFFSITE_DUMP_DONE=yes)"
    exit 1
  fi
  dry_done=$(kubectl -n $NS get jobs -l beyric.io/job=db-reset,beyric.io/reset-mode=dry \
    -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.status.completionTime}{"\n"}{end}' 2>/dev/null | sort | tail -1)
  if [[ -n "$dry_done" && $(age_hours "$dry_done") -lt 24 ]]; then
    echo "  ok   3. a dry run completed $(age_hours "$dry_done") h ago"
  else
    echo "  FAIL 3. no successful dry run in the last 24 h. Run:  scripts/db-reset-prod.sh dry   and read its table."
    exit 1
  fi
fi

echo
echo "Job $NAME in $NS (identity db-migrate / Vault weysure-migrate)"
if [[ "$MODE" == real ]]; then echo "  REAL RUN: deletes all data except the owner's admin account and the config tables. It commits."
else echo "  DRY RUN: runs every step, then rolls back. Nothing is changed."; fi
if [[ "${DRY_SERVER:-}" == 1 ]]; then kubectl create -f "$WORK/job.yaml" --dry-run=server -o name | sed 's/$/  (server dry run: accepted, nothing created)/'; exit 0; fi
if [[ "$MODE" == real ]]; then read -r -p "This DELETES production data. Type RESET to run: " a; [[ "$a" == RESET ]] || { echo "not run"; exit 1; }
else read -r -p "Run the dry run? [y/N] " a; [[ "$a" == y ]] || { echo "not run"; exit 1; }; fi

kubectl create -f "$WORK/job.yaml" >/dev/null
echo "created job/$NAME; waiting (Vault login, then the reset; up to 15 min)..."
st=""
for _ in $(seq 1 180); do
  st=$(kubectl get job "$NAME" -n $NS -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
  [[ "$st" == *Complete* || "$st" == *Failed* ]] && break; sleep 5
done
echo "---------------- output ----------------"
kubectl logs -n $NS "job/$NAME" -c reset 2>&1 | grep -v -i -E 'DATABASE_URL|password=|postgresql://' || true
echo "----------------------------------------"
if [[ "$st" == *Complete* ]]; then
  echo "OK: job/$NAME completed (kept 7 days for its logs)."
  if [[ "$MODE" == real ]]; then
    echo "NEXT: restart the worker so its recurring jobs are scheduled again, then run the after-checks in the runbook:"
    echo "  kubectl -n $NS rollout restart deployment/api-worker"
  else
    echo "NEXT: read the table above. If it is what you want: take the RDS snapshot, then  scripts/db-reset-prod.sh real"
  fi
else
  echo "FAILED or timed out: job/$NAME ($st). Nothing was committed by a failed run (one transaction)."
  echo "  kubectl describe job $NAME -n $NS ; kubectl logs -n $NS job/$NAME -c reset ; kubectl logs -n $NS job/$NAME -c vault-agent-init"
  exit 1
fi
