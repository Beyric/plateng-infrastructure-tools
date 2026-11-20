#!/usr/bin/env bash
# Repro/test of the safety gates in scripts/db-reset-prod.sh. No cluster, no AWS: kubectl and aws are stubs on
# PATH, the gitops checkout is a temp git repo with a temp origin. Run:  scripts/weysure-data-reset/test-gates.sh
# Every `real` case ends at DRY_SERVER=1 (no Job is created even on the stub). Exit 0 only if every case behaves.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SCRIPT=$HERE/../db-reset-prod.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; FAILS=0
check(){ if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2', want '$3')"; FAILS=$((FAILS+1)); fi; }
iso_ago(){ python3 -c 'import sys,datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }

echo "== 1. the age helpers fail closed"
# shellcheck source=/dev/null
source "$SCRIPT"
echo "  (the old gate: an empty age is treated as 0, so  [[ \"\" -ge 6 ]]  is false and the gate PASSES: $([[ "" -ge 6 ]] && echo 'blocked' || echo 'passed'))"
for case in "empty||6" "garbage|not-a-time|6" "naive (no timezone)|2026-11-20T10:00:00|6" "future|$(iso_ago -5)|6" "too old|$(iso_ago 7)|6" "max not a number|$(iso_ago 1)|six" "fresh|$(iso_ago 2)|6"; do
  IFS='|' read -r label ts max <<<"$case"
  if age_ok "$ts" "$max"; then got=pass; else got=fail; fi
  [[ "$label" == fresh ]] && want=pass || want=fail
  check "age_ok: $label -> $want" "$got" "$want"
done
check "age_hours prints nothing for garbage (not 0)" "$(age_hours not-a-time)" ""

echo "== 2. the gates of the real script, with stubs"
mkdir -p "$T/bin" "$T/origin.git" "$T/work"
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/gitops" 2>/dev/null
M=projects/weysure/manual/prod; mkdir -p "$T/gitops/$M"
cat > "$T/gitops/$M/db-reset-prod-v1-job.yaml" <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: db-reset-prod-v1
  namespace: weysure-prod
  labels:
    app.kubernetes.io/name: db-migrate
    beyric.io/job: db-reset
spec:
  template:
    metadata:
      labels:
        app.kubernetes.io/name: db-migrate
        beyric.io/job: db-reset
    spec:
      containers:
        - name: reset
          env:
            - { name: DRY_RUN, value: "true" }
EOF
git -C "$T/gitops" add -A; git -C "$T/gitops" -c user.name=t -c user.email=t@example.test commit -q -m manifest; git -C "$T/gitops" branch -M main; git -C "$T/gitops" push -q -u origin main 2>/dev/null
SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$T/gitops/$M/db-reset-prod-v1-job.yaml")

cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
a="$*"
case "$a" in
  "config current-context") echo "arn:aws:eks:us-east-1:000000000000:cluster/beyric-prod" ;;
  *"get deployment api-worker"*) printf '%s' "${STUB_REPLICAS-0}" ;;
  *"get cronjob weysure-db-backup"*) printf '%s' "${STUB_BACKUP-}" ;;
  *"get jobs -l"*) cat "${STUB_JOBS_FILE:-/dev/null}" ;;
  *"--dry-run=server"*) echo "job.batch/stub" ;;
  *) echo "unexpected kubectl call: $a" >&2; exit 99 ;;
esac
EOF
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_SNAP-}"
EOF
chmod +x "$T/bin/kubectl" "$T/bin/aws"
dryjobs(){  # completion time, succeeded, hash -> a kubectl "get jobs -o json" body
  python3 -c 'import json,sys; ct,ok,h=sys.argv[1:4]; it={"metadata":{"annotations":{"beyric.io/manifest-sha256":h}},"status":{"succeeded":int(ok)}};
if ct: it["status"]["completionTime"]=ct
print(json.dumps({"items":[it]}))' "$1" "$2" "$3" > "$T/jobs.json"
}
run(){  # mode, then env assignments; prints the last FAIL line or OK
  local mode=$1; shift
  set +e
  out=$(env PATH="$T/bin:$PATH" GITOPS="$T/gitops" DRY_SERVER=1 STUB_JOBS_FILE="$T/jobs.json" "$@" "$SCRIPT" "$mode" 2>&1); RC=$?
  set -e
}
GOOD_SNAP="weysure-pre-reset-x $(iso_ago 1)"; GOOD_BACKUP=$(iso_ago 3)
dryjobs "$(iso_ago 1)" 1 "$SHA"
export STUB_REPLICAS=0

run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP"
check "all gates satisfied: reaches the server dry run, exit 0" "$RC:$(grep -c 'server dry run: accepted' <<<"$out")" "0:1"

run real STUB_SNAP="" STUB_BACKUP="$GOOD_BACKUP";                       check "snapshot: none -> FAIL 1" "$RC:$(grep -c 'FAIL 1' <<<"$out")" "1:1"
run real STUB_SNAP="None" STUB_BACKUP="$GOOD_BACKUP";                   check "snapshot: 'None' -> FAIL 1" "$RC:$(grep -c 'FAIL 1' <<<"$out")" "1:1"
run real STUB_SNAP="id-only" STUB_BACKUP="$GOOD_BACKUP";                check "snapshot: id without a time -> FAIL 1 (was a silent pass)" "$RC:$(grep -c 'FAIL 1' <<<"$out")" "1:1"
run real STUB_SNAP="id garbage-time" STUB_BACKUP="$GOOD_BACKUP";        check "snapshot: unreadable time -> FAIL 1 (was a silent pass)" "$RC:$(grep -c 'FAIL 1' <<<"$out")" "1:1"
run real STUB_SNAP="id $(iso_ago 7)" STUB_BACKUP="$GOOD_BACKUP";        check "snapshot: 7 h old -> FAIL 1" "$RC:$(grep -c 'FAIL 1' <<<"$out")" "1:1"

run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="";                         check "backup: no timestamp, no override -> FAIL 2 (was a silent pass)" "$RC:$(grep -c 'FAIL 2' <<<"$out")" "1:1"
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="garbage";                  check "backup: unreadable time -> FAIL 2" "$RC:$(grep -c 'FAIL 2' <<<"$out")" "1:1"
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$(iso_ago 30)";            check "backup: 30 h old -> FAIL 2" "$RC:$(grep -c 'FAIL 2' <<<"$out")" "1:1"
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="" OFFSITE_DUMP_DONE=yes;   check "backup: manual dump stated -> passes" "$RC" "0"

dryjobs "" 1 "$SHA";                      run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP"; check "dry run: no completion time -> FAIL 3 (was a silent pass)" "$RC:$(grep -c 'FAIL 3' <<<"$out")" "1:1"
dryjobs "$(iso_ago 1)" 0 "$SHA";          run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP"; check "dry run: not succeeded -> FAIL 3" "$RC:$(grep -c 'FAIL 3' <<<"$out")" "1:1"
dryjobs "$(iso_ago 30)" 1 "$SHA";         run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP"; check "dry run: 30 h old -> FAIL 3" "$RC:$(grep -c 'FAIL 3' <<<"$out")" "1:1"
dryjobs "$(iso_ago 1)" 1 "deadbeef";      run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP"; check "dry run of a DIFFERENT manifest hash -> FAIL 3" "$RC:$(grep -c 'FAIL 3' <<<"$out")" "1:1"
: > "$T/jobs.json";                       run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP"; check "dry run: kubectl returns nothing -> FAIL 3" "$RC:$(grep -c 'FAIL 3' <<<"$out")" "1:1"
dryjobs "$(iso_ago 1)" 1 "$SHA"

run real STUB_REPLICAS=1 STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP"; check "api-worker at 1 replica -> refused (real)" "$RC:$(grep -c 'not scaled to 0' <<<"$out")" "1:1"
run dry STUB_REPLICAS=1;                                                    check "api-worker at 1 replica -> refused (dry)" "$RC:$(grep -c 'not scaled to 0' <<<"$out")" "1:1"
run dry STUB_REPLICAS="";                                                   check "api-worker replicas unreadable -> refused" "$RC:$(grep -c 'not scaled to 0' <<<"$out")" "1:1"

echo "== 3. the gitops checkout must be clean, on main and equal to origin/main"
echo "# local edit" >> "$T/gitops/$M/db-reset-prod-v1-job.yaml"
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP";   check "modified manifest -> refused" "$RC:$(grep -c 'uncommitted or untracked' <<<"$out")" "1:1"
git -C "$T/gitops" checkout -q -- .
echo x > "$T/gitops/stray-file"
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP";   check "untracked file -> refused" "$RC:$(grep -c 'uncommitted or untracked' <<<"$out")" "1:1"
rm "$T/gitops/stray-file"
git clone -q "$T/origin.git" "$T/other" 2>/dev/null; echo "# new on origin" >> "$T/other/$M/db-reset-prod-v1-job.yaml"
git -C "$T/other" -c user.name=t -c user.email=t@example.test commit -q -am "newer manifest"; git -C "$T/other" push -q origin main 2>/dev/null
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP";   check "local HEAD behind origin/main (after fetch) -> refused" "$RC:$(grep -c 'is not origin/main' <<<"$out")" "1:1"
git -C "$T/gitops" pull -q --ff-only origin main 2>/dev/null
SHA2=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$T/gitops/$M/db-reset-prod-v1-job.yaml")
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP";   check "after pulling, the earlier dry run belongs to the OLD manifest -> FAIL 3" "$RC:$(grep -c 'FAIL 3' <<<"$out")" "1:1"
dryjobs "$(iso_ago 1)" 1 "$SHA2"
run real STUB_SNAP="$GOOD_SNAP" STUB_BACKUP="$GOOD_BACKUP";   check "a dry run of the new manifest -> passes" "$RC" "0"
git -C "$T/gitops" switch -q -c side; run dry;                check "not on main -> refused" "$RC:$(grep -c 'not main' <<<"$out")" "1:1"
git -C "$T/gitops" switch -q main

echo "== 4. rendering (PRINT=1 runs no checks)"
rendered=$(env PATH="$T/bin:$PATH" GITOPS="$T/gitops" PRINT=1 "$SCRIPT" real)
check "name is db-reset-prod-v1-real-<time>" "$(grep -c -E '^  name: db-reset-prod-v1-real-[0-9]{14}$' <<<"$rendered")" "1"
check "DRY_RUN is false for real" "$(grep -c 'value: "false"' <<<"$rendered")" "1"
check "manifest sha annotation is the file's sha256" "$(grep -c "beyric.io/manifest-sha256: $SHA2" <<<"$rendered")" "1"
check "mode label on the Job and the pod" "$(grep -c 'beyric.io/reset-mode: real' <<<"$rendered")" "2"
rendered=$(env PATH="$T/bin:$PATH" GITOPS="$T/gitops" PRINT=1 "$SCRIPT" dry)
check "dry render keeps DRY_RUN true" "$(grep -c 'value: "true"' <<<"$rendered")" "1"

if [[ $FAILS -eq 0 ]]; then echo "ALL GATE CASES PASSED"; else echo "$FAILS GATE CASE(S) FAILED"; exit 1; fi
