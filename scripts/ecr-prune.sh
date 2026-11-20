#!/usr/bin/env bash
# Prunes the Weysure ECR repos. DRY RUN unless --apply is given. Runbook: COST_CONTROLS.md, "ECR image retention".
#
# Why a script and not a lifecycle rule: an ECR lifecycle rule can only EXPIRE images that match a tag
# pattern. It cannot exempt a tag ("never expire what gitops points at"), and the only wildcard is '*',
# so it cannot tell a 12-hex main SHA from a 64-hex Kaniko cache tag. This script can do both.
#
# For each repo it keeps (never deletes):
#   - the newest KEEP_MAIN main-build images (12-hex SHA tags)
#   - every tag in a gitops images.yaml on origin/main, in any environment (prod, stage)
#   - the previous KEEP_PROMOTED promoted tags per environment file (rollback targets, from git history)
#   - every image a pod in the cluster runs now (kubectl get pods, read-only) - if the cluster is reachable
#   - untagged, PR/branch and any other tag shape (the lifecycle policy owns those)
# It deletes: main-build images outside that set, and Kaniko cache images (64-hex) older than CACHE_DAYS.
# It refuses to run if a tag in prod images.yaml is not found in the repo (something is wrong; stop).
#
# Usage:  scripts/ecr-prune.sh            # report only, deletes nothing
#         scripts/ecr-prune.sh --apply    # deletes (human-run, see HUMAN_GATED_COMMANDS.md)
# Env:    GITOPS_DIR (default ../plateng-gitops next to this repo)  KEEP_MAIN=30  KEEP_PROMOTED=10  CACHE_DAYS=14
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-beyric-admin} AWS_REGION=${AWS_REGION:-us-east-1} AWS_PAGER=""
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
HERE=$(cd "$(dirname "$0")" && pwd)
export GITOPS_DIR=${GITOPS_DIR:-$HERE/../../plateng-gitops}
export KEEP_MAIN=${KEEP_MAIN:-30} KEEP_PROMOTED=${KEEP_PROMOTED:-10} CACHE_DAYS=${CACHE_DAYS:-14} APPLY
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS session expired - run: aws sso login --profile $AWS_PROFILE"; exit 1; }
git -C "$GITOPS_DIR" fetch origin --quiet || { echo "cannot fetch $GITOPS_DIR"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; export W
for r in weysure-api weysure-web; do
  aws ecr describe-images --repository-name "$r" \
    --query 'imageDetails[].{d:imageDigest,t:imageTags,p:imagePushedAt,s:imageSizeInBytes}' --output json > "$W/$r.json"
done
if kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' > "$W/live.txt" 2>/dev/null; then
  echo "cluster reachable: $(grep -c . "$W/live.txt") container images read from running pods"
else
  : > "$W/live.txt"; echo "WARNING: cluster not reachable - the live-pod guard is OFF (gitops guard still on)"
fi
python3 - <<'PY'
import json, os, re, subprocess, datetime
W, G = os.environ["W"], os.environ["GITOPS_DIR"]
KEEP_MAIN, KEEP_PROM, CACHE_DAYS = (int(os.environ[k]) for k in ("KEEP_MAIN", "KEEP_PROMOTED", "CACHE_DAYS"))
APPLY = os.environ["APPLY"] == "1"
git = lambda *a: subprocess.check_output(["git", "-C", G, *a], text=True)
files = [f for f in git("ls-tree", "-r", "--name-only", "origin/main").split() if f.endswith("/images.yaml")]
KEY = {"weysure-api": "api", "weysure-web": "web"}
tag_of = lambda txt, k: (m.group(1) if (m := re.search(rf'^{k}:\s*\n\s*tag:\s*"?([0-9A-Za-z._-]+)"?', txt, re.M)) else None)
current = {r: set() for r in KEY}; previous = {r: set() for r in KEY}; prod_current = {}
for f in files:
    for r, k in KEY.items():
        cur = tag_of(git("show", f"origin/main:{f}"), k)
        if cur: current[r].add(cur)
        if cur and "/prod/" in f: prod_current[r] = cur
        seen = []
        for h in git("log", "origin/main", "--format=%H", "--", f).split():
            t = tag_of(git("show", f"{h}:{f}"), k)
            if t and t not in seen: seen.append(t)
            if len(seen) > KEEP_PROM + 1: break
        previous[r].update(seen[:KEEP_PROM + 1])   # current + the previous KEEP_PROM
live = open(W + "/live.txt").read().split()
now = datetime.datetime.now(datetime.timezone.utc)
HEX12, HEX64 = re.compile(r"^[0-9a-f]{12}$"), re.compile(r"^[0-9a-f]{64}$")
gb = lambda n: f"{n/1e9:6.2f} GB"
total_del = 0; plan = {}
for r in KEY:
    imgs = json.load(open(f"{W}/{r}.json"))
    for i in imgs: i["pushed"] = datetime.datetime.fromisoformat(i["p"]).astimezone(datetime.timezone.utc)
    tags_present = {t for i in imgs for t in (i["t"] or [])}
    if prod_current.get(r) not in tags_present:
        raise SystemExit(f"STOP {r}: prod images.yaml tag {prod_current.get(r)!r} is not in the repo; refusing to prune")
    live_tags = {x.rsplit(":", 1)[1] for x in live if f"/{r}:" in x}
    main = sorted((i for i in imgs if i["t"] and any(HEX12.match(t) for t in i["t"])), key=lambda i: i["pushed"], reverse=True)
    protected = current[r] | previous[r] | live_tags | {t for i in main[:KEEP_MAIN] for t in i["t"]}
    dele, why = [], {}
    for i in imgs:
        ts = i["t"] or []
        if not ts or any(t in protected for t in ts): continue
        if any(HEX12.match(t) for t in ts): dele.append(i); why[i["d"]] = "main build outside newest-%d / gitops / rollback / live" % KEEP_MAIN
        elif any(HEX64.match(t) for t in ts) and (now - i["pushed"]).days >= CACHE_DAYS: dele.append(i); why[i["d"]] = f"Kaniko cache older than {CACHE_DAYS}d"
    bad = [i for i in dele if any(t in protected for t in (i["t"] or []))]
    assert not bad, "BUG: a protected image is in the delete set"
    size = lambda xs: sum(i["s"] for i in xs)
    kinds = lambda xs: (sum(1 for i in xs if any(HEX12.match(t) for t in i["t"])), sum(1 for i in xs if any(HEX64.match(t) for t in i["t"])))
    print(f"\n== {r}: {len(imgs)} images ({gb(size(imgs))} as listed)")
    print(f"   protected tags: {len(protected)}  (gitops now {sorted(current[r])}, live pods {sorted(live_tags)}, rollback window {len(previous[r])})")
    m, c = kinds(dele)
    print(f"   would delete {len(dele)}: {m} main builds + {c} cache layers = {gb(size(dele))} as listed -> keeps {len(imgs)-len(dele)}")
    print(f"   prod tag {prod_current[r]} stays: {all(prod_current[r] not in (i['t'] or []) for i in dele)}")
    plan[r] = dele; total_del += len(dele)
print(f"\nTOTAL to delete: {total_del}   mode: {'APPLY' if APPLY else 'DRY RUN (nothing deleted)'}")
if APPLY:
    for r, dele in plan.items():
        for n in range(0, len(dele), 100):
            batch = [{"imageDigest": i["d"]} for i in dele[n:n + 100]]
            out = json.loads(subprocess.check_output(["aws", "ecr", "batch-delete-image", "--repository-name", r, "--image-ids", json.dumps(batch), "--output", "json"], text=True))
            print(f"   {r}: deleted {len(out.get('imageIds', []))}, failures {len(out.get('failures', []))}")
            for f in out.get("failures", []): print("     FAIL", f)
PY
