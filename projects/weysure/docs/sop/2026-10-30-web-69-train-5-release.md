# SOP — Web Train 5 (#69) live

**Shipped:** [Weysure #69](https://github.com/Beyric/Weysure/pull/69) merged 2026-10-30 18:32:03 UTC as a **merge commit** `3722a308e9c7` (parents `2b49b4a4` and the approved head `01e4cfe3`) → `main` build #59 green 18:46 UTC → promote gitops `bd2a3758` → Argo `weysure-web` Synced/Healthy 18:52 UTC → web ×2 on `3722a308e9c7` ·
**Kind:** developer release (web), **no API change, no migration** · **Cost delta:** $0 ·
Notes and replies (`weysure/docs/`): `platform-note-2026-10-30-train-5-web*.md`, `platform-reply-2026-10-30-train5-web-{sonar,not-yet,second-test,go,live}.md`.

## Why

The developers' fifth web release. The gate and the build took several heads: Sonar found new issues that were fixed in code (never "Accepted"), and each new head was re-checked before our GO for the exact commit.

## Decisions

| Decision | Why |
|---|---|
| GO only for the exact approved commit `01e4cfe3`; any push is a new commit we check again | approval is of content; the merge carried `--match-head-commit` |
| Sonar findings fixed in code | the gate stays meaningful; a local `lint:sonar` 0 does not prove the gate (parity gap, see the quoted-tag and parity SOP) |
| One release at a time: no API merge until the web roll was confirmed | blame stays clear |

## Verification (live, 2026-10-30)

| Check | Evidence |
|---|---|
| Promote | gitops `bd2a3758`: web tag `2b49b4a4e5f2` → `"3722a308e9c7"`, one line. **The new quoted-tag form in the Jenkinsfile ran on a real `main` build** |
| Pods | 2 web pods on `3722a308e9c7`, Ready, 0 restarts, on two different nodes; no error lines in the web logs; `https://weysure.com` 200; API untouched on `174036317683` |

## Operate / roll back

Image-only in `images.yaml` back to `2b49b4a4e5f2`. No migration and no API dependency. Never past `6bef32860f30` (`d71f3a7595bc` carries the `next` CVE).

## Follow-ups

- [x] The release branch `release/2026-11-5-web` may be deleted (told to the developers).
