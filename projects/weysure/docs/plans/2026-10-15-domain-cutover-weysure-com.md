# Plan — move Weysure to weysure.com / api.weysure.com (2026-10-15)

**Decision (Adebayo, 2026-10-15):** web app on `weysure.com` (`www` → 301 to apex), API on `api.weysure.com`. Platform
tools stay on `*.beyrictech.com` (Grafana, Sonar, Jenkins, probe). **Why now:** prelaunch, so no external developer has
hard-coded the API host yet (`payment_url` is built from `SERVER_HOST`), and the brand matches. Keeping the tools on a
different registrable domain also means app cookies and app-domain incidents never reach them.

**Shape:** serve old and new hosts side by side → switch the settings → redirect the old web host → retire the old API
host after a soak. No downtime; every step before §6 rolls back by reverting one setting.

## 1. Read-only findings (2026-10-15 16:15 WAT)

| Check | Result | Consequence |
|---|---|---|
| `weysure.com` NS | `ian` / `jessica.ns.cloudflare.com` | Zone is live on Cloudflare ✅ |
| Apex + `www` | **Already proxied** (Cloudflare IPs); `http://` → 302, `https://` **times out** | Existing records point at a dead origin (imported at zone setup?). Find the target in the dashboard; they get **replaced** |
| `api.weysure.com` | No record | Free ✅ |
| Apex MX | `10 inbound-smtp.eu-west-1.amazonaws.com` (SES inbound) | Someone receives `@weysure.com` mail through SES. **Do not touch.** A/AAAA or CNAME-flattened apex records can coexist with MX |
| Mail auth | `send.` (Resend: SPF, MX, CNAME `send.forge.rmta.net`), `rsend.` (SES SPF and MX), `resend._domainkey` DKIM, `_dmarc p=none` | Outbound mail is intact; nothing changes. Odd: `send.` shows a CNAME **and** TXT/MX → check it in the dashboard (separate from this plan) |
| CAA | None | Let's Encrypt allowed ✅ |
| Origin | NLB `k8s-traefik-traefik-1b6c471b42-…elb.us-east-1.amazonaws.com`; admits all Cloudflare IPs; no Authenticated Origin Pulls | The new zone reaches the origin with no NLB or Traefik change ✅ |
| cert-manager | DNS-01 via Cloudflare (`cloudflare-api-token`), issuers `letsencrypt-staging` / `-prod` | **The token must be able to edit DNS in `weysure.com`** (unknown; check its zone scope in the dashboard) |
| Chart `beyric-app` | `templates/ingress.yaml` takes **one** `host` | Needs an `extraHosts` option (backward compatible) to serve both hosts |
| API settings | gitops `projects/weysure/environments/prod/apps/api/values.yaml:42-44`: `SERVER_HOST`, `FRONTEND_URL`, `BACKEND_CORS_ORIGINS` | gitops-only change |
| Web settings | Web repo `Jenkinsfile:71-72`: `NEXT_PUBLIC_API_URL` / `NEXT_PUBLIC_WS_URL`, **baked in at build time** | Developer PR plus rebuild |
| Cookies or host checks | None in the API (`set_cookie`, `TrustedHost` absent) | No session breakage ✅ |
| Web content | Already uses `https://weysure.com` (schema.org) and `support@weysure.com` | Consistent ✅ |

## 2. Dashboard checks (Adebayo, read-only)

1. Cloudflare `weysure.com` → DNS: what are the apex and `www` records' targets? (Copy them into this plan before replacing them.)
2. Cloudflare `weysure.com` → SSL/TLS mode (must be **Full (strict)**), Always Use HTTPS, minimum TLS 1.2, WebSockets **on**.
3. Cloudflare `beyrictech.com` → Security (WAF custom rules, rate limiting, bot settings), Rules (redirect, origin,
   configuration). List what applies to the `weysure*` hosts so it can be mirrored.
4. Cloudflare → My Profile → API Tokens → the cert-manager token: which zones does it cover? If only `beyrictech.com`,
   edit it to add Zone:DNS:Edit on `weysure.com`. No new value means no Vault change.
5. Paystack dashboard (test mode; live later): current webhook URL and callback URL.
6. Dojah dashboard: is a webhook URL set? → **Yes, both Paystack and Dojah webhooks are set**; Adebayo changes them in B3 (2026-10-15).
7. Is there a mobile app build with a hard-coded API URL? → **No mobile app** (2026-10-15).

**Answers (Adebayo, 2026-10-15 16:55 WAT):** apex `A 192.64.119.68` and `www CNAME parkingpage.namecheap.co` are the
Namecheap parking page, safe to replace. SSL mode **Full** (not strict), Always Use HTTPS **off**, minimum TLS **1.0**.
No redirect, origin or configuration rules and no WAF rules for weysure on `beyrictech.com`, so there is nothing to
mirror. The cert-manager token (Edit zone DNS) covers **1 zone**, presumably `beyrictech.com`, so `weysure.com` must be added.

## 3. Phase A — serve both hosts (no behaviour change)

| Step | Who | Change | Verify |
|---|---|---|---|
| A1 | Adebayo | Cloudflare `weysure.com`: replace apex/`www` and add `api` as **proxied** CNAMEs to the NLB hostname. Mirror the beyrictech security settings from §2 | `dig` shows Cloudflare IPs; the origin answers 404 (unknown host) instead of timing out |
| A2 | platform (gitops PR) | Chart: `ingress.extraHosts: []`, rendered into the same Ingress `rules` and `tls.hosts` (one certificate with SANs). `helm template` diff empty when unset | Render diff |
| A3 | platform (gitops PR) | Staging issuer first: a throwaway `Certificate` for `api.weysure.com` on `letsencrypt-staging` | `Ready=True` proves the token reaches the zone; then delete it |
| A4 | platform (gitops PR) | `extraHosts`: api `[api.weysure.com]`, web `[weysure.com, www.weysure.com]`; certificates on `letsencrypt-prod` | `curl -sI https://api.weysure.com/api/v1/health` 200; web 200; old hosts unchanged |
| A5 | Adebayo | Cloudflare redirect rule `www.weysure.com/*` → `https://weysure.com/$1` (301) | `curl -sI` shows 301 |

**Phase A status (2026-10-15 17:15 WAT):** A1 ✅ (Cloudflare CNAMEs, Full (strict), Always HTTPS, TLS ≥1.2; mail
records unchanged) · A2+A4 ✅ gitops #75 (`8054fd9`): `api-extra-tls` and `web-extra-tls` Ready; `api.weysure.com` health,
`weysure.com` and `www` all 200; old hosts 200 · A3 ✅ staging certificate issued (token now covers `weysure.com`), then
deleted · A5 ⏳ `www` → apex 301 rule (Adebayo).

## 4. Phase B — switch the settings to the new hosts

| Step | Who | Change | Verify |
|---|---|---|---|
| B1 | platform (gitops PR) | API `SERVER_HOST=https://api.weysure.com`, `FRONTEND_URL=https://weysure.com`, `BACKEND_CORS_ORIGINS` = **both** web origins | CORS preflight from both origins 200; a fresh verification email links to `api.weysure.com` |
| B2 | developers (web PR) | `Jenkinsfile` `NEXT_PUBLIC_API_URL` / `WS_URL` → `api.weysure.com`; promote | Browser network tab: calls go to `api.weysure.com`; WebSocket connects |
| B3 | Adebayo | Paystack and Dojah webhook and callback URLs → `api.weysure.com` | One test-mode top-up end to end (as on 10-15); Loki shows the webhook on the new host |
| B4 | platform | Blackbox probes / `SiteDown*` targets → new hosts (keep the old ones until §5) | Probes green |

**Phase B status (2026-10-15 21:20 WAT):** B1 ✅ gitops #78 (also fixed a phase A gap: CORS rejected `https://weysure.com`,
400, so the app failed from the new host; now 200 from both origins, foreign origin still 400) · B4 ✅ probes for
`api.weysure.com` and `weysure.com` up · B2 ⏳ developers' `Jenkinsfile` PR (ask sent after web #49 went live) · B3 ⏳
Paystack and Dojah URLs (Adebayo, after B2).

## 5. Phase C — retire the old hosts

| Step | When | Change |
|---|---|---|
| C1 | after B2 is verified | Cloudflare redirect `weysure.beyrictech.com/*` → `https://weysure.com/$1` (301). Web only: browsers follow a GET redirect safely |
| C2 | after a **14-day soak** with 0 requests in Loki to `weysure-api.beyrictech.com` (except probes) | Remove the old API host from the ingress and DNS. **Never redirect the API**: a 301/302 turns POST into GET and drops the body |
| C3 | with C2 | `BACKEND_CORS_ORIGINS` → only `https://weysure.com`; remove the old names from `extraHosts`, probes, docs |

## 6. Rollback

- Phase A: revert the gitops PR or delete the DNS records. The old hosts are untouched throughout.
- Phase B: revert the setting (gitops) or the web build (image revert). The old hosts still serve until C2.
- Phase C: delete the redirect rule; re-add the host to `extraHosts` (certificate reissues in about 1 minute via DNS-01).

## 7. Follow-ups noticed (not in scope)

- The NLB admits **every** Cloudflare IP, so any Cloudflare customer could point a zone at our origin. Traefik only routes
  known hosts, so the impact is low. Authenticated Origin Pulls (per zone, mTLS) would close it: consider at go-live.
- `send.weysure.com` has a CNAME alongside TXT/MX records; ties into the 10-12 "mailed-by rsend" question.
