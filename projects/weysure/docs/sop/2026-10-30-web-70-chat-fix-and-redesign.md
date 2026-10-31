# SOP — Web #70: chat send fix and chat redesign live

**Shipped:** [Weysure #70](https://github.com/Beyric/Weysure/pull/70) merged as a **merge commit** (approved head `4b87bd8bc5171baa0b5b8f2b002da6264e3fc287`, `fix/chat-send-and-widget`) → live as **`ba5875b98ca8`**, web ×2, 2026-10-30 evening ·
**Kind:** developer release (web), **no API change, no migration** · **Cost delta:** $0 ·
Notes and replies: `platform-note-2026-10-30-web-chat-fix*.md`, `platform-reply-2026-10-30-{web-chat-422,web-chat-fix-sonar,web-chat-fix-go}.md`.

## Why

Adebayo's live two-session chat test on production (the #130 test, finally possible once web #69 added a chat entry) found that **every message after the first returned 422**. Root cause: the web's `sendMessage` omitted `thread_id` and `sender_id`, which the API's `MessageCreate` requires; the contract test did not cover that route's body.

## What changed

| Change | Detail |
|---|---|
| The fix | `sendMessage` sends `thread_id` and `sender_id`; `MessageContext` passes the signed-in user's id (falls back to the deal route when the id is missing). Proof bodies in `docs/chat-send-proof/` |
| The redesign (bundled at Adebayo's confirmation) | new `message-center.tsx` layout; Enter-to-send moved from `onKeyPress` to `onKeyDown` with the same condition; attach button hidden on a draft chat |

## Decisions

| Decision | Why |
|---|---|
| GO withheld until the 422 fix and the redesign were each read | we read the whole `message-center.tsx`: the logic is identical to the live one apart from the dropped `onClose` prop |
| GO for the exact commit `4b87bd8b` | a fix is a new SHA with its own check |
| Bundle the redesign with the fix | Adebayo's choice; one web release, one window |

## Verification

CI on exactly `4b87bd8b` (PR-70 #2): **3548 of 3548** unit tests, changed-line coverage 122 of 123 lines (99.2%), Sonar gate PASSED and `new_violations` 0, Trivy no unfixed CRITICAL. Live: web ×2 on `ba5875b98ca8`. **Adebayo's two-session test on production passed**: message, replies, typing, read ticks, mark delivered, confirm, rating. **#130 closed.**

## Operate / roll back

Image-only to `3722a308e9c7` (brings the 422 back) or `2b49b4a4e5f2` (removes the chat entry). We fix forward by preference. Never past `6bef32860f30`.

## Follow-ups

- [x] A finished deal's chat must stop taking messages (API #134 and web #71, next SOP).
- [ ] The touch-screen Return rule is not yet run on a real phone.
