# SOP — Quoted image tag proven on real builds; the Sonar parity gap

**What:** two platform findings of 2026-10-30/31, one closed and one open. Records the proof for the first and the rule for the second.

## 1. The quoted promote tag is proven

**Problem (10-30, Train 4):** a 12-hex image tag that is all digits (`174036317683`, about 1 in 300) was written unquoted into `images.yaml`; YAML read it as a number, Helm printed `1.74036317683e+11`, the PreSync migrate Job got `InvalidImageName` and Argo waited on the hook. Prod never moved. See `2026-10-30-train-4-api-release.md`.

**Fix:** gitops #97 quoted the tag in `images.yaml`; the developers changed both Jenkinsfile promote steps to write `tag: "<12 hex>"` with a post-check (`grep -q "tag: \"${TAG}\""`) that fails the build if it is not quoted. The Groovy escaping could only be proven on a `main` build.

**Proof:** real `main` builds wrote the quoted form: web promotes `bd2a3758` (`tag: "3722a308e9c7"`) and `109da87e`, and API `247afc1`. A watcher's `grep -q "$TAG"` still matches a quoted tag.

**Still open:** the chart guard (ours): fail the render when the image tag is not a string (`charts/beyric-app/templates/_helpers.tpl`, with a `helm template` before/after diff).

## 2. The Sonar parity gap

The developers' local `lint:sonar` cannot reproduce rule **S7755** (`prefer-at`, unicorn) and does not cover `.mjs` files, so a local "0 findings" says nothing about rules the local config does not have. **The gate is the proof**: we read the Sonar database (`quality_gate_details`, `new_violations`) and the Jenkins log for the exact head, never the status text. Rule held for web #69/#70/#71 and API #133: **fix in code, never "Accepted"**; refactors are read for behavioural equivalence.

**Developers' follow-up (theirs):** a one-line parity change so local lint matches the gate.

## Follow-ups

- [ ] Platform: chart guard for a non-string image tag.
- [ ] Developers: local lint parity for S7755 and `.mjs`.
