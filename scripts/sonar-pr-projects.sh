#!/usr/bin/env bash
# Sonar option 2 (decision 2026-10-09): PR analyses go to their own projects so they stop
# changing main's issue history (Community Edition = one branch per project).
# Creates <key>-pr for each main project, copying visibility, quality gate, quality
# profiles and the new-code definition from the main project, then prints both side
# by side. Idempotent. Dry run unless --apply.
#
#   bash scripts/sonar-pr-projects.sh            # read-only: show what would change
#   bash scripts/sonar-pr-projects.sh --apply    # create / align
#
# Needs: kubectl to beyric-prod (port-forward), an admin USER token from
# sonar.beyrictech.com > My Account > Security (type "User", expiry 1 day), pasted at the
# prompt (never echoed, never stored). Revoke it afterwards.
set -euo pipefail
APPLY=false; [[ "${1:-}" == "--apply" ]] && APPLY=true
PROJECTS="weysure-api weysure-web"
PORT=19000

kubectl -n sonarqube port-forward svc/sonarqube-sonarqube $PORT:9000 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -sf "localhost:$PORT/api/system/status" >/dev/null && break; sleep 1; done

read -rsp "SonarQube admin user token: " TOKEN; echo
[[ -n "$TOKEN" ]] || { echo "no token"; exit 1; }
api(){ local m=$1 p=$2; shift 2; curl -sf -H "Authorization: Bearer $TOKEN" -X "$m" "localhost:$PORT/api/$p" "$@"; }
api GET authentication/validate | jq -e '.valid' >/dev/null || { echo "token rejected"; exit 1; }

gate(){ api GET "qualitygates/get_by_project?project=$1" | jq -r '.qualityGate.name'; }
profiles(){ api GET "qualityprofiles/search?project=$1" | jq -r '.profiles[] | "\(.language)\t\(.name)\t\(.isDefault)"' | sort; }
newcode(){ api GET "new_code_periods/show?project=$1" | jq -r '[.type, (.value // "-"), (.inherited|tostring)] | @tsv'; }
visibility(){ api GET "components/show?component=$1" | jq -r '.component.visibility'; }
exists(){ api GET "components/show?component=$1" >/dev/null 2>&1; }
run(){ if $APPLY; then echo "  APPLY: $*"; "$@" >/dev/null; else echo "  would: $*"; fi; }

for main in $PROJECTS; do
  pr="$main-pr"
  echo "== $main -> $pr"
  vis=$(visibility "$main"); g=$(gate "$main")
  if exists "$pr"; then echo "  $pr exists"; else run api POST projects/create -d "project=$pr" -d "name=$pr" -d "visibility=$vis"; fi
  if ! exists "$pr"; then
    echo "  (dry run) would then copy from $main: gate=$g, new code=$(newcode "$main" | tr '\t' ' ')"
    profiles "$main" | sed 's/^/    profile: /'
    continue
  fi
  [[ "$(gate "$pr")" == "$g" ]] || run api POST qualitygates/select -d "projectKey=$pr" --data-urlencode "gateName=$g"
  while IFS=$'\t' read -r lang name isdef; do
    [[ "$isdef" == "true" ]] && continue      # default profiles apply automatically
    run api POST qualityprofiles/add_project -d "project=$pr" -d "language=$lang" --data-urlencode "qualityProfile=$name"
  done < <(profiles "$main")
  IFS=$'\t' read -r nct ncv nci < <(newcode "$main")
  if [[ "$nci" == "false" && "$(newcode "$pr")" != "$(newcode "$main")" ]]; then   # main has its own setting: copy it
    if [[ "$ncv" == "-" ]]; then run api POST new_code_periods/set -d "project=$pr" -d "type=$nct"
    else run api POST new_code_periods/set -d "project=$pr" -d "type=$nct" -d "value=$ncv"; fi
  fi
  echo "  --- compare (main | pr)"
  printf '  visibility   %s | %s\n' "$vis" "$(visibility "$pr")"
  printf '  gate         %s | %s\n' "$g" "$(gate "$pr")"
  printf '  new code     %s | %s\n' "$(newcode "$main")" "$(newcode "$pr")"
  if diff <(profiles "$main") <(profiles "$pr") >/dev/null; then echo "  profiles     identical"
  else echo "  profiles differ:"; diff <(profiles "$main") <(profiles "$pr") | sed 's/^/    /' || true; fi
  printf '  scan groups  %s | %s\n' \
    "$(api GET "permissions/groups?projectKey=$main&permission=scan" | jq -r '[.groups[]|select(.permissions|index("scan"))|.name]|join(",")')" \
    "$(api GET "permissions/groups?projectKey=$pr&permission=scan" | jq -r '[.groups[]|select(.permissions|index("scan"))|.name]|join(",")')"
done
echo "Done. Revoke the token in My Account > Security."
