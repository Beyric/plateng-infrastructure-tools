# SOP — A deal's chat ends with the deal: API #134 and web #71 live

**Shipped:** [Weysure-API #134](https://github.com/Beyric/Weysure-API/pull/134) merge 2026-10-30 22:23:40 UTC (approved head `80a90879`), promote gitops `95acd686`, **ROLLED OUT 23:28 UTC as `7208ab9cf0ba`**; then [Weysure #71](https://github.com/Beyric/Weysure/pull/71) merge 2026-10-31 08:57:54 UTC `f87f1b81` (approved head `3399c65d299b81c8addedc22b1578fa6477d1f33`), `main` build green 09:10 UTC, promote gitops `5071a83d`, **ROLLED OUT as `f87f1b814241`** (web ×2 Ready 09:14 UTC) ·
**Kind:** developer releases, **no migration** (Alembic head stays `b3f6a9d2c814`; not read live) · **Cost delta:** $0 ·
Notes and replies: `platform-note-2026-10-30-chat-closes.md`, `platform-reply-2026-10-30-{chat-closes-order,api134-go,api134-live}.md`, `platform-reply-2026-10-31-{web71-go,web71-live-and-train5}.md`.

## Why

After #130 and the chat fix, a deal's chat stayed open after the deal ended. The goal: a finished deal must not keep taking messages, but its history stays readable, and the web must say so.

## How

| Piece | Behaviour |
|---|---|
| API #134, **allowlist** | chat open only while the deal is `IN_ESCROW`, `DELIVERED` or `DISPUTED`; anything else, or a thread with no deal, is closed. A send to a closed chat is **409 `This chat has ended because the deal is over.`**; `GET /messages/threads` carries `chat_open`. Typing, reads and receipts are not gated. An accepted race of milliseconds (no lock) |
| Web #71 | reads `chat_open` from `GET /messages/threads`; **only `false` ends the chat**, so web and API can deploy in either order. The ended notice replaces the input; history stays. A failed send refetches the thread list, so a deal ending mid-chat removes the input. The input became a `textarea` that grows to about six lines: Enter sends and Shift+Enter adds a line on desktop; on a touch screen Return adds a line and the Send button sends |

## Decisions

| Decision | Why |
|---|---|
| Order: #133 → #134 → web #71 → Train 5 API; one release at a time, a GO per exact SHA | a notice with no `chat_open` is a worse day than waiting; blame stays clear |
| Allowlist, not a denylist | it fails closed |
| **Counts-only prod read before the #134 GO** (`HANDOFF-scripts/chat-counts.sql`, tested on a throwaway Postgres with a seed): 1 thread, on a `RELEASED` deal (Adebayo's test deal); 0 with no deal; 0 other | proves nothing unexpected closes; no names or ids leave the DB |

## Verification

| Check | Evidence |
|---|---|
| #134 live | 3 pods on `7208ab9cf0ba`, 0 restarts, no errors, no 5xx; flags read from the boot `[FLAGS]` line (all three `BUSINESS_*` false) |
| #134 by Adebayo | on his `RELEASED` test deal, sending is refused and the history is still readable |
| #71 CI | PR-71 #1 built exactly `3399c65d`: 225 files, **3550 of 3550** tests; Sonar gate PASSED, `new_violations` 0; Trivy 0 unfixed CRITICAL |
| #71 live | web ×2 on `f87f1b814241`, Ready, 0 restarts, Argo 32/32, `weysure.com` 200, 0 error lines |
| #71 by Adebayo (10-31 ~10:20 WAT) | the ended chat shows the notice and no input; a running chat takes several lines |
| **Not run** | the touch-screen Return rule on a real phone |

## Operate / roll back

API: image-only to `955818887811` (reopens closed chats; nothing else). Web: image-only to `ba5875b98ca8` (single-line input, no notice). Neither has a migration.

## Follow-ups

- [ ] Adebayo: the touch-screen Return check on a phone.
- [ ] Web: the 409 message for a duplicate rating (`fix/rating-already-rated-409`, after Train 5).
