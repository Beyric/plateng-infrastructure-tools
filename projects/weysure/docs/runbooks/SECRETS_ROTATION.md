# Runbook — Secret rotation

## When to run this

Scheduled rotation, suspected exposure, an engineer leaving, or a credential found in git
history. If you are here because something leaked: **rotate first, investigate second.** A
rotated credential makes the investigation unhurried.

## Order matters

Rotate in this order. It is not arbitrary.

| # | Secret | Where | Blast radius if leaked |
|---|---|---|---|
| 1 | `PAYSTACK_SECRET_KEY` | Paystack → Settings → API Keys & Webhooks | **Moves money.** Always first. |
| 2 | `PAYSTACK_WEBHOOK_SECRET` | Paystack → Webhooks | Forged payment-success events |
| 3 | `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`, `SUPABASE_WEBHOOK_SECRET` | Supabase → Settings → API | Full database read/write |
| 4 | Database password | Supabase → Settings → Database → Reset | Full database read/write |
| 5 | `CLOUDINARY_API_SECRET` | Cloudinary → Settings → Security | Asset manipulation |
| 6 | `SMTP_PASSWORD` | Mail provider | Outbound mail as your domain |
| 7 | **`SECRET_KEY`** | `python3 -c "import secrets; print(secrets.token_urlsafe(64))"` | **Last — see below** |

**`SECRET_KEY` goes last** because rotating it invalidates every JWT the application has ever
issued, logging out every session simultaneously. With no users that is free. With users it is
a visible outage, so it belongs in a maintenance window.

**Money first, sessions last.** Everything between is ordered by blast radius.

## After each rotation

```bash
cd ~/Documents/beyric/projects/weysure/Weysure-API
docker compose up -d && sleep 15 && curl -fsS http://localhost:8000/api/v1/health
```

A failure here means the new value did not take. Fix it before rotating the next one — rotating
several at once turns one clear failure into an ambiguous one.

## Once Vault is live (Phase 3)

This runbook shrinks substantially:

- **Database credentials stop existing as a rotatable thing.** Vault's database engine issues a
  Postgres user valid for one hour and revokes it. There is nothing standing to rotate.
- **Static secrets** live in Vault KV v2. Update the value in Vault; External Secrets Operator
  refreshes the Kubernetes Secret; Reloader restarts the consuming pods. No `.env` edit, no
  manual restart.
- **What remains manual** is the third-party side: Paystack, Cloudinary and SMTP still require
  generating a new value in their console before writing it to Vault.

## Verification

After a full rotation, confirm nothing was missed:

```bash
gitleaks detect --source ~/Documents/beyric/projects/weysure/Weysure-API --redact --no-banner
```

History findings are expected — see `SECRET_EXPOSURE_HISTORY.md`. What matters is that no
finding corresponds to a credential that is still **live**.

## Adding application secrets (2026-10-02: Termii, Dojah, KYC)

Values are typed or generated; they never appear on screen, in shell history, in chat or in a PR.
Log in first (the token lasts 1 hour):
```bash
kubectl exec -n vault -it vault-0 -- vault login -method=userpass username=adebayo
```

**A value given by a provider** (replace `NAME` once, in both places):
```bash
printf 'NAME: '; read -rs V; echo; printf '{"NAME":"%s"}' "$V" | kubectl exec -n vault -i vault-0 -- vault kv patch secret/weysure/prod - >/dev/null; unset V; kubectl exec -n vault vault-0 -- sh -c 'echo "NAME: $(vault kv get -field=NAME secret/weysure/prod | tr -d "\n" | wc -c) chars"'
```
`kv patch` adds one key and leaves the others alone. `kv put` would replace the whole secret — never use it here.

**What happens next, by itself:** External Secrets copies the new key into the Kubernetes Secret within
an hour → Reloader sees the Secret change → `api` and `api-scheduler` do a rolling restart (old pods
serve until new ones are ready). To not wait the hour:
`kubectl annotate externalsecret weysure-app-config -n weysure-prod force-sync=$(date +%s) --overwrite`.

**Before a release that needs a new key:** the key must be in Vault first. From KYC phases 2 and 3
on, the API refuses to start without the Termii and Dojah keys; the rollout would stall (old pods
keep serving) and the migration of that release would already have run.

## Secrets that must never be rotated or lost

| Secret | Why | Copies |
|---|---|---|
| `KYC_FINGERPRINT_KEY` in `secret/weysure/prod` | HMAC key for BVN/NIN fingerprints: the one-identity-per-account check. A different key makes every verified identity look new. Different per environment. | Vault (daily snapshot to S3, KMS-encrypted) **and** Secrets Manager `platform/weysure/prod/kyc-fingerprint-key` (`break-glass.tf`) |

Generated inside Vault, never seen by anyone. The command refuses to run if the key already exists:
```bash
kubectl exec -n vault vault-0 -- sh -c 'vault kv get -field=KYC_FINGERPRINT_KEY secret/weysure/prod >/dev/null 2>&1 && { echo "KYC_FINGERPRINT_KEY already exists - NOT overwriting"; exit 1; }; K=$(vault write -field=random_bytes sys/tools/random/32 format=hex) && printf "{\"KYC_FINGERPRINT_KEY\":\"%s\"}" "$K" | vault kv patch secret/weysure/prod - >/dev/null && echo "stored: $(vault kv get -field=KYC_FINGERPRINT_KEY secret/weysure/prod | tr -d "\n" | wc -c) hex chars"'
```
Then, the same hour:
1. Snapshot, so the key is not only in Vault's live data:
   `kubectl create job -n vault --from=cronjob/vault-snapshot vault-snapshot-kyc-key-$(date +%s)`
2. Second copy (pipe, never printed), and proof that both copies are identical without showing either:
   ```bash
   kubectl exec -n vault vault-0 -- vault kv get -field=KYC_FINGERPRINT_KEY secret/weysure/prod | tr -d '\n' | aws secretsmanager put-secret-value --secret-id platform/weysure/prod/kyc-fingerprint-key --secret-string file:///dev/stdin --query VersionId --output text
   ```
   ```bash
   [ "$(kubectl exec -n vault vault-0 -- vault kv get -field=KYC_FINGERPRINT_KEY secret/weysure/prod | tr -d '\n' | shasum -a 256)" = "$(aws secretsmanager get-secret-value --secret-id platform/weysure/prod/kyc-fingerprint-key --query SecretString --output text | tr -d '\n' | shasum -a 256)" ] && echo "MATCH: both copies are identical" || echo "MISMATCH - stop and investigate"
   ```

If Vault is ever lost and restored from a snapshot older than this key: restore the key from Secrets
Manager with the first command above (`read -rs` form), **before** any API pod starts.
