# SOP: Jenkins builds only `main`, `release/*` and PRs

**Shipped:** plateng-gitops [#90](https://github.com/Beyric/plateng-gitops/pull/90) (`1e63105`), **merged 2026-10-24 18:30 UTC as `2e4ba9f8`** ·
**Kind:** Jenkins JCasC (Job DSL org folder) · **Cost delta:** fewer agent pods and spot nodes after every release merge

**Status: live 2026-10-24 20:24 UTC** (not 18:33, as this line first said). The merge at 18:30 updated only the org folder. The filter reached the repo jobs when Adebayo ran **Scan Organization Now** at 20:24 UTC. See "Correction" below.

## Why

On 2026-10-24, merging Train 1b (Weysure-API #123) closed 5 PRs at once. On its next scan Jenkins created a branch job for each of
those 5 branches and started build `#1` on all of them, alongside the `release/*` and `main` builds. Karpenter put the new spot nodes
in us-east-1b, which had no free /28 prefix blocks left (VPC CNI prefix delegation; CloudTrail `Client.InsufficientCidrBlocks`).
The `main` deploy build sat in `ContainerCreating` for about 55 minutes, until the stale builds were aborted by hand. Agent pods carry
`karpenter.sh/do-not-disrupt`, so those nodes could not be reclaimed while the stale builds ran.

**Root cause:** the `beyric` org folder used `gitHubBranchDiscovery { strategyId(1) }`, which means "exclude branches that are also
filed as PRs". That check only holds while the PR is open. Once the PR closes, the branch counts as a plain branch again, and nothing
restricted which branch names got a job.

## How

The fix adds one scm-api trait to the org folder's `traits {}`:

```groovy
headWildcardFilter { includes('main release/* PR-*'); excludes('') }
```

| Head | Before | After |
|---|---|---|
| `main` | built; Promote runs | unchanged (`when { branch 'main' }` still matches) |
| `release/*` with no open PR | built as a branch | unchanged |
| `release/*` with an open PR | built as `PR-<n>` | unchanged |
| PRs (`PR-<n>`, merge with target) | built | unchanged |
| `feature/*`, `fix/*`, … after their PR closes | **built as `#1`** | not built; the existing job is orphaned |

**Rejected:** branch strategy 2 ("only branches also filed as PRs"). `main` is never a PR head, so it would stop building and stop
promoting.

**Plugin check (live controller, 2026-10-24):** scm-api `728.vc30dcf7a_0df5` contains `jenkins.scm.impl.trait.WildcardSCMHeadFilterTrait`,
with Job DSL symbol `headWildcardFilter` (read from the class file). job-dsl is `3732.v9a_c49a_61a_313` and github-branch-source is
`1986.v801e40614d00`. The same block already uses `sourceRegexFilter` from the same package.

## What's involved

- `plateng-gitops/bootstrap/apps/jenkins.yaml`: `controller.JCasC.configScripts.jobs` (org folder `beyric`), 1 trait plus a comment.
- No plugin, chart version or StatefulSet change.

## Verification

- `pre-commit run --all-files` passes.
- `helm template jenkins/jenkins --version 5.9.56` before and after: the only diff is the JCasC jobs ConfigMap. The StatefulSet
  `checksum/config` is unchanged (`5dd98ddd…`, equal to live), so there is **no controller restart**; the `config-reload` sidecar
  applies the change.
- After merge (Adebayo): Beyric → Weysure-API → Configure shows "Filter by name (with wildcards)" = `main release/* PR-*`. After the
  scan, closed-PR branch jobs are listed as orphaned and nothing builds them. `main` and open PRs still build on the next push.

## Correction (2026-10-24 21:30 WAT): the filter was not live until an organization scan

| | |
|---|---|
| Symptom | 20:16 UTC: pushing `ci/jenkins-timeout-90` (Weysure-API #124) ~1 min before opening its PR started branch build `ci%2Fjenkins-timeout-90` #1 next to `PR-124` #1 (developers reported it) |
| Cause | The JCasC reload re-ran Job DSL and saved the **org folder** `beyric/config.xml` (18:33, has `WildcardSCMHeadFilterTrait`), but did **not** start an organization scan. A GitHub org folder copies its traits into each repo's multibranch job (`beyric/jobs/<repo>/config.xml`) **only during an organization scan** (`computation.log`). That scan runs daily (`periodicFolderTrigger 1d`); the last one was 10:59 UTC. Both repo jobs kept their 10:59 config with no filter |
| Wrong evidence | The 18:33 "Does not meet criteria" lines came from the branch-discovery strategy ("exclude branches that are also PRs"), not from the wildcard filter |
| Fix | Adebayo aborted the stray branch build and PR-125 #1 (stuck in `ContainerCreating` on us-east-1b prefix space), then ran **Scan Organization Now** on `beyric` (20:24:19 UTC, 2.9 s). Both repo `config.xml` files were rewritten at 20:24 and contain `<includes>main release/* PR-*</includes>`. The re-index lists non-matching branches without probing them; `main` "Met criteria", "No changes detected" |
| Lesson | Verify a setting where it is evaluated (the repo job's `config.xml`), not where it is written (the org folder). After any change to org-folder traits, run **Scan Organization Now** and grep both repo job configs |

## Operate / roll back

- **Merge only while no agent pod is running.** Run `kubectl -n jenkins get pods` and check that it shows only `jenkins-0`. Reloading
  JCasC re-runs Job DSL, which saves the org folder. It does **not** scan the organization: after the merge, run **Scan Organization Now**
  on `beyric`, then check `grep -A2 Wildcard /var/jenkins_home/jobs/beyric/jobs/<repo>/config.xml` for both repos.
- Merge command (Adebayo):
  `gh pr merge 90 --repo Beyric/plateng-gitops --squash --delete-branch --match-head-commit 1e63105296b8f84f803d1d86595ecd1a563e6883`
- Argo `jenkins` has `selfHeal: false`. Sync it if it doesn't sync on its own.
- Roll back: revert the commit (or delete the trait line), then **Scan Organization Now** again so the repo jobs lose the filter.
- New long-lived branches with no PR need their pattern added to `includes` or they won't build.

## Follow-ups

- us-east-1b /28 prefix exhaustion (`InsufficientCidrBlocks`) is tracked separately. This change only lowers the build burst.
- Orphaned branch jobs are removed by `orphanedItemStrategy` (7 days / 10 items). No manual cleanup is needed.
