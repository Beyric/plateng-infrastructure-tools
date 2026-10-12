# SOP — API email switched from Gmail SMTP to Resend (`support@weysure.com`)

**Shipped:** 2026-10-12 14:27:44 UTC (Vault `secret/weysure/prod` v11) · **Kind:** config only (Vault values + Reloader
restart), no code, image, migration or gitops change · **Cost delta:** $0 pre-launch (check the Resend plan before launch) ·
Related: developers' note `weysure/docs/platform-note-2026-10-12-resend-email.md`, our reply
`platform-reply-2026-10-12-resend-email.md`, [identity UX release](2026-10-12-identity-ux-release.md) (which asked for the sender)

**Status: live and verified in production.** Test password reset delivered from `support@weysure.com`, DKIM and SPF pass.

## What shipped

| Setting (Vault `secret/weysure/prod`) | Before (v10) | After (v11) |
|---|---|---|
| `SMTP_HOST` | Gmail (`smtp.gmail.com`) | `smtp.resend.com` |
| `SMTP_PORT` | `465` | `465` (implicit TLS, `smtplib.SMTP_SSL`) |
| `SMTP_USER` | Gmail account | `resend` (literal) |
| `SMTP_PASSWORD` | Gmail app password | Resend API key, "Sending access", domain `weysure.com` (36 chars; never printed) |
| `EMAILS_FROM_EMAIL` | Gmail address | `support@weysure.com` |

DNS (developers, Cloudflare): `weysure.com` MX `10 inbound-smtp.eu-west-1.amazonaws.com` (Resend receiving), DMARC
`v=DMARC1; p=none;`, DKIM `resend._domainkey`, bounce domain `rsend.weysure.com` (SPF `include:amazonses.com`).

## Why

Weysure-API #62 (identity UX) wanted user email from `support@weysure.com`. On 2026-10-12 morning `weysure.com` had **no MX**
(replies would bounce) and **no DMARC**, and the SMTP credentials were Gmail, which cannot send as `weysure.com`: switching
only the From address would have broken every user email (sign-up, password reset, withdrawals).

## How (key decisions)

| Decision | Why |
|---|---|
| Decoupled from #62; its own change | a sender change can fail on its own and break all email; don't let it share a release |
| Value in **Vault**, not git | the chart lists the ConfigMap then the Secret in `envFrom`; the last source wins, so a git value would be silently overridden |
| **One** `vault kv patch` for all four keys, key on stdin | separate patches could sync between writes (new host + old password = every email fails); stdin keeps the key out of history, `ps` and screen |
| `re_` shape check before writing | wrong-clipboard protection (the 10-09 placeholder incident) |
| Rollback = `vault kv rollback -version=10` | no one has to retype the old Gmail password |

Procedure as run (Adebayo; all Vault commands through the pod, never a local `vault` CLI — it has no `VAULT_ADDR`):

```bash
kubectl exec -n vault vault-0 -- vault kv metadata get -format=json secret/weysure/prod | jq '.data.current_version'   # 10
printf 'Resend API key: '; read -rs K; echo; case "$K" in re_*) printf '{"SMTP_HOST":"smtp.resend.com","SMTP_USER":"resend","EMAILS_FROM_EMAIL":"support@weysure.com","SMTP_PASSWORD":"%s"}' "$K" | kubectl exec -n vault -i vault-0 -- vault kv patch secret/weysure/prod - >/dev/null && echo "patched";; *) echo "Not a Resend key - nothing written";; esac; unset K
```

## Verification (2026-10-12)

| Check | Result |
|---|---|
| Vault values (non-secret fields read back) | `SMTP_HOST=smtp.resend.com`, `SMTP_PORT=465`, `SMTP_USER=resend`, `EMAILS_FROM_EMAIL=support@weysure.com`; `SMTP_PASSWORD` 36 chars |
| Pods hold the new env | ExternalSecret synced → Reloader restart 14:28:42 (api, api-scheduler, api-worker); release roll 14:34 also after it |
| Test password reset (14:45:22 UTC) | Loki: `POST /api/v1/auth/forgot-password … 200`, `Email sent to …`; Gmail: From `Weysure <support@weysure.com>`, **Signed by `weysure.com`** (DKIM aligned), **mailed-by `rsend.weysure.com`** (SPF pass, aligned under relaxed DMARC), TLS |
| Errors | 0 `Failed to send email` / `email failed` / SMTP lines since 14:20 |

## What went wrong (process)

**The switch was applied at 14:27, ahead of the agreed "after web #47 verified", and 6 minutes before the #62 roll.** The
Reloader restart created an extra ReplicaSet per API workload (`api-worker-7bbccf4bc5`, same image), and the #62 surge pods
then hit the namespace quota (14:34–14:36). The developers saw a "stuck" worker and an unexplained second ReplicaSet and
asked for a quota raise. Diagnosis: diff the ReplicaSet pod templates (strip `pod-template-hash`): the only change was
`reloader.stakater.com/last-reloaded-from: SECRET weysure-app-config`, which led to Vault v11 at 14:27:44. The roll had
completed at 14:37; no quota change was made. **Rule:** a config change during a release window gets announced first, so
the release watch can account for it.

## Operate / roll back

- Roll back: `kubectl exec -n vault vault-0 -- vault kv rollback -version=10 secret/weysure/prod`, then
  `kubectl -n weysure-prod annotate externalsecret weysure-app-config force-sync=$(date +%s) --overwrite` (Reloader restarts).
- Rotate the Resend key: same patch command with only `SMTP_PASSWORD`, then force-sync; revoke the old key in Resend after.
- Mail failures: Loki `{namespace="weysure-prod",container=~"api|api-worker"} |~ "Failed to send email|email failed"`.

## Follow-ups

- [ ] Developers revoke the Gmail app password after a few quiet days on Resend.
- [ ] Developers stop logging the recipient address: `Email sent to …` (INFO) and `Failed to send email to …` (ERROR) in `app/services/email.py`.
- [ ] Developers: remove the unused Resend bounce domain (`send.weysure.com` vs the live `rsend.weysure.com`), the stale Namecheap `include` in the root SPF, and add `rua=` to DMARC.
- [ ] Resend plan limits checked before launch.
- [ ] Optional: a Loki alert on `Failed to send email` (none exists; a broken sender is silent until users complain).
