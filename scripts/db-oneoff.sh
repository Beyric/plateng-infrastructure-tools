#!/usr/bin/env bash
# Run ONE SQL statement or ONE alembic command against the weysure-prod database, as a
# one-off Job with exactly the identity of the PreSync migration: ServiceAccount
# db-migrate, Vault role weysure-migrate (30-min credential), NetworkPolicy label
# app.kubernetes.io/name=db-migrate, the chart's security context. The Job is rendered
# from plateng-gitops charts/beyric-app (templates/migration-job.yaml), so it cannot
# drift from what migrations use; only name, command and image tag change.
#
#   scripts/db-oneoff.sh <image-tag> read    "SELECT kind, status, count(*) FROM jobs GROUP BY 1, 2"
#   scripts/db-oneoff.sh <image-tag> write   "UPDATE jobs SET ... WHERE ..."
#   scripts/db-oneoff.sh <image-tag> alembic "current" | "history -r-3:" | "downgrade <rev>"
#
# read  : runs inside SET TRANSACTION READ ONLY; any write is refused by Postgres.
# write : one transaction, committed only if the statement succeeds; prints rowcount.
# alembic: runs from the image you name. A downgrade must use the image that HAS the
#          revision being removed (the newer one), never the one you roll back to.
# Every mode prints the plan and asks first; write and alembic downgrade/upgrade/stamp
# need you to type the mode word. DRY=1 validates against the API server (incl. Kyverno)
# and creates nothing; PRINT=1 prints the Job and exits (no cluster or AWS calls). Results can contain personal data: they stay in your terminal.
# Runbook: projects/weysure/docs/runbooks/DEPLOYMENT_ROLLBACK.md
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1}
NS=weysure-prod; CLUSTER=beyric-prod; REPO=weysure-api
GITOPS=${GITOPS:-$(cd "$(dirname "$0")/../../plateng-gitops" 2>/dev/null && pwd || true)}
TAG=${1:-}; MODE=${2:-}; ARG=${3:-}
usage(){ sed -n '9,11p' "$0" | sed 's/^# *//'; exit 2; }
[[ -n "$TAG" && -n "$ARG" ]] || usage
case "$MODE" in read|write|alembic) ;; *) usage ;; esac
[[ -n "$GITOPS" && -f "$GITOPS/charts/beyric-app/templates/migration-job.yaml" ]] || { echo "plateng-gitops not found next to this repo; set GITOPS=/path/to/plateng-gitops"; exit 1; }

if [[ "${PRINT:-}" != 1 ]]; then
ctx=$(kubectl config current-context); [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context is '$ctx', not $CLUSTER - aborting"; exit 1; }
aws ecr describe-images --repository-name $REPO --image-ids imageTag="$TAG" --query 'imageDetails[0].imageTags' --output text >/dev/null 2>&1 \
  || { echo "image $REPO:$TAG not found in ECR (or AWS session expired: aws sso login --profile $AWS_PROFILE)"; exit 1; }
fi

# The Job is rendered from the local gitops checkout: it must be main, as deployed.
GB=$(git -C "$GITOPS" branch --show-current 2>/dev/null || true)
if [[ "$GB" != main && "${ALLOW_BRANCH:-}" != 1 && "${PRINT:-}" != 1 ]]; then
  echo "plateng-gitops checkout is on '${GB:-detached}', not main: the Job would be rendered from unmerged chart/values."
  echo "  git -C $GITOPS switch main && git -C $GITOPS pull --ff-only   (or ALLOW_BRANCH=1 to override)"; exit 1
fi
NAME=db-oneoff-$(date -u +%Y%m%d%H%M%S)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
P=$GITOPS/projects/weysure/environments/prod
helm template weysure-api "$GITOPS/charts/beyric-app" -n $NS -f $P/apps/api/values.yaml -f $P/images.yaml \
  --set image.tag="$TAG" --show-only templates/migration-job.yaml > "$WORK/job.yaml"

# The program the container runs. Never prints DATABASE_URL; SQL comes from an env var,
# not from the shell, so quotes in the statement need no escaping.
cat > "$WORK/run.py" <<'PY'
import json, os, sys
import sqlalchemy as sa
mode, sql = os.environ["ONEOFF_MODE"], os.environ.get("ONEOFF_SQL", "")
engine = sa.create_engine(os.environ["DATABASE_URL"], poolclass=sa.pool.NullPool)
with engine.begin() as c:
    if mode == "read":
        c.execute(sa.text("SET TRANSACTION READ ONLY"))
    c.execute(sa.text("SET LOCAL statement_timeout = '60s'"))
    c.execute(sa.text("SET LOCAL lock_timeout = '10s'"))
    r = c.execute(sa.text(sql))
    if r.returns_rows:
        cols = list(r.keys()); rows = r.fetchmany(201)
        print(json.dumps({"columns": cols, "rows": [[None if v is None else str(v) for v in row] for row in rows[:200]],
                          "truncated": len(rows) > 200}))
    else:
        print(json.dumps({"rowcount": r.rowcount, "committed": True}))
PY

python3 - "$WORK/job.yaml" "$NAME" "$MODE" "$ARG" "$WORK/run.py" <<'PY'
import sys, yaml
path, name, mode, arg, runpy = sys.argv[1:]
job = yaml.safe_load(open(path))
md = job["metadata"]
md["name"] = name
md["annotations"] = {"beyric.io/purpose": f"db-oneoff {mode}"}     # no PreSync hook: a plain Job
for labels in (md["labels"], job["spec"]["template"]["metadata"]["labels"]):
    labels["app.kubernetes.io/instance"] = "db-oneoff"                # not part of the Argo app
    # app.kubernetes.io/name stays db-migrate: that label is what the NetworkPolicy allows to RDS
job["spec"]["ttlSecondsAfterFinished"] = 3600
job["spec"]["activeDeadlineSeconds"] = 600
c = job["spec"]["template"]["spec"]["containers"][0]
c["name"] = "oneoff"
load = 'set -a; . "$VAULT_ENV_FILE"; set +a; cd /app && '
if mode == "alembic":
    c["command"] = ["/bin/bash", "-c", load + 'exec alembic $ONEOFF_ALEMBIC']
    c["env"].append({"name": "ONEOFF_ALEMBIC", "value": arg})
else:
    c["command"] = ["/bin/bash", "-c", load + 'exec python -c "$ONEOFF_PY"']
    c["env"] += [{"name": "ONEOFF_MODE", "value": mode}, {"name": "ONEOFF_SQL", "value": arg},
                 {"name": "ONEOFF_PY", "value": open(runpy).read()}]
yaml.safe_dump(job, open(path, "w"), sort_keys=False)
PY

[[ "${PRINT:-}" == 1 ]] && { cat "$WORK/job.yaml"; exit 0; }
echo "Job $NAME in $NS  image $REPO:$TAG  identity db-migrate / Vault weysure-migrate  (chart from gitops ${GB:-?})"
echo "  mode:    $MODE"
echo "  command: $ARG"
if [[ "${DRY:-}" == 1 ]]; then kubectl create -f "$WORK/job.yaml" --dry-run=server -o name | sed 's/$/  (server dry run: accepted, nothing created)/'; exit 0; fi
need=""; [[ "$MODE" == write ]] && need="write"
[[ "$MODE" == alembic && "$ARG" =~ ^(downgrade|upgrade|stamp) ]] && need="alembic"
if [[ -n "$need" ]]; then read -r -p "This changes the production database. Type '$need' to run: " a; [[ "$a" == "$need" ]] || { echo "not run"; exit 1; }
else read -r -p "Run it? [y/N] " a; [[ "$a" == y ]] || { echo "not run"; exit 1; }; fi

kubectl create -f "$WORK/job.yaml" >/dev/null
echo "created job/$NAME; waiting (Vault login, then the command; up to 10 min)..."
for _ in $(seq 1 120); do
  st=$(kubectl get job "$NAME" -n $NS -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
  [[ "$st" == *Complete* || "$st" == *Failed* ]] && break; sleep 5
done
echo "---- output ----"
kubectl logs -n $NS "job/$NAME" -c oneoff 2>&1 | grep -v -i -E 'DATABASE_URL|password=|postgresql://' || true
echo "----------------"
if [[ "$st" == *Complete* ]]; then echo "OK: job/$NAME completed (kept 1 h for its logs)"; else
  echo "FAILED or timed out: job/$NAME ($st). kubectl describe job $NAME -n $NS ; kubectl logs -n $NS job/$NAME -c vault-agent-init"; exit 1; fi
