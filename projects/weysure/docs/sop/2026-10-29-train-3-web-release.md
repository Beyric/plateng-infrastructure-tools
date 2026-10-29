# SOP — Weysure web Train 3 (#67) live

**Shipped:** web #67 merged 2026-10-29 18:14:45 UTC as a **merge commit** (`main` → `2b49b4a4`, parents `8d81d74c` + approved head `b74342ed`) →
main build green 18:32 UTC → promoted `2b49b4a4e5f2` (gitops `1cd347b1`) → web ×2 Ready 18:38 UTC · **Kind:** developer web release train
W1–W10 (session refresh hardening, invite sender UI, Tier 3 / ceiling / refund-in-progress, copy + cookie notice, route guards, ESLint,
verify-email token in the body + `no-referrer`, rating, chat typing/read ticks and polling fallback, **access token in memory only**) ·
no migration, no platform config · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-2x-train-3-web.md`, `platform-question-2026-10-27-web67-pr-merge-error.md`,
`platform-reply-2026-10-27-web67-pr-merge-error.md`, `platform-reply-2026-10-29-web67-review-findings.md`,
`platform-reply-2026-10-29-web67-train-3-web-go.md`, `platform-reply-2026-10-29-web67-train-3-web-live.md`.

**Status: live and fully verified** (a real signed-in session restored from the refresh cookie at 18:48 UTC). API half: [Train 3 API](2026-10-26-train-3-api-release.md). Method: [Train 2 web](2026-10-26-train-2-web-and-127-release.md).

## Why it took three heads

| Head | Result | Cause |
|---|---|---|
| `5db9ce2` (PR-67 #1) | pr-merge error | Quality gate |
| `da8075c` (PR-67 #2) | pr-merge error | Quality gate: `new_violations` 9 (S6822, S6767 ×2, S6754 ×2, S6819, S6582 ×2, S2004). Tests passed (3492), nothing timed out |
| `4e9ddfed` (PR-67 #3) | green | the 9 fixed in code (no Accepted). **GO withheld**: our own review first |
| **`b74342ed`** (PR-67 #4) | green, **GO** | one commit on top of `4e9ddfed` fixing our review findings |

## What our review found (Opus, read-only, `4e9ddfed`)

No blocker in the logic. One finding to fix before merge, four to fix soon; the developers shipped all five in `b74342ed`.

| # | Finding | Fix in `b74342ed` |
|---|---|---|
| A1 | W5 guards `/developer/**`, so a signed-out click on the emailed `/developer/settings/verify-payout-change/<token>` redirected to `/login?next=…<token>`: a one-time token in browser history and Traefik/Loki logs (Alloy redacts `token=` query values, not path segments). Route also missing from the `no-referrer` list. Confirmed by us in `middleware.ts` | path exempt from the guard (no `next=`), `no-referrer` rule added, test |
| B1 | redux-persist `autoMergeLevel1` could rehydrate a token an old tab wrote to `persist:auth` after the purge | `persistReducer` removed from auth and adminAuth |
| B2 | silent refresh ignored `user.id` / `admin_id`: a shared cookie that now belongs to another account would run as that account under the old UI | compare ids; mismatch clears this tab only (`clearLocal`) and the query cache |
| B3 | comment claimed a 30 s timeout avoids false theft detection; it does not (a retry of a lost rotation arrives after the 10 s grace) | comment corrected. **Real fix is API-side** (re-issue the cookie on an in-grace replay or a longer grace): not requested yet |
| B4 | a 200 without `access_token` retried every 15 s for ever, rotating the cookie each time | treated as expired, session cleared |

B2 was checked against the API's live captures (`auth-refresh/28`, `29`): user answer `user.id`, admin answer `admin_id`, the same field `ADMIN.adopt` stores, so a normal refresh does not sign anyone out.

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| Web after the API train (Train 3 API live 10-26) | W7 sends the verify-email token in the body; the API on `main` before A9 answers 422 |
| Own review of W5/W10/W1/W7 before the GO | the developers' reviews covered refresh and rotation; auth/permission paths get our review by rule, and it found A1 |
| GO for `b74342ed`, not `4e9ddfed` | approval is of a commit; a fix for a real finding is a new SHA with its own check |
| Merge commit, `--match-head-commit` | per-PR commits stay; GitHub enforces the approved SHA |

## Platform findings this release exposed

| Finding | Effect | Action |
|---|---|---|
| PR-67 #2 waited ~35 min for an agent pod (`Unschedulable: Insufficient cpu/memory`, then `ContainerCreating`; two pods timed out at 16.7 min each) | build queued 18:20, first stage ran ~18:55 | capacity / prefix-space work (checklist) |
| Spot node `ip-10-0-4-48` (SonarQube, an API pod, a web pod) was **forcibly terminated** (events `Evicted: Forceful Termination`, about 18:20 UTC); `do-not-disrupt` does not stop spot reclaims | SonarQube restarted on another node; API pod `bdq7m` had 4 restarts (startup probes timing out, node at 101% memory — likely cause); worker 4 restarts, all exit 0 | pods rescheduled onto two nodes; keep watching |
| A new spot node `ip-10-0-3-34` (nodeclaim `default-lz9xb`) never registered: `NotReady`, only Pending DaemonSet pods | Alloy 5/6 ready, `alloy` and `kube-prometheus-stack` show Progressing | cleared by Karpenter within the hour; nothing to do |
| Argo `Degraded` ~1 min mid-roll | one Next.js startup-probe timeout | none; judge at the end |

## Verification (live, 2026-10-29)

| Check | Evidence |
|---|---|
| Merged tree | `2b49b4a4` parents `8d81d74c` + `b74342ed` = GO commit; PR-67 #4: 219 files / 3496 tests, changed-line coverage 97.2%, Sonar `pr-67` `new_violations` 0 (PR scan 61,002 lines), gitleaks 0, Trivy stage passed |
| Web pods | 2/2 on `2b49b4a4e5f2`, Ready, 0 restarts, `ip-10-0-4-18` + `ip-10-0-4-241` |
| Argo / sites | `weysure-web` Synced Healthy at gitops `1cd347b1`; `weysure.com`, `/login`, `api.weysure.com/api/v1/health` 200 |
| `Referrer-Policy: no-referrer` | on `/verify-email/…`, `/reset-password/…`, `/settings/verify-bank-account/…`, `/developer/settings/verify-payout-change/…`, `/admin/set-password`; `/` keeps `strict-origin-when-cross-origin` |
| Route guards (signed out) | `/developer`, `/dashboard` → 307 `/login?next=…`; `/admin/dashboard` → 307 `/admin/login`; the payout-change token path → **200, no redirect** |
| Errors | 0 error/traceback lines in api, api-worker, web around the roll (SIGTERM excluded) |
| Proof of life | one cookie-less `POST /auth/refresh` probe = 401, visible in API and Traefik logs |
| **Real session** | Adebayo signed in and reloaded private pages: `GET /dashboard` 18:48:08 → `POST /auth/refresh` **200** 18:48:11; `/dashboard/settings` → 200 at 18:48:28; `/dashboard/disputes` → 200 at 18:48:34 (870 bytes each); 0 responses with 429 and 0 errors 18:44–18:58. A 429 on refresh is "unavailable", never a sign-out: read in `lib/auth/session-refresh.ts` + unit tests, not seen live |

Loki queries used (port-forward `svc/loki` in `monitoring`):

```
sum(count_over_time({namespace="weysure-prod", container="api"} |= "/auth/refresh" [20m]))     # refresh traffic (add |= " 429")
sum by (s) (count_over_time({namespace="traefik"} |= "auth/refresh" | regexp "\" (?P<s>[0-9]{3}) " [25m]))
{namespace="weysure-prod",container=~"api|api-worker"} |~ "Traceback|ERROR|CRITICAL" != "was sent SIGTERM"
```

## Operate / roll back

- **Rollback is image-only:** gitops `projects/weysure/environments/prod/images.yaml` `web.tag` back to `8d81d74c58c0`; never below `6bef32860f30` (`d71f3a7595bc` has the `next` CVE). No migration, no config.
- After a rollback, users who already loaded the new build have had their old stored session deleted by it (W10), so they sign in again once.
- Watch `/auth/refresh` 429s (limits 60/min per IP, 20/min per cookie): users behind one NAT.

## Follow-ups

- [x] Real-session proof (2026-10-29 18:48 UTC, see Verification).
- [x] Nodeclaim `default-lz9xb` (NotReady spot node, no workload): Karpenter removed it itself before the delete command ran (`NotFound`).
- [ ] B3 API item (replay inside the refresh grace) if the developers want it.
- [ ] Prod API/worker restarts from startup probes: decide on consolidation exemption / probe timeout.
- [ ] Before `DEAL_INVITES_ENABLED`: invite option shown after a search miss with the flag off; "In escrow" excludes a buyer's held invite money.
- [ ] Before `ACCESS_TOKEN_EXPIRE_MINUTES=15`: web MED-B (refresh vs device clock) is covered by W1; re-check with the first real sessions.
