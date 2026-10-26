# SOP — Weysure web Train 2 (#66) and API docs #127 live

**Shipped:** web #66 merged 2026-10-26 08:56 UTC as a **merge commit** (`main` → `8d81d74c`, head = approved `f52cde99`) → main build green
09:06 UTC → promoted `8d81d74c58c0` (gitops `aef60a70`) → web ×2 09:14 UTC. Then API #127 merged 09:28 UTC (`c232753c`, parents
`5ef23964` + approved `870fe62b`) → main green 10:17 UTC → promoted `c232753c8746` (gitops `55e56666`) → api ×2 + api-worker 10:26 UTC ·
**Kind:** developer web release train + API docs-only PR, no migration, no platform config · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-25-train-2-web.md`, `platform-reply-2026-10-25-train-2-web-review.md`,
`…-train-2-web-go.md`, `platform-reply-2026-10-26-train-2-web-live.md`; `platform-note-2026-10-25-api-127-docs.md`, `…-api-127-go.md`,
`platform-reply-2026-10-26-api-127-live.md`.

**Status: live and verified.** Web half of Train 2; API half: [Train 2 API](2026-10-25-train-2-release.md). Method: [Train 1b](2026-10-24-train-1b-release.md).

## What it is

| Part | Content |
|---|---|
| W0 fold-in | #59 silent session refresh, #56 WebSocket token off the URL, #58 Tier 2 withdraw copy, #52 gitleaks pre-commit, #53 admin Settings / Platform health / Admins, #55 invite page (inert, `DEAL_INVITES_ENABLED` off) |
| W1–W4 | user KYB wizard + DVA screens; admin Businesses / Account numbers / Holds / Chargebacks; developer console live-key states; DVA 5b returns; KYB PR-7 pause/resume; Tier 3 apply + admin queue. Every feature sits behind an API flag that is **off** in prod |
| Review fixes | S3776 refactor of `services/api.ts` `apiRequest` (behaviour read: same order, one retry, `"unavailable"` never signs out); MED-A `credentials: "include"` on admin password change; S2925 e2e wait |
| CI | web PR builds gain changed-line coverage (`scripts/coverage-new-code.sh`); B1 `-pr` recreate already live (#63) |
| API #127 | three files under `docs/` only; the Jenkinsfile has no docs-only skip, so it was a full build and a roll on identical code |

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| Web after the API train, then #127 after web | one rollout at a time; #66 needed API #89/#98/#126 live; #127 queued behind it so a web problem is never confused with an API roll |
| GO for exact commit `f52cde99`, merge window 08:00 WAT next morning | approval is of a commit; someone watching at merge time |
| Folded PRs left alone | GitHub marks #52–#59 merged once their commits reach `main` through the merge commit; nothing to close (a squash would have left them open) |
| `WS_ALLOW_URL_TOKEN=false` not in this release | needs a **positive** live line (a connect without `?token=`), and confirmation no other client still uses it; prod had no socket traffic since 10-22, so "0 `?token=` lines" alone proved nothing |

## Platform findings this release exposed

| Finding | Effect | Action |
|---|---|---|
| Argo showed `Degraded` ~1 min mid-roll | one Next.js startup-probe timeout on a new pod; old pods kept serving | none; judge a roll at the end (all pods on tag, Ready, 0 restarts) |
| Argo picked up the web promote ~6 min after the gitops commit (API: ~6 min too) | normal poll + queue | none |
| Gunicorn logs old-pod shutdown as `[ERROR] Worker … was sent SIGTERM!` | error-count queries flag a clean roll | exclude `was sent SIGTERM` when counting errors after a roll |

## Verification (all live, 2026-10-26)

| Check | Evidence |
|---|---|
| Web merged tree | `8d81d74c` head `f52cde99` = GO commit; PR-66 #4 green, `pr-66` `new_violations` 0, Trivy CRITICAL 0 (pre-merge) |
| Web pods | 2/2 on `8d81d74c58c0`, Ready, 0 restarts, `ip-10-0-4-18` + `ip-10-0-4-37` (ADR-024); start-up line `Next.js 15.5.28` |
| Web health | `weysure.com` 200, `www` 301 → apex; 0 error/exception lines (web) and 0 Traefik 5xx on `weysure.com` in the first 10 min |
| **WS token off the URL** | before: last connects 10-22, all `WebSocket /api/v1/ws/…?token=…`. After (Adebayo signed in, opened notifications 09:26 UTC): `WebSocket /api/v1/ws/notifications` and `/ws/messages` **`[accepted]`, no query string**; Traefik `GET /api/v1/ws/notifications` without query |
| #127 merged tree | `c232753c` parents `5ef23964` + approved `870fe62b` |
| #127 pods | api ×2 (two nodes) + api-worker on `c232753c8746`, Ready, 0 restarts |
| #127 migration / guards | migrate log: context lines only, no `Running upgrade` (head stays `e4b8d1a6c372`); no `[BOOT GUARD]` |
| #127 flags / errors | `[FLAGS]` identical to Train 2 (api + worker); 0 error lines besides old-pod SIGTERM; `/api/v1/health` 200 |

Loki queries used (port-forward `svc/loki` in `monitoring`):

```
{namespace=~"weysure-prod|traefik"} |= "/api/v1/ws/"                       # WS connects, check for ?token=
{namespace="weysure-prod",container=~"api|api-worker"} |~ "Traceback|ERROR|CRITICAL" != "was sent SIGTERM"
{namespace="weysure-prod",container=~"api|api-worker"} |= "[FLAGS]"
```

## Operate / roll back

- **Web:** image-only — gitops `web.tag` back to `e272db7f1371`; **never past `6bef32860f30`** (`d71f3a7595bc` has the `next` CVE).
- **API #127:** image-only — gitops back to `5ef239645723` (same schema). Train 2 API's own rollback (not image-only) is in its SOP.

## Follow-ups

- [ ] `WS_ALLOW_URL_TOKEN=false` as its own change, after the developers confirm no other client (mobile, scripts, docs examples) sends `?token=`
- [ ] Web auth MED-B (refresh against the device clock) before `ACCESS_TOKEN_EXPIRE_MINUTES=15`; 4 web LOWs later
- [ ] CI-speed B (pytest-xdist) and C1 (web kaniko cache); Train 3 (note still a draft)
- [ ] Developers delete `release/2026-10-2-web` and `release/2026-10-2-api`
