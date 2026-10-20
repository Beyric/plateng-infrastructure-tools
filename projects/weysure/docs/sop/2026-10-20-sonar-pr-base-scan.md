# SOP — Sonar PR gate compares a PR with `main` (base scan + lock)

**Shipped so far:** platform half — plateng-gitops #84 (`4275c86`, merged 2026-10-20) adds `lockable-resources` to Jenkins;
controller restarted 13:06:01 UTC · **Pending:** the developers' Jenkinsfile PRs (Weysure-API, then Weysure web) ·
**Kind:** CI · **Cost delta:** $0 (+~1 min per PR build) · Proposal: `weysure/docs/platform-proposal-2026-10-20-sonar-pr-base-scan.md`,
order: `platform-reply-2026-10-20-base-scan-order.md`, `platform-reply-2026-10-20-lock-plugin-live.md`

**Status: platform part live; Jenkinsfile change not yet merged.**

## Why

SonarQube Community Edition has no PR analysis. Since 2026-10-09 PR builds analyse into one shared project per app
(`weysure-api-pr`, `weysure-web-pr`) with `sonar.projectVersion=pr-<N>`. "New code" there is **since the previous version
analysed** = whichever PR ran last, so the PR gate was wrong both ways:

| When | Effect |
|---|---|
| Weysure-API #91 (2026-10-19) | PR gate passed; main's gate then failed on S3516 → `main` red, nothing deployed |
| Weysure-API #99 (2026-10-19) | PR gate failed on S8410 in `admin.py` (untouched since 2026-02-13); baseline `pr-98` |
| Two PRs at once | each can take the other's analysis as its baseline |

## How

PR builds (`changeRequest()`) only, inside `lock(resource: 'sonar-weysure-<app>-pr')`:

1. **Base scan:** the PR's merge base with `main` (separate worktree), `sonar.projectVersion=base-pr-<N>`, no gate wait, no coverage.
2. **PR scan:** as today, `pr-<N>`, `qualitygate.wait=true` → new code = **this PR vs the `main` it branches from**.

Main builds unchanged; main's gate (`weysure-api`, `weysure-web`) stays the authority for what deploys.

| Rejected | Why |
|---|---|
| Developer Edition / community branch plugin | licence cost / unofficial and version-locked (2026-10-09) |
| One Sonar project per PR | cleanup per PR; auto-created projects miss our gate/profile settings (`scripts/sonar-pr-projects.sh`) |
| PR gate advisory only | that is how #91 turned `main` red |

## What's involved

| Where | Change |
|---|---|
| plateng-gitops `bootstrap/apps/jenkins.yaml` | `lockable-resources` in `controller.installPlugins` (#84) |
| Weysure-API / Weysure `Jenkinsfile` | Quality gate stage: base scan + PR scan under `lock` (developers; pending) |

## Verification

| Check | Result |
|---|---|
| Jenkins idle before merge | no agent pods; main #72 (#91 + #99) finished 12:50 UTC |
| Restart | `jenkins-0` recreated 13:06:01 UTC, Ready, 0 restarts; "Jenkins is fully up and running" 13:06:42; no `SEVERE` / failed plugin loads |
| Plugin | `lockable-resources` **1576.v217259b_f9976** (Jenkins 2.541.3), pinned |
| Jenkinsfile proof (pending) | throwaway PR with one known issue → PR gate fails on exactly it; clean PR passes even with another PR analysed in between |

**Gotcha:** the Jenkins Argo app's source is the Helm chart, so `status.sync.revision` is the chart version (`5.9.56`), never
a git SHA. Judge a Jenkins rollout by `jenkins-0`'s `creationTimestamp` and readiness.

## Operate / roll back

- A plugin change restarts the controller and kills running builds: merge only with no agent pod running.
- Rollback: revert #84 (another restart) — only after the Jenkinsfiles stop using `lock`, or their PR builds fail on an unknown step.
- Until the Jenkinsfiles land: when a PR gate is red, read the issue; outside the PR's diff = baseline noise, decided case by case.

## Follow-ups

- Developers: the two Jenkinsfile PRs; then the proof above, for each app.
- Pin Jenkins plugins by `name:version` (open since Phase 6; `installLatestPlugins: true` today).
