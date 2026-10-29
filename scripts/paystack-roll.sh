#!/usr/bin/env bash
# Roll Paystack keys in Vault secret/weysure/prod in ONE atomic patch. Values never echo, never touch argv/disk.
# Enter = leave that key unchanged. Run by Adebayo. DRY_RUN=1 prints names+lengths and writes nothing.
set -euo pipefail

ask() { printf '%s (paste, then Enter; Enter alone = unchanged): ' "$1" >&2; IFS= read -rs v || true; echo >&2; printf '%s' "$v" | tr -d '[:space:]'; }
shape() { case "$1" in "") echo "unchanged";; sk_test_*) echo "sk_test_";; sk_live_*) echo "sk_live_";; *) echo "BAD";; esac; }

SECRET=$(ask PAYSTACK_SECRET_KEY)
TEST=$(ask PAYSTACK_TEST_SECRET_KEY)
LIVE=$(ask PAYSTACK_LIVE_SECRET_KEY)

bad=0
for n in SECRET TEST LIVE; do
  v=${!n}; s=$(shape "$v"); echo "$n: len=${#v} shape=$s"
  [ "$s" = BAD ] && bad=1
done
[ "$bad" = 1 ] && { echo "A value is not sk_test_/sk_live_: nothing written."; exit 1; }
[ -z "$SECRET$TEST$LIVE" ] && { echo "Nothing entered: nothing written."; exit 1; }
if [ "${SECRET#sk_live_}" != "$SECRET" ]; then
  printf 'PAYSTACK_SECRET_KEY is a LIVE key: real money. Type LIVE to continue: ' >&2; read -r ok
  [ "$ok" = LIVE ] || { echo "Cancelled."; exit 1; }
fi

JSON=$(jq -n --arg s "$SECRET" --arg t "$TEST" --arg l "$LIVE" '
  {} | (if $s != "" then .PAYSTACK_SECRET_KEY = $s else . end)
     | (if $t != "" then .PAYSTACK_TEST_SECRET_KEY = $t else . end)
     | (if $l != "" then .PAYSTACK_LIVE_SECRET_KEY = $l else . end)')

if [ "${DRY_RUN:-}" = 1 ]; then echo "DRY RUN: would patch keys: $(printf '%s' "$JSON" | jq -r 'keys|join(", ")')"; exit 0; fi

kubectl exec -n vault vault-0 -- vault token lookup >/dev/null 2>&1 || { echo "No Vault login. Run: kubectl exec -n vault -it vault-0 -- vault login -method=userpass username=adebayo"; exit 1; }
printf '%s' "$JSON" | kubectl exec -n vault -i vault-0 -- vault kv patch secret/weysure/prod - >/dev/null
unset SECRET TEST LIVE JSON
echo "Vault patched. Next: force-sync the ExternalSecret."
