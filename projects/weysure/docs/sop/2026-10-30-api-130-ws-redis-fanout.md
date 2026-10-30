# SOP — Weysure-API #130 (WebSocket fan-out over Redis) live

**Shipped:** [#130](https://github.com/Beyric/Weysure-API/pull/130) merged 2026-10-30 08:55:38 UTC as a **merge commit** (`main` → `a5198545f609`, approved head `e44547db`) →
promoted `a5198545f609` (gitops `b36a381`, 09:44 UTC) → api ×2 + api-worker Ready ~09:46–09:47 UTC ·
**Kind:** developer fix, **no migration**, default-on setting with a rollback switch · **Cost delta:** $0 ·
Notes/replies (`weysure/docs/`): `platform-note-2026-10-26-ws-redis-fanout.md`, `platform-reply-2026-10-29-pr130-review.md`, `…-pr130-sonar-red.md`, `platform-reply-2026-10-30-pr130-go.md`, `…-pr130-window-open.md`, `…-pr130-live-and-seller-search.md`.

**Status: live; platform checks pass; the two-session chat test is NOT done** (no UI entry point to chat in the web build, see Follow-ups).

## What it is and why

Chat typing, read receipts, message pushes, user notifications and the admin broadcast travel over WebSockets. With 2 api replicas × 2 gunicorn workers, a frame reached the recipient only when their socket sat in the **same worker** (about 1 in 4). The developers' production-image run measured 17/30 typing, 9/30 message pushes and 20/30 read receipts delivered with the old behaviour, and 30/30 on each with the fan-out.

Now every outbound frame is also published to Redis and every API process subscribes, so the frame arrives whichever worker holds the socket.

| Property | Value |
|---|---|
| Setting | `WS_REDIS_FANOUT_ENABLED`, default **true**; `false` restores the old same-process delivery exactly |
| Envelope | HMAC-signed (key derived from `SECRET_KEY`); unsigned, tampered, older than 60 s or more than 5 s ahead are dropped; `kind` and `target` are inside the signature; own-origin messages are skipped (no double delivery) |
| Back-pressure | publish bounded to 1 s behind a 10 s circuit breaker; the subscriber never awaits a send: each (kind, target) has a bounded queue (32, drops when full) drained by its own task; every admin has their own queue |
| Redis outage | degrades to same-process delivery with one `[WS FANOUT]` WARNING a minute; never a crash or a hung request |
| Delivery | at-most-once (documented in the developers' SOP) |
| Auth, handshake, close codes, frame shapes | unchanged; `WS_ALLOW_URL_TOKEN=false` unchanged |
| New load | one `PUBLISH` per outbound frame (typing is limited to 10/s per socket) and one long-lived pub/sub connection per API process; cleartext chat on Redis is accepted because NetworkPolicy `redis-ingress-from-api` limits who can reach it |

## Why it went the way it did (decisions)

| Decision | Why |
|---|---|
| GO for exact `e44547db` after our own Opus review | the change touches the WS auth path and an outage path. Review: no security blocker; M1 (the subscriber awaited sends, so one slow socket stalled all) and M2 (one admin path bypassed the fan-out) fixed; M3 (cleartext chat in Redis) accepted |
| Merge only in a watched window we announce | a roll of the live API that carries chat; a main build is ~50–65 min and a spot reclaim can kill it |
| Merge commit with `--match-head-commit` | GitHub enforces the approved SHA |
| Chat test not a condition of "live" | the web build has no way to open chat (below); we recommended treating #130 as confirmed on the platform checks; Adebayo then sent the Train 4 GO, which carried that exception, and the chat test moved to after Train 4 |

## Verification (live, 2026-10-30)

| Check | Evidence |
|---|---|
| Merged tree | `a5198545f609` = merge of main `7cd29776` and `e44547db`; PR-130 #5 on `e44547db`: 5618 passed, Sonar gate PASSED, 0 new issues |
| Pods | api ×2 + api-worker on `a5198545f609`, Ready, 0 restarts |
| Health and logs | `api.weysure.com/api/v1/health` 200; 0 `[WS FANOUT]` lines; no error or traceback lines |
| Settings | `WS_REDIS_FANOUT_ENABLED` not set anywhere, so the default (true) applies |
| Node loss | a node was reclaimed about a minute after the roll; the pods moved and were Ready again with no incident |
| **Not exercised live** | two sessions seeing typing, message and read ticks. The developers' run (`scripts/live_verify_ws_fanout.py`, captures in `docs/fe-integration-guide-captures/`) is the evidence for the delivery rates |

## Operate / roll back

- Switch off: set `WS_REDIS_FANOUT_ENABLED: "false"` in the api and worker values (`projects/weysure/environments/prod/apps/api/values.yaml`); Reloader restarts the pods. Back to the old same-process delivery.
- Image rollback: promote the previous tag through gitops (no migration). Nothing depends on the commit.
- Watch for: `[WS FANOUT]` warnings in a steady state (Redis trouble), Redis `PUBLISH` rate.

## Follow-ups

- [ ] Two-session chat test (typing, message, read) once the web build has a chat entry point; asked of the developers in `platform-reply-2026-10-30-train4-live.md` §3c.
- [ ] Optional: a Grafana panel for Redis `PUBLISH` rate.
