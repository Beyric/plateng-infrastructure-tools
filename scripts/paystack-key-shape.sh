#!/usr/bin/env bash
# Read-only: show the SHAPE of the Paystack keys in Vault secret/weysure/prod, never a value.
# Prints per key: set?, length, mode prefix (sk_test_ / sk_live_ / other), and which keys are equal.
# Values stay inside jq; nothing is written to disk. Run by Adebayo (Vault exec).
set -euo pipefail
kubectl exec -n vault vault-0 -- vault kv get -format=json secret/weysure/prod | jq -r '
  .data.data as $d
  | def mode(v): if (v|startswith("sk_test_")) then "sk_test_" elif (v|startswith("sk_live_")) then "sk_live_" elif v=="" then "-" else "other" end;
  def k(n): ($d[n] // "" | gsub("^\\s+|\\s+$";""));
  ["PAYSTACK_SECRET_KEY","PAYSTACK_TEST_SECRET_KEY","PAYSTACK_LIVE_SECRET_KEY"][] as $n
  | "\($n): set=\(k($n)!="") len=\(k($n)|length) mode=\(mode(k($n)))",
  (if $n=="PAYSTACK_LIVE_SECRET_KEY" then
     "equal: SECRET==TEST \(k("PAYSTACK_SECRET_KEY")==k("PAYSTACK_TEST_SECRET_KEY") and k("PAYSTACK_SECRET_KEY")!="")  SECRET==LIVE \(k("PAYSTACK_SECRET_KEY")==k("PAYSTACK_LIVE_SECRET_KEY") and k("PAYSTACK_SECRET_KEY")!="")  TEST==LIVE \(k("PAYSTACK_TEST_SECRET_KEY")==k("PAYSTACK_LIVE_SECRET_KEY") and k("PAYSTACK_TEST_SECRET_KEY")!="")",
     "vault metadata version: \(.data.metadata.version)"
   else empty end)'
