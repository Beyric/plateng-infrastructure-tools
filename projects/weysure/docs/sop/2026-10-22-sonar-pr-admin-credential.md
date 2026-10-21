# SOP — Sonar `-pr` gate fix A1 + B1, platform part (`weysure-pr` gate, `sonar-pr-admin-token`)

**Shipped:** plateng-gitops [#87](https://github.com/Beyric/plateng-gitops/pull/87), merged 2026-10-21 23:35 UTC (`92aaf4d`); SonarQube UI and
Vault changes by Adebayo (2026-10-21/22) · **Kind:** CI platform config + credential · **Cost delta:** none

**Status: platform part live (Jenkins restarted 23:36:36 UTC, key file mounted, JCasC credential loaded, no `SEVERE`). The fix only takes
effect when the developers' Jenkinsfile change lands and its proof passes (checklist).**

## Why

Two holes in the Sonar PR gate, found 2026-10-21 ([SOP](2026-10-21-train-1a-release.md)):

| Hole | Effect | Fix |
|---|---|---|
| (a) `-pr` scans run with SCM off, so every line is "new code" | coverage on new code = whole-repo coverage: web (63%) fails every PR, API (>80%) passes every PR | **A1:** gate `weysure-pr` with only "New issues > 0"; coverage per PR from changed lines in Jenkins (developers) |
| (b) one shared `-pr` project per app keeps history | an issue seen by an earlier PR is **reopened with its old date**, so it is not new and the gate passes (PR-95 #3, PR-118 #1 with S3776; main's gate caught it after merge) | **B1:** each PR build deletes + recreates the `-pr` project and selects `weysure-pr` under the existing lock, then base scan, then PR scan |

Decided by Adebayo 2026-10-21 23:45 WAT. Rejected: lowering main's gate (weakens main), SCM on (planted issue passed, proven 10-21),
per-build unique project names (orphans need a sweeper), diffing issue lists ourselves (fragile), Community Branch Plugin (rejected 10-09).

## What changed

| Where | Change |
|---|---|
| SonarQube UI | Quality gate **`weysure-pr`**: New issues > 0 only (no coverage, duplication or hotspot conditions: with SCM off each measures the whole repo). Assigned to `weysure-api-pr`, `weysure-web-pr`. Main projects keep their gate |
| SonarQube UI | User **`jenkins-sonar-pr`** (local, password discarded): global **Create Projects** only; Default template "Project Creators" = Administer; Administer on the two existing `-pr` projects; **user token**, 90 days |
| Vault `secret/platform/jenkins` | new key `sonar_pr_admin_token` (`kv patch`, stdin via `read -rs` + `printf %s`): len 44, no trailing newline, other 4 keys kept |
| gitops `bootstrap/apps/jenkins.yaml` | `additionalExistingSecrets` + JCasC string credential **`sonar-pr-admin-token`** |
| gitops `platform/ci-secrets/externalsecrets.yaml` | comment only (key list) |

The existing `sonar-token` is a **global analysis token**: it can upload scans but SonarQube refuses project admin calls from it,
whatever its user's rights. That is why B1 needs a second credential.

## Order (it matters)

1. Token into Vault → 2. force-sync ExternalSecret `jenkins-platform` and check the key **name** is in the Secret → 3. merge gitops.
The Jenkins pod mounts the key as a file; merging first would leave `jenkins-0` unable to start until the hourly refresh.

## Verification

| Check | Result |
|---|---|
| Vault key | `token_len=44 trailing_newline=false`, keys = admin_password, admin_user, sonar_pr_admin_token, sonar_token, webhook_secret |
| Secret `jenkins/jenkins-platform` | key names include `sonar_pr_admin_token` before merge |
| Argo | root `92aaf4d`; `jenkins` Synced/Healthy |
| Jenkins | `jenkins-0` restarted, Ready; `/run/secrets/additional/jenkins-platform-sonar_pr_admin_token` present; credential id in `credentials.xml`; log `Jenkins is fully up and running` 23:36:36 UTC |
| Not yet proven | that the token can delete/create/select-gate. First proven by the developers' throwaway proof PR |

## Risk

- The token is bound in **PR builds**, whose Jenkinsfile developers control. Blast radius: projects `jenkins-sonar-pr` administers
  (the `-pr` scratch projects); it cannot touch `weysure-api` / `weysure-web`. This meets the trigger of the deferred
  "`jenkins` namespace NetworkPolicy" item (checklist, deferred follow-ups).
- Token expiry (≈ 2027-01-19): delete/create return 401 → PR builds fail closed (no gate is skipped). Rotate before.

## Operate / roll back

- Rotate: SonarQube → Users → `jenkins-sonar-pr` → Tokens → generate → `vault kv patch` as above → force-sync → JCasC reads the
  file only at start, so `kubectl -n jenkins rollout restart statefulset jenkins` (Adebayo, between builds) → revoke the old token.
- Roll back: revert gitops #87 (Jenkins restarts); the Vault key can stay; un-assign `weysure-pr` (assign the old gate back) to undo A1.

## Follow-ups

- Developers: B1 Jenkinsfile (API + web) + proof; A1 changed-line coverage (Train 2). Web needs #61 (SCM off) first.
- `jenkins` NetworkPolicy (deferred, trigger met).
