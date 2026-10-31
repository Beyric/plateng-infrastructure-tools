# Runbook — a deal carries `refund_send_unconfirmed_at` (clearing the refund marker)

**Applies to:** API Train 5 and later (live 2026-10-31, `c157f08ce180`). **Who runs it:** Adebayo (`db-oneoff.sh write` is a mutating command). Source of the facts: the developers' note `weysure/docs/platform-note-2026-10-31-refund-marker-clear.md`; the SQL below was tested on a throwaway Postgres (JSON column, enum status, seeded rows), not on the real schema.

## What the marker is

When `/refund` or `/split` cannot prove whether a Paystack refund was sent (timeout, a 5xx or unusable answer, or a reconcile refusal), the API sets `refund_send_unconfirmed_at` in `escrow_transactions.extra_metadata` (column type **JSON**, not JSONB; value = ISO time, naive UTC). While it is set, `/release`, `/split`, auto-release and `close_lost` refuse the deal. Its companion `refund_unconfirmed_escalated_for` is the once-flag of the 24-hour admin alert. **Only a successful `/refund` removes the marker** (it adopts or sends the refund, records it and clears it). Admin alerts that point here: `escrow_refund_send_unconfirmed`, `escrow_refund_unconfirmed_unresolved`, `escrow_refund_reconcile`.

## First choice: no database edit

Ask the developer to call `/refund` again for the right amount. It lists the refunds at Paystack, adopts one that landed, records it and clears the marker with no money moved. Wait at least 2 hours after the marker's time first (Paystack's refund list lags and the lag is not documented).

## A clear is a payout decision

- If the deal has a live auto-release job, the marker is the only thing holding it. It looks again every 6 hours: once the marker is gone and the date has passed, the next look pays the developer, and nothing asks again. If a refund did land, that pays on top of it.
- A lost answer on a full `/refund` or on `/split` has already cancelled the deal's clocks, so such a deal has no auto-release job until the next worker start (`ensure_auto_release` is a startup sweep); then the same warning applies.
- **Clear only when you have proved there is no refund we have not recorded.**

## Steps

1. **Stop anything acting on the deal.** Confirm no developer is calling on it. Read the status (next step); if it is not `FUNDED` or `ON_HOLD`, stop and ask the developers.
2. **Read the deal** (counts and times only, no personal data):
   ```
   scripts/db-oneoff.sh <api-image-tag> read "SELECT id, status::text, extra_metadata->>'refund_send_unconfirmed_at' AS marker, extra_metadata->>'payment_reference' AS payment_reference, extra_metadata->>'total_refunded_amount' AS recorded_naira FROM escrow_transactions WHERE id = '<ESCROW_ID>'"
   ```
   `<api-image-tag>` is the live API tag; `<ESCROW_ID>` is the deal id from the alert.
3. **List the refunds at Paystack** for that `payment_reference`: dashboard, or `GET /refund?transaction=<reference>`, on the right account (test or live, per the deal's key).
4. **Compare in the right units.** `live` = the sum of refund `amount` values in **kobo** with state `pending`, `processing`, `processed` or `needs-attention`; `failed`, `reversed`, `cancelled` count as nothing. `recorded` = `recorded_naira` from step 2 (Naira, 0 if empty). Compare `live` with `recorded × 100`.

   | Result | Meaning | Action |
   |---|---|---|
   | Equal, every refund has a known state and a whole amount | nothing unrecorded | safe to clear (step 6) |
   | `live` higher, extra is a whole Naira amount | a refund landed that we did not record | **do not clear**: the developer calls `/refund` for exactly that amount |
   | `live` higher with an odd kobo remainder, or more than the balance | nothing in the API can fix it | **do not clear**: a human decision on the money and a hand correction of `total_refunded_amount`; ask the developers first |
   | an unknown state or an unreadable amount | unknown | **do not clear**: wait or ask Paystack, list again |

5. **Wait out the settle window:** at least 2 hours after the marker's time.
6. **Decide what happens next, on purpose.** If the deal must not pay, hold it or set `requires_manual_review` in the same change (auto-release stops on that flag), before clearing.
7. **Clear it with one statement.** `db-oneoff.sh write` takes exactly one statement and commits it in one transaction; the guards in `WHERE` make it a no-op on the wrong row or a deal that already moved. It prints the rowcount: **it must be 1**; if it is 0, nothing changed, go back to step 2.
   ```
   scripts/db-oneoff.sh <api-image-tag> write "UPDATE escrow_transactions SET extra_metadata = ((extra_metadata::jsonb - 'refund_send_unconfirmed_at') - 'refund_unconfirmed_escalated_for')::json WHERE id = '<ESCROW_ID>' AND extra_metadata->>'refund_send_unconfirmed_at' IS NOT NULL AND status::text IN ('FUNDED','ON_HOLD')"
   ```
   The cast is needed because the column is JSON. `jsonb` reorders keys; nothing reads their order. Re-run the step 2 read: the `marker` column should now be empty.
8. **Record it:** who, when, the Paystack listing you saw, and why. This edit leaves **no audit row**, unlike the admin decisions.

## Rollback and limits

- A wrong clear cannot be undone by the API; restore the two keys with a `write` of the old values from your step 2 read, only after a human decision.
- **Before any image rollback of Train 5**, count the deals that carry the marker (`SELECT count(*) FROM escrow_transactions WHERE extra_metadata->>'refund_send_unconfirmed_at' IS NOT NULL`): an old image ignores the marker and can release such a deal on top of a refund that may have landed.
- **Not exercised:** this runbook end to end on a real deal, or a clear with a live auto-release job.

## Follow-up

The developers' follow-up PR (M1 "sending" marker before the Paystack call, an admin exit with a reason and an audit row that re-lists Paystack itself) replaces steps 5 to 7. Remove this runbook's hand edit when it ships.
