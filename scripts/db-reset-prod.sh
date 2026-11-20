#!/usr/bin/env bash
# Run the one-off Weysure PRODUCTION DATA RESET (db-reset-prod-v1): wipes every table except the config
# tables and the owner's admin account. The SQL and what it keeps: docs/sop/2026-11-20-prod-data-reset.md.
#
#   scripts/db-reset-prod.sh dry     # runs everything, ROLLS BACK, prints per-table before/after counts
#   scripts/db-reset-prod.sh real    # the real run; refuses unless every safety check below passes
#
# The Job is the manifest in plateng-gitops (projects/weysure/manual/prod/db-reset-prod-v1-job.yaml), changed in
# a few places only: its name, DRY_RUN and two annotations (manifest hash, git commit). It runs as ServiceAccount
# db-migrate with a 30-minute Vault credential (role weysure-migrate), exactly like a migration. Argo CD does not
# manage it.
#
# BOTH modes refuse unless:
#   a. the plateng-gitops checkout is clean, on main, and HEAD equals origin/main (after a fetch): the Job is the merged one
#   b. deployment api-worker is scaled to 0 (the worker polls the jobs table; the reset empties it)
# `real` also refuses unless ALL of these hold (each prints how to fix it). Every age check FAILS CLOSED: a
# missing or unreadable timestamp is a failure, never a pass.
#   1. a manual RDS snapshot of weysure-postgres-v2 younger than SNAPSHOT_MAX_AGE_H (default 6) and `available`
#   2. an off-AWS copy: the nightly backup CronJob succeeded in the last 26 h, or you set OFFSITE_DUMP_DONE=yes
#      after taking a manual dump (runbook DB_OFFSITE_BACKUP.md)
#   3. a `dry` run of THIS EXACT manifest (same sha256) completed successfully in the last 24 h
#   4. you type RESET
# PRINT=1 prints the Job and exits (no cluster, AWS or git checks). DRY_SERVER=1 validates it against the API
# server (including Kyverno) and creates nothing. Results can name the owner's email: they stay in your terminal.
# Runbook: projects/weysure/docs/runbooks/PROD_DATA_RESET.md
set -euo pipefail

# ISO-8601 timestamp -> whole hours ago. Prints NOTHING (not 0) when the input is empty, unparsable or in the
# future, so callers can tell "unknown" from "recent". python3: no GNU date on macOS.
age_hours() {
  python3 -c '
import sys, datetime as d
try:
    t = d.datetime.fromisoformat(sys.argv[1].strip().replace("Z", "+00:00"))
    if t.tzinfo is None:
        sys.exit(0)
    h = int((d.datetime.now(d.timezone.utc) - t).total_seconds() // 3600)
    if h >= 0:
        print(h)
except Exception:
    pass
' "${1:-}" 2>/dev/null || true
}

# age_ok <timestamp> <max-hours>: success only for a NUMERIC age strictly below the limit. Anything else fails.
age_ok() {
  local h max=${2:-}
  [[ "$max" =~ ^[0-9]+$ ]] || return 1
  h=$(age_hours "${1:-}")
  [[ "$h" =~ ^[0-9]+$ ]] || return 1
  (( h < max ))
}

# Sourced by the repro test (scripts/weysure-data-reset/test-gates.sh): functions only, run nothing.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
NS=weysure-prod; CLUSTER=beyric-prod; RDS_ID=weysure-postgres-v2
MODE=${1:-}
case "$MODE" in dry|real) ;; *) sed -n '3,6p' "$0" | sed 's/^# *//'; exit 2 ;; esac
GITOPS=${GITOPS:-$(cd "$(dirname "$0")/../../plateng-gitops" 2>/dev/null && pwd || true)}
MANIFEST=$GITOPS/projects/weysure/manual/prod/db-reset-prod-v1-job.yaml
[[ -n "$GITOPS" && -f "$MANIFEST" ]] || { echo "plateng-gitops (with the merged reset Job) not found next to this repo; set GITOPS=/path/to/plateng-gitops"; exit 1; }
SNAPSHOT_MAX_AGE_H=${SNAPSHOT_MAX_AGE_H:-6}
[[ "$SNAPSHOT_MAX_AGE_H" =~ ^[0-9]+$ ]] || { echo "SNAPSHOT_MAX_AGE_H must be a whole number of hours"; exit 1; }
fail() { echo "  FAIL $*"; exit 1; }

MANIFEST_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$MANIFEST")

if [[ "${PRINT:-}" != 1 ]]; then
  echo "Safety checks:"
  ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || fail "kubectl context is '$ctx', not $CLUSTER - aborting"
  # a. the Job must be exactly the merged one
  git -C "$GITOPS" fetch -q origin main || fail "could not fetch origin/main in $GITOPS (network or login)"
  GB=$(git -C "$GITOPS" branch --show-current 2>/dev/null || true)
  [[ "$GB" == main ]] || fail "plateng-gitops is on '${GB:-detached}', not main:  git -C $GITOPS switch main && git -C $GITOPS pull --ff-only"
  [[ -z "$(git -C "$GITOPS" status --porcelain)" ]] || fail "plateng-gitops has uncommitted or untracked changes (git -C $GITOPS status); the Job must be the merged one"
  GHEAD=$(git -C "$GITOPS" rev-parse HEAD); GORIGIN=$(git -C "$GITOPS" rev-parse origin/main)
  [[ -n "$GHEAD" && "$GHEAD" == "$GORIGIN" ]] || fail "plateng-gitops HEAD ${GHEAD:0:12} is not origin/main ${GORIGIN:0:12}:  git -C $GITOPS pull --ff-only"
  echo "  ok   a. plateng-gitops is clean, on main, at origin/main ${GHEAD:0:12}; manifest sha256 ${MANIFEST_SHA:0:12}"
  # b. the worker must be stopped
  reps=$(kubectl -n $NS get deployment api-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  [[ "$reps" == 0 ]] || fail "api-worker is not scaled to 0 (replicas: '${reps:-unknown}'):  kubectl -n $NS scale deployment/api-worker --replicas=0"
  echo "  ok   b. api-worker is scaled to 0"
else
  GHEAD=$(git -C "$GITOPS" rev-parse HEAD 2>/dev/null || echo unknown)
fi

NAME="db-reset-prod-v1-$MODE-$(date -u +%Y%m%d%H%M%S)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
python3 - "$MANIFEST" "$NAME" "$MODE" "$MANIFEST_SHA" "$GHEAD" > "$WORK/job.yaml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
name, mode, sha, head = sys.argv[2:6]
def sub_once(pattern, repl, s, flags=0):
    out, n = re.subn(pattern, repl, s, count=1, flags=flags)
    assert n == 1, f"manifest changed shape: {pattern}"
    return out
text = sub_once(r"^  name: db-reset-prod-v1$", f"  name: {name}", text, re.M)
text = sub_once(r"^  namespace: weysure-prod$", f"  namespace: weysure-prod\n  annotations:\n    beyric.io/manifest-sha256: {sha}\n    beyric.io/git-head: {head}", text, re.M)
text = sub_once(r'\{ name: DRY_RUN, value: "true" \}', '{ name: DRY_RUN, value: "%s" }' % ("false" if mode == "real" else "true"), text)
# label both the Job and its pod, so the script can find earlier dry runs
text, n = re.subn(r"^(\s+)beyric\.io/job: db-reset$", rf"\1beyric.io/job: db-reset\n\1beyric.io/reset-mode: {mode}", text, flags=re.M)
assert n == 2, "expected the db-reset label twice"
sys.stdout.write(text)
PY
[[ "${PRINT:-}" == 1 ]] && { cat "$WORK/job.yaml"; exit 0; }

if [[ "$MODE" == real ]]; then
  # 1. RDS snapshot
  # shellcheck disable=SC2016  # the backticks are JMESPath string literals, not shell
  SNAP_QUERY='sort_by(DBSnapshots[?Status==`available`], &SnapshotCreateTime)[-1].[DBSnapshotIdentifier,SnapshotCreateTime]'
  snap=$(aws rds describe-db-snapshots --db-instance-identifier "$RDS_ID" --snapshot-type manual \
    --query "$SNAP_QUERY" --output text 2>/dev/null || true)
  snap_id=""; snap_ts=""
  [[ "$snap" == None* ]] || read -r snap_id snap_ts <<<"$snap" || true
  if [[ -z "$snap_id" || -z "$snap_ts" ]] || ! age_ok "$snap_ts" "$SNAPSHOT_MAX_AGE_H"; then
    echo "  FAIL 1. no available manual RDS snapshot of $RDS_ID younger than ${SNAPSHOT_MAX_AGE_H} h with a readable time (latest: ${snap:-none})."
    echo "       aws rds create-db-snapshot --db-instance-identifier $RDS_ID --db-snapshot-identifier weysure-pre-reset-\$(date -u +%Y%m%d-%H%M)"
    echo "       aws rds wait db-snapshot-available --db-snapshot-identifier <the identifier you used>"
    exit 1
  fi
  echo "  ok   1. RDS snapshot $snap_id ($(age_hours "$snap_ts") h old)"
  # 2. off-AWS copy
  last=$(kubectl -n $NS get cronjob weysure-db-backup -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)
  if age_ok "$last" 26; then
    echo "  ok   2. nightly off-AWS backup succeeded $(age_hours "$last") h ago"
  elif [[ "${OFFSITE_DUMP_DONE:-}" == yes ]]; then
    echo "  ok   2. you confirmed a manual off-AWS dump (OFFSITE_DUMP_DONE=yes)"
  else
    echo "  FAIL 2. no successful nightly off-AWS backup in the last 26 h with a readable time (cronjob weysure-db-backup: ${last:-not found})."
    echo "       Run it now: kubectl -n $NS create job --from=cronjob/weysure-db-backup weysure-db-backup-prereset"
    echo "       then: kubectl -n $NS logs job/weysure-db-backup-prereset -c upload-retain | grep BACKUP_OK"
    echo "       (or take a manual dump per DB_OFFSITE_BACKUP.md and re-run with OFFSITE_DUMP_DONE=yes)"
    exit 1
  fi
  # 3. a successful dry run of this exact manifest
  dry_done=$(kubectl -n $NS get jobs -l beyric.io/job=db-reset,beyric.io/reset-mode=dry -o json 2>/dev/null | python3 -c '
import json, sys
sha = sys.argv[1]
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    items = []
done = sorted(i["status"]["completionTime"] for i in items
              if i.get("status", {}).get("succeeded") == 1 and i["status"].get("completionTime")
              and i["metadata"].get("annotations", {}).get("beyric.io/manifest-sha256") == sha)
print(done[-1] if done else "")
' "$MANIFEST_SHA" 2>/dev/null || true)
  if age_ok "$dry_done" 24; then
    echo "  ok   3. a dry run of this exact manifest completed $(age_hours "$dry_done") h ago"
  else
    echo "  FAIL 3. no successful dry run of THIS manifest (sha256 ${MANIFEST_SHA:0:12}) in the last 24 h. Run:  scripts/db-reset-prod.sh dry   and read its table."
    exit 1
  fi
fi

echo
echo "Job $NAME in $NS (identity db-migrate / Vault weysure-migrate)"
if [[ "$MODE" == real ]]; then echo "  REAL RUN: deletes all data except the owner's admin account and the config tables. It commits."
else echo "  DRY RUN: runs every step, then rolls back. Nothing is changed. It still takes ACCESS EXCLUSIVE locks on the tables (the API may stall up to 30 s)."; fi
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
kubectl logs -n $NS "job/$NAME" -c reset 2>&1 | grep -v -i -E 'DATABASE_URL|password=|postgresql://' | tee "$WORK/log.txt" || true
echo "----------------------------------------"
if [[ "$st" == *Complete* ]]; then
  echo "OK: job/$NAME completed (kept 7 days for its logs)."
  if [[ "$MODE" == real ]]; then
    if grep -q '^RESET_COMMITTED' "$WORK/log.txt"; then
      echo "NEXT: scale the worker back up (it re-creates its recurring jobs when it starts), then the after-checks in the runbook:"
      echo "  kubectl -n $NS scale deployment/api-worker --replicas=1"
    else
      echo "Nothing was reset by this run (see the output above). Scale the worker back up when you are done:  kubectl -n $NS scale deployment/api-worker --replicas=1"
    fi
  else
    echo "NEXT: read the table above. If it is what you want: keep api-worker at 0, take the RDS snapshot, then  scripts/db-reset-prod.sh real"
    echo "      (if you will wait more than a few hours, scale the worker back up and down again before the real run)"
  fi
else
  echo "FAILED or timed out: job/$NAME ($st). Nothing was committed by a failed run (one transaction)."
  echo "  kubectl describe job $NAME -n $NS ; kubectl logs -n $NS job/$NAME -c reset ; kubectl logs -n $NS job/$NAME -c vault-agent-init"
  exit 1
fi
