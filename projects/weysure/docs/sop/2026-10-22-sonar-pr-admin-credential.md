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
| SonarQube UI | Quality gate **`weysure-pr`**: New issues > 0 only (no coverage, duplication or hotspot conditions: with SCM off each measures the whole repo). **Correction 2026-10-24: not created on 10-21** (see below); created 2026-10-24 10:10 UTC. Not the default gate. Not assigned by hand: B1 selects it on every PR build, because recreating a project resets it to the default gate. Main projects keep the default "Sonar way" |
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
| Token can delete/create/select-gate | **proven 2026-10-24**: API PR-121 #4 / PR-122 #4: delete 204, create 200, select 204; PR-122 gate `new_violations` actual 1 (planted S1481 only) |

### Correction (2026-10-24): the gate was missing

All 12 developers' B1 builds (10-21 23:52 → 10-22 12:44 UTC) failed on `qualitygates/select` → **404**: gate `weysure-pr` did not exist.
The SonarQube access log (from 10-17) shows the 10-21 23:19–23:27 UTC user/permissions/template/token calls and no
`POST /api/qualitygates/create` at any time. This SOP and the checklist recorded the gate as done from the plan, not from the server.

Second trap, same day: a **new gate is pre-filled with the four "Sonar way" conditions** (new issues, coverage < 80, duplication > 3,
hotspots reviewed < 100). The first create left all four; Adebayo then deleted three. Verify the conditions in SonarQube's own DB (read-only):

```
kubectl -n sonarqube exec sonar-postgres-0 -- sh -c 'psql -U "${POSTGRES_USER:-sonarqube}" -d "${POSTGRES_DB:-sonarqube}" -At -c "select g.name, m.name, c.operator, c.value_error from quality_gates g left join quality_gate_conditions c on c.qgate_uuid=g.uuid left join metrics m on m.uuid=c.metric_uuid order by g.name;"'
```

Expected: `weysure-pr|new_violations|GT|0` and nothing else for `weysure-pr`. API calls of any kind (UI included) are in
`/opt/sonarqube/logs/access*.log` in `sonarqube-sonarqube-0` (method, path, status, browser vs curl): check setup claims there.

## Risk

- The token is bound in **PR builds**, whose Jenkinsfile developers control. Blast radius: projects `jenkins-sonar-pr` administers
  (the `-pr` scratch projects); it cannot touch `weysure-api` / `weysure-web`. This meets the trigger of the deferred
  "`jenkins` namespace NetworkPolicy" item (checklist, deferred follow-ups).
- Token expiry (≈ 2027-01-19): delete/create return 401 → PR builds fail closed (no gate is skipped). Rotate before.

## Operate / roll back

- Rotate: SonarQube → Users → `jenkins-sonar-pr` → Tokens → generate → `vault kv patch` as above → force-sync → JCasC reads the
  file only at start, so `kubectl -n jenkins rollout restart statefulset jenkins` (Adebayo, between builds) → revoke the old token.
- Roll back: revert gitops #87 (Jenkins restarts); the Vault key can stay. To undo A1, revert the developers' B1 Jenkinsfile step (it selects `weysure-pr`); deleting the gate instead makes every PR build fail closed (select 404).
- Rebuild the gate (if ever lost): Quality Gates → Create `weysure-pr` → **delete the pre-filled Coverage, Duplicated Lines, Security Hotspots Reviewed** → keep Issues > 0 → never "Set as default" → check with the DB query above.

## Follow-ups

- Developers: B1 **API proven 2026-10-24** (GO #121 `78323f6`). **Web not proven**: PR-64 #4 failed with `new_violations` 345: the base scan in the hidden `.base-scan` worktree analysed only `tests/` + `e2e/` (231 vs 724 JS/TS files; most likely SonarQube skips hidden dirs with `sonar.sources=.`) → developers rename the worktree, re-prove #63/#64. A1 changed-line coverage (Train 2).
- `jenkins` NetworkPolicy (deferred, trigger met).
