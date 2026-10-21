# SOP — Sonar PR gate compares a PR with `main` (base scan + lock + SCM off)

**Shipped:** plateng-gitops #84 (`lockable-resources`, 2026-10-20) · Weysure-API **#102** (`2be8fd2`, base scan + lock, 2026-10-20 16:00 UTC)
and **#110** (`e5c43cd`, SCM off in the `-pr` scans, 2026-10-21 09:51 UTC) · Weysure web **#60** (`d71f3a7`, base scan + lock, 2026-10-20
16:02 UTC) · plateng-gitops #85 (SonarQube `do-not-disrupt`, 2026-10-20 17:05 UTC) · **Kind:** CI · **Cost delta:** $0 (+~1 min per PR
build) · Proposal: `weysure/docs/platform-proposal-2026-10-20-sonar-pr-base-scan.md`; proof report:
`weysure/docs/platform-report-2026-10-21-sonar-base-scan-proof.md`

**Status: API proven (2026-10-21). Web: base scan + lock live, SCM-off change still to come, so web's PR gate cannot fail on new
issues yet (see Follow-ups).**

## Why

SonarQube Community has no PR analysis. Since 2026-10-09, PR builds have analysed into one shared project per app (`weysure-api-pr`,
`weysure-web-pr`) with `sonar.projectVersion=pr-<N>`, so "new code" meant "since whichever PR ran last". The gate was wrong both ways:

| When | Effect |
|---|---|
| Weysure-API #91 (2026-10-19) | PR gate passed; main's gate then failed on S3516, so `main` was red and nothing deployed |
| Weysure-API #99 (2026-10-19) | PR gate failed on S8410 in `admin.py` (untouched since 2026-02-13), because the baseline was `pr-98` |

## How (final design)

PR builds only (`CHANGE_ID` set), inside `lock(resource: 'sonar-weysure-<app>-pr')`:

1. **Base worktree** (`git` container, no credential, hooks off): `git merge-base HEAD refs/remotes/origin/main` → detached worktree
   `.base-scan`, then `chown -R "$(stat -c %u:%g .)" .base-scan`. No merge base → base scan skipped, build UNSTABLE.
2. **Base scan:** `projectVersion=base-pr-<N>`, `sonar.scm.disabled=true`, no coverage, no gate wait.
3. Worktree removed in a `finally` (web also checks `test ! -e .base-scan` and excludes `.base-scan/**`).
4. **PR scan:** `projectVersion=pr-<N>`, `sonar.scm.disabled=true`, coverage, `qualitygate.wait=true`.

Main builds take the original path: one scan into `weysure-api`/`weysure-web`, **SCM on**, no lock. Main's gate stays the authority
for what deploys.

### Three defects found only by running it

| # | Defect | Fix |
|---|---|---|
| 1 | Fallback `HEAD^1` when `origin/main` was missing: Jenkins merges main **into** the PR head, so `HEAD^1` is the PR. The gate would have passed silently | fallback removed (`HEAD^2` would be main; neither is needed, because Jenkins always fetches `refs/heads/main`) |
| 2 | `.base-scan` created by the `git` container (uid 0); the `sonar` container (uid 1000, `scanner-cli`) could not write `.scannerwork` | `chown` to the workspace owner (`1000:1000`) |
| 3 | **The gate could not fail.** Community dates an issue by its line's **last commit** when SCM data exists; a PR's commits are always older than its base analysis, so nothing the PR added was "new" (UI: `New issues 0`, coverage "not enough lines") | `sonar.scm.disabled=true` in both `-pr` scans: issues are then dated at the analysis, and pre-existing ones match by line hash |

| Rejected | Why |
|---|---|
| Developer Edition / community branch plugin | licence cost / unofficial and version-locked |
| One Sonar project per PR (the developers' local method: a fresh project with a back-dated baseline) | cleanup per PR; a shared project only accepts increasing analysis dates |
| PR gate advisory only | that is how #91 turned `main` red |

## What's involved

| Where | Change |
|---|---|
| plateng-gitops `bootstrap/apps/jenkins.yaml` | `lockable-resources` (#84) |
| plateng-gitops `bootstrap/apps/sonarqube.yaml`, `platform/sonarqube/postgres.yaml` | `karpenter.sh/do-not-disrupt` (#85); a consolidation move killed proof build PR-107 #1 mid-scan |
| Weysure-API `Jenkinsfile` (Quality gate stage) | #102 (base scan, lock, `chown`), #110 (SCM off in `-pr` scans) |
| Weysure `Jenkinsfile` | #60 (base scan, lock, `chown`, `.base-scan/**` exclusion); SCM off still to come |

## Verification (Weysure-API; throwaway draft PRs, never merged)

| Case | Build | Result |
|---|---|---|
| Main path after #102 | main #73 (`2be8fd2`) | one scan into `weysure-api`, no lock, gate PASSED, promoted, live 16:47 UTC |
| Base scan + lock work | PR-102 #4, PR-60 #4 | lock → `base-pr-<N>` EXECUTION SUCCESS → `pr-<N>` gate; indexed files: base 1494 / PR 1496 (web), so no leftover copy |
| Known issue, **before SCM off** | PR-107 #2 | **PASSED, the defect** (New issues 0) |
| Clean PR, SCM off | PR-110 #1 (`f7af50a`) | PASSED, `SCM Publisher is disabled` ×2 |
| Known issue, never seen before, SCM off | PR-111 #2 (`7af1f10` = `f7af50a` + new file with `python:S1481`) | **FAILED**: UI `New issues 1 (Required = 0)`, the only failed condition; 7 new lines, 3 to cover |
| Main path after #110 | main #75 (`570e48e`) | `SCM provider for this project is: git` (SCM on), gate PASSED |

**Proof gotcha:** PR-111 #1 re-used #107's planted line and **passed**. Sonar reopened #107's closed issue, which keeps its original
(SCM-backdated) creation date. A proof issue must be one Sonar has never seen.

**Bonus of SCM off:** new lines are found by line hash, so new-code coverage (≥ 80 %) and duplication (≤ 3 %) apply again in the
PR gate (Sonar skips them below ~20 new lines).

## Operate / roll back

- A red PR gate is now meaningful: read the issue; it is in the PR's own code.
- **Accepted limit:** a PR that brings back an issue main once had and fixed (a revert) is reopened, not new, so the PR gate misses it.
  Main's gate still catches it.
- SonarQube restarts kill running scans: change its pod template only when no PR build is in Quality gate.
- Roll back: revert #110 (gate fails open again), then #102/#60 (back to the shared baseline). Revert #84 only after no Jenkinsfile
  uses `lock`.

## Follow-ups

- **Web: SCM off** in both `-pr` scans (the same one-line change as #110), then the same proof with a fresh planted issue. Until then,
  a green **web** PR gate does not prove "no new issues".
- Pin Jenkins plugins by `name:version` (`installLatestPlugins: true` today).
- Optional: `-Dsonar.scm.revision=$base` on the base scan (its analysis is labelled with `GIT_COMMIT`, cosmetic).
