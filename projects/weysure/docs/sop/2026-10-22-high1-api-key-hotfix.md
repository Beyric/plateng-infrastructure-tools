# SOP — HIGH-1 hotfix: developer API keys refused for banned/inactive developers (Weysure-API #119)

**Shipped:** Weysure-API #119 merged 2026-10-22 11:52:35 UTC as a **merge commit** (`250636e`, parents `d23e9b09` + `03654c6`; tree
identical to the approved `03654c6`) → main #78 green → promoted `250636ecc649` (gitops `b32de8d`) · **Kind:** security hotfix
(auth), no migration, no platform config · **Cost delta:** $0 · Notes/replies (`weysure/docs/`):
`platform-note-2026-10-21-high1-api-key-status.md`, `platform-reply-2026-10-21-high1-hotfix-and-sonar-pr.md`,
`platform-note-2026-10-22-high1-hotfix-head.md`, `platform-reply-2026-10-22-high1-hotfix-go.md`, `…-high1-live.md`.
Developers' SOP: `Weysure-API/docs/sop/2026-10-21-api-key-developer-status.md`.

**Status: live and verified on prod.**

## Why

`verify_api_key` (`app/core/api_key_auth.py`) refused only `status == "suspended"`: keys of BANNED or INACTIVE developers kept
authenticating on every `/api/v1/public/*` endpoint. Fix: an allowlist, fail closed: only a verified developer with status
ACTIVE or PENDING_KYC; anything else (incl. NULL or a future status) → 403 with the unchanged body.

## How it was released (and why that way)

| Decision | Why |
|---|---|
| Hotfix outside the trains, **and** kept in Train 2 (Adebayo, 2026-10-21; "no more small PRs" except hotfixes) | auth hole, one file, no migration, image-only rollback; Train 2 already carried `eabe006` |
| Developers **merged `main` into the branch** instead of rebasing | a rebase would give the change new SHAs, so `main` and Train 2 would carry two copies and the train's "PR heads = merge parents" check would break |
| Merged as a **merge commit** with `--match-head-commit` | `eabe006` itself reaches `main`; Train 2's copy becomes an ancestor → its #119 diff vs `main` is empty |
| Review carried over from `eabe006` to `03654c6` | the auth file and its test are byte-identical (`git diff eabe006 03654c6 -- <files>` empty) |

Review (Opus-level, auth path): `users.status` is a native `Enum(UserStatus)` column, so the set lookup compares members; tests
prove ACTIVE/PENDING_KYC still get 200 (a wrong comparison would lock out every developer) and BANNED/INACTIVE/SUSPENDED/NULL/
unverified get 403; `verify_api_key` is the only `X-API-Key` authentication path.

## Verification

| Check | Result |
|---|---|
| PR-119 #3 on `03654c6` | 3716 passed, 2 skipped; gitleaks clean; Trivy CRITICAL (fixable) 0 |
| main #78 on `250636e` | 3716 passed; **main Sonar gate PASSED**; Promote → `b32de8d` |
| Rollout | api ×2, scheduler, worker on `250636ecc649`, Ready, 0 restarts; Argo 32/32; sites 200 |
| Live proof | throwaway developer account (`+dev` Gmail alias), one key: ACTIVE → `GET /api/v1/public/escrow` **200**; admin ban → same key **403** `Developer account is not active or has been suspended.` Account left **banned** |

Live-check method: key read with `read -rs K`, sent with `printf 'X-API-Key: %s' "$K" | curl -H @-` (never on argv or in history),
`unset K` after. A role cannot be changed after onboarding (`/auth/select-role` is one-time and audited), so a mistaken non-developer
signup needs a new signup, not a DB edit.

## Roll back

Image-only: gitops `images.yaml` back to `d23e9b09321d` (no migration in #119). Reverting re-opens the hole.

## Follow-ups

- Developers: merge `main` into `release/2026-10-2-api` (it does not contain `250636e` yet; `release/2026-10-1b` does).
- Signup stores developers' default keys in plaintext until first use: fixed by Train 1b (`72e9c986` + migration `c8d2f6a41b95`).
- Train 1b's #101 (live-key gating, no flag): count live keys and their owners' tiers before 1b deploys.
