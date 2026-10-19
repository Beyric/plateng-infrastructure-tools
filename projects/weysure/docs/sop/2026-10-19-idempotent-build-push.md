# SOP — Idempotent Build & push (Weysure-API #90, web #57) live

**Shipped:** API #90 merged 2026-10-17 23:31:15 UTC (rebase-merge, `main` → `7770cf8`, tree identical to the approved
`b0190ac`) → main #68 promoted `7770cf806803` (gitops `516c67a`) → all 4 API pods by 2026-10-18 00:17:37 UTC. Web #57 merged
2026-10-19 11:25:11 UTC (`main` → `3106a37`, tree identical to the approved `9378e77`) → main #52 green 11:33:39, promoted `3106a37bdb8e` (gitops `681596f`) → both web pods 11:38:51 UTC · **Kind:** CI change
(Jenkinsfile only, no migration, no app code) · **Cost delta:** $0 · Notes/replies:
`weysure/docs/platform-note-2026-10-17-idempotent-build-push.md`, `platform-note-2026-10-18-90-live.md`,
`platform-reply-2026-10-18-90-57-go.md`, `platform-reply-2026-10-18-90-live.md`, Replay script
`weysure/docs/replay-2026-10-18-90-step3.Jenkinsfile`

**Status: API live and proven (steps 1–3); web live and proven (steps 1–2; step 3 is the same code, proven on API).**

## Why

ECR tags are immutable (`<sha12>` per main commit). When a main build pushed its image and then died (spot reclaim, the
30-min timeout), every re-run failed at the push, and the only way out was a hand-edited Replay. Seen on #75 (2026-10-16)
and #79 (main #66 aborted 2026-10-17). The fix was the developers' promise in #78's note.

## How (what the stage now does)

| Stage | Behaviour |
|---|---|
| Build & push | `aws ecr batch-get-image` on `$IMAGE:$TAG` (new pinned `amazon/aws-cli:2.22.35@sha256:6977c83a…` container, pod identity, no stored keys). `ImageNotFound` → kaniko builds as before, now with label `org.opencontainers.image.revision=$GIT_COMMIT`. Tag exists → log digest + `imagePushedAt`, read the image config, **reuse only if the revision label equals `$GIT_COMMIT`**; no label or a different value → fail. Any other ECR answer → fail |
| Image scan | Trivy runs on every path, including a reused image |
| Promote | 1) **tip guard:** `git ls-remote` of the app repo's `main` (with `github-app`); not the tip → `not promoting`, build **UNSTABLE**, no push; lookup error → fail. 2) **no-op:** `images.yaml` already has the tag → `already promoted`, no commit |

**Decisions (platform review, 2026-10-17):**

| Decision | Why |
|---|---|
| Skipping the push required the tip guard and no-op promote first | the failed push was the only thing stopping a re-run of an old build from promoting an old image (a silent rollback) |
| Revision label checked on reuse; a missing label fails | a tag is a name, not proof; fail closed on every pre-#90 image |
| Tip lookup with `github-app`, not `scm.userRemoteConfigs` | no sandbox-sensitive Groovy; the credential is already bound for the gitops push |
| Accepted: a non-tip main build ends UNSTABLE and does not promote; if the newer build fails, nothing promotes until main is green | only the tip may reach prod |

## Verification (live)

**Multibranch runs the Jenkinsfile of the commit being built.** A plain re-run of a pre-#90 build runs the old Jenkinsfile
and never reaches the new checks, so step 3 was a **Replay** of that build with #90's Jenkinsfile (Tests and Quality gate
removed, Build & push and Promote verbatim — diffed against `7770cf8`).

| Step | Build | Result |
|---|---|---|
| 1. New build labels + promotes | API main #68 (`7770cf8`) | pushed 2026-10-18 00:08:31 UTC `sha256:c72c18e8…`; label read back from ECR = `7770cf8…`; gitops `516c67a`; 4 pods on the tag |
| 2. Re-run skips | API main #69 (same commit) | `ECR tag weysure-api:7770cf806803 already exists` (same digest, same pushed-at) → `revision label matches … skipping kaniko build` → Trivy passed → `already promoted` → SUCCESS; gitops head unchanged |
| 3. Unlabelled image refused | API main #70 = Replay of #67 (`a9e66ab`), 2026-10-19 | `image has no org.opencontainers.image.revision label; refusing to reuse it` → FAILURE; no Trivy, no promote, gitops head still `516c67a`, pods unchanged |
| Web 1. New build labels + promotes | web main #52 (`3106a37`) | `ECR tag … not found - building`; pushed 2026-10-19 11:32:50 UTC `sha256:e442e99a…`; label read back from ECR = `3106a37…`; `promoted web -> 3106a37bdb8e` (gitops `681596f`); 2 pods on 2 nodes, 0 restarts; `weysure.com` 200. (The second kaniko push, tag `0cd12796…`, is a cache layer: cache shares the repo, decision 2026-10-03) |
| Web 2. Re-run skips | web main #53 (same commit), 2026-10-19 | `ECR tag weysure-web:3106a37bdb8e already exists` (same digest `e442e99a…`, same pushed-at 11:32:50Z) → `revision label matches … skipping kaniko build` → Trivy passed → `already promoted` → SUCCESS; gitops head still `681596f`, web pods unchanged |

The UNSTABLE "not main's tip" path has not run yet; it will on the first main build that is overtaken by a newer merge.

## Operate / roll back

- **Spot-aborted or timed-out main build:** press **Build Now** on `main` (or re-run the same build). It reuses the image if
  the label matches, scans it and promotes only if it is still main's tip. No Replay needed any more.
- **A main build ends UNSTABLE "not main's tip":** expected when a newer merge landed; the newer build promotes. If that one
  failed, fix main; do not Replay the older build to force it out.
- **"refusing to reuse it":** the tag in ECR was not built from this commit (or predates #90). Do not delete the tag;
  investigate how it got there.
- **Rollback:** revert the PR in the app repo (Jenkinsfile only); the next main build runs the old pipeline. No cluster change.

## Follow-ups

- Watch for the first UNSTABLE "not main's tip" build and note it here.
- Pin the other agent images by digest (developers' follow-up).
- PR builds share main's IAM role and the `github-app` credential (go-live item, with merge enforcement).
