# SOP — Weysure-API Train 1a (#118, 11 PRs) + fix-forward #120 live

**Shipped:** #118 merged 2026-10-21 14:47:19 UTC as a **merge commit** (`main` → `45bb5fd`, tree identical to the approved
`8604b24`) → main #76 **failed main's Sonar gate** (1 new issue, `python:S3776`) → nothing built. Fix #120 merged 17:40:44 UTC
(squash `d23e9b0`, tree identical to the approved `5955171`) → main #77 green, promoted `d23e9b09321d` (gitops `88f6f1a`) →
migration + all 4 API pods 18:29 UTC · **Kind:** developer release train (fixes and hardening), **one migration**
`f2b8d6a4c1e7`, no platform config · **Cost delta:** $0 · Notes/replies (`weysure/docs/`): `platform-note-2026-10-2x-train-1a.md`,
`platform-reply-2026-10-20-release-trains.md`, `platform-reply-2026-10-21-train-1a-review.md`, `…-train-1a-go.md`,
`…-train-1a-main-gate-red.md`, `platform-note-2026-10-21-withdraw-cognitive-complexity.md`, `…-withdraw-complexity-go.md`,
`…-train-1a-live.md`. Developers' own SOP: `Weysure-API/docs/sop/2026-10-20-train-1a-integration.md`.

**Status: live and verified.** First release train (decision 10-20: "yes with 8 conditions").

## What it is

| Part | Content |
|---|---|
| 11 PRs, merged into `release/2026-10-1a` by merge commit | #81, #82, #84, #85, #86, #89, #95, #103, #104, #105, #106 (fixes, hardening, chargebacks pre-enforce, case-insensitive emails, superadmin-only approvals) |
| Integration commits | 9 (developers' table) + docs `1805e574` (FE guide 403/401 bodies) + two merges of `main` (`a586634`, `8604b24`) |
| Migration | `f2b8d6a4c1e7` (#104): aborts on any case-collision, lower-cases ASCII emails, `CREATE UNIQUE INDEX CONCURRENTLY uq_users_lower_email ON users (lower(email))`, drops `ix_users_lower_email` |
| New startup line | `[FLAGS] role=… <every bool/Literal setting>=<value>` (condition 6) |
| #120 | behaviour-preserving extraction from `request_withdrawal`: `_check_withdraw_limits`, `_withdrawable_balance` (S3776 17 → 11) |

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| Verify the train by **structure**, not only content: 11 PR heads = merge commits' 2nd parents; integration commits = table; Jenkinsfile = main; one Alembic head | approval stays per PR commit; a train is only bisectable/revertable if each PR's commits survive unchanged |
| Re-pin after merging `main` (`570e48e`, CVE hotfix + SCM off): `88bd066` must be an ancestor of the new head, only the doc commit + main merge new, re-merge diff empty | proves nothing else slipped in with the update |
| **Merge commit** for the train (`--merge --match-head-commit`) | squash would erase the 11 PRs' commits (no per-PR revert/bisect); `--match-head-commit` makes "go for this exact commit" enforced by GitHub |
| Prod **case-collision read** before the go (the migration's own count query, read-only, counts only) | a collision makes the migration abort → failed PreSync mid-release; reading first moves that failure to zero cost. Result: `collision_groups 0, users 1, mixed_case_emails 0` |
| Main #76 red → **fix-forward PR**, not revert | the gate blocks Promote, so prod never changed; a revert of an 11-PR merge is the bigger risk |
| #120 reviewed for behaviour (money path): every helper name module-level, same check order, balance read after `lock_user` | an extracted helper using a function-local import would be a runtime `NameError` on the first withdrawal |

## Platform findings this release exposed

| Finding | Effect | Status |
|---|---|---|
| **Shared `-pr` Sonar project reopens a previously seen issue with its old creation date** | PR-95 #3 and PR-118 #1 PASSED with S3776 that PR-95 #1/#2 had reported → PR gate only catches an issue the first time any PR build reports it | open — design: fresh, history-free Sonar project per PR build (needs decision + token perms). Main's gate (SCM on) caught it |
| With SCM off, **every line is "new code"** in `-pr` analyses | "coverage on new code" = whole-repo coverage (web 63% → web #61 fails on its own; API > 80% → passes but measures nothing per PR) | open — separate `-pr` quality gate with New issues only; per-PR changed-line coverage in Jenkins (`scripts/coverage-new-code.sh` on web) |
| Karpenter node `ip-10-0-4-19` came up with ipamd never assigning secondary IPs (ENI had 1 IP; subnet had 66 free) | alloy, ebs-csi, a Jenkins agent stuck `ContainerCreating` 45 min; Argo `alloy` Progressing | self-resolved (Karpenter removed the node ~18:50 UTC). Next time: `kubectl delete node <name>`; root cause in `ipamd.log` on the node |

## Verification (all live, 2026-10-21)

| Check | Evidence |
|---|---|
| Merged trees | `git diff 8604b24 45bb5fd` empty; `git diff 5955171 d23e9b0` empty |
| Main #77 | 3707 passed; `weysure-api` gate PASSED; Trivy `Python │ 0`; `promoted api -> d23e9b09321d` |
| Migration | Loki `container="migrate"`: `Running upgrade a7e3c9b25d14 -> f2b8d6a4c1e7`; Job Succeeded; Adebayo `db-oneoff.sh d23e9b09321d alembic "current"` 18:49 UTC → `f2b8d6a4c1e7 (head)` |
| Pods | api ×2 (`ip-10-0-4-18`, `ip-10-0-4-35`), scheduler, worker on `d23e9b09321d`, Ready, 0 restarts |
| `[FLAGS]` | in all 4 pods; = developers' note §4 defaults except gitops prod values `ORIGIN_RULES_ENFORCED=true` (all) and `WALLET_RECONCILIATION_SCHEDULER_ENABLED=true` (scheduler + worker; `apps/api/values.yaml:137,162`) |
| Errors | none from new pods (old pods' gunicorn shutdown `SIGTERM` only) |
| Sites / Argo | 200 / 200 / 200; 32/32 Synced/Healthy |

## Operate / roll back

- **Rollback is not image-only:** `scripts/db-oneoff.sh d23e9b09321d alembic "downgrade a7e3c9b25d14"` (the **train** image knows
  the new revision), then revert the gitops promote to `570e48eb4c67`. Lower-cased emails stay lower-cased.
- The `[FLAGS]` line is the first thing to read after any API rollout: it shows the effective flags per role.

## Follow-ups

- [ ] `-pr` Sonar: fresh project per PR build (reopen hole) + `-pr` gate New-issues-only + changed-line coverage step (API, web)
- [ ] Web #61 (SCM off) proof re-run after the `-pr` gate change
- [ ] Loki rules on the new log lines from the developers' note §3 (only now that 1a is live)
- [ ] M-1 (#114) before `REFUND_TO_SOURCE_ENABLED` flag-on; L-1…L-6 follow-up PRs (#115, #116)
- [ ] `WS_ALLOW_URL_TOKEN=false` in gitops after web #56 is live
- [ ] `admins` `lower(email)` uniqueness (developers' follow-up)
