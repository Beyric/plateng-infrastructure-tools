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
cd ~/Documents/dev/weysure/Weysure-API
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
gitleaks detect --source ~/Documents/dev/weysure/Weysure-API --redact --no-banner
```

History findings are expected — see `SECRET_EXPOSURE_HISTORY.md`. What matters is that no
finding corresponds to a credential that is still **live**.
