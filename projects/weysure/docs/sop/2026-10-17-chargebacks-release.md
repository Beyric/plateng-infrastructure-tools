# SOP — Weysure-API #79 (card chargebacks) live, off

**Shipped:** #79 merged 2026-10-17 20:57:23 UTC (rebase-merge, `main` → `a9e66ab`, tree identical to the approved
`44f62bf`) → main build #66 **aborted** 21:07 (spot interruption) → #67 green 21:50:35, promoted `a9e66abf2ebb` (gitops
`e859a07`) → Argo 21:56:08 → migration `e1a7c4d9b3f2 → a7e3c9b25d14` → all 4 API pods 21:58:21 UTC · **Kind:** developer
release, money path, expand-only migration, ships **off** · **Cost delta:** $0 · Notes/replies:
`weysure/docs/platform-note-2026-10-17-79-{go,live}.md`, `platform-reply-2026-10-17-79-{review,go,live}.md`

**Status: live and verified; `CHARGEBACKS_MODE=off`, `CHARGEBACK_AUTO_RESPOND_ENABLED=false` (unset in gitops).**

## What it is

Paystack `charge.dispute.*` intake, account freeze, evidence PDF + response to Paystack, and recovery of lost money
(`CHARGEBACK_DEBIT` ledger rows, a debt sweep at credit sites, taint holds on payouts funded by disputed top-ups). New
tables `chargeback_cases`, `chargeback_events`, `chargeback_recoveries`, `account_freezes`; `users.frozen_at`; 7 worker job
kinds (`chargeback.sync/respond/auto_respond/reminder/recover/debt_sweep/extend_holds`); new dependency `fpdf2 2.8.9`
(+ pillow, fonttools, defusedxml). While off, a dispute only raises the admin alert `chargeback_ignored`.

## Review (money path: two Opus reviewers + lead verification)

44 commits, 5,225 app lines on `8bcf5e8`. Every required finding was re-verified in the code before it went to the
developers. **Changes requested (Adebayo: fix before merge):**

| # | Finding | Fixed in `44f62bf` (verified) |
|---|---|---|
| R1 | `off` did not stop recovery or the debt sweep (0 mode checks in `chargeback_recovery.py` / `chargeback_debt.py`; `sweep_credit` at 6 credit sites) — the SOP's rollback was untrue | early return unless `enforce` in every money path |
| R2 | Bank retry of a card refund (`retry_with_account`) ignored the chargeback freeze | `lock_user`, `assert_not_frozen`, `assert_no_chargeback_on_record` first |
| R3 | `CHARGEBACK_DEBIT` rows shared `created_at` with siblings and the swept credit; reconciler ordered by `created_at` only → false mismatches / paging | per-row stamp after the user's newest row (checked: `autoflush=False`, but every site flushes); `id` tie-breaker |
| R4 | "Image revert is safe" was wrong after `enforce` (old image: `LookupError` on `CHARGEBACK_DEBIT`, ignores `frozen_at`) | docstring/SOP corrected; downgrade refuses on any case or debit row |

Fix tests + `test_migrations` + single-head on PG16: 135 passed. Platform checks: image installs from `poetry.lock`
(`requirements.txt` is stale); jobs inert while off; settings default off; `api-egress` already allows public 443 (the
app's `PAYSTACK_DISPUTE_UPLOAD_HOSTS` allow-list is the only upload control: exact host, https/443, no userinfo/IP).

## The release

| Step | Time (UTC) | Note |
|---|---|---|
| Merge | 20:57:23 | rebase-merge; developers held all other merges |
| main #66 | 20:58:57 → **aborted 21:07:03** | Karpenter `initiating delete from interruption message` for `ip-10-0-4-244` at 21:04:27; agent pod evicted in Tests. **ECR had no `a9e66abf2ebb` tag** → plain re-run safe (no Replay) |
| main #67 | 21:14:47 → 21:50:35 | green; promote 21:50:32 (`e859a07`) |
| Argo + migration | 21:56:08 | PreSync `Running upgrade e1a7c4d9b3f2 -> a7e3c9b25d14`, no lock retries |
| 4/4 pods | 21:58:21 | |

**Gotcha:** AWS SSO expired ~21:43 mid-release; an OpenAPI read at 21:57 still showed the old schema because pods were
rolling 21:56–21:58. Don't read "old schema" as stuck until Argo's revision and the pod tags are known.

## Verification (live)

| Check | Result |
|---|---|
| Migration log (Loki `container="migrate"`) | `Running upgrade e1a7c4d9b3f2 -> a7e3c9b25d14, Chargebacks: …`, clean |
| DB (`db-oneoff`, Adebayo, 22:03) | `alembic current` = `a7e3c9b25d14 (head)` |
| New code serving | public OpenAPI 200 → 217 schemas, 0 → 9 chargeback paths (baseline before merge) |
| Off is inert | worker startup sweeps 21:57:22: `ensure_recoveries/response_jobs/sync/debt_sweep` `0 job(s) scheduled` |
| Flags | no `CHARGEBACK*` key in gitops prod |
| Pods / edge | 4/4 on tag, 0 restarts, api on two nodes; 0 errors, 0 × 5xx, health 200 |
| Reconciliation | old worker's last run 21:51:31 `1 users, 0 mismatches`; new worker (`api-worker-5c4f874659-dcfj5`, Loki `pod=~"api-worker-5c4f874659-.*"`): 22:21:45 and 22:51:56 UTC `1 users, 0 mismatches`, each followed by `rescheduled to` +30 min (proof the loop runs, not just silence) |

## Operate / roll back

- **Until `enforce` has ever run:** `scripts/db-oneoff.sh a9e66abf2ebb alembic "downgrade e1a7c4d9b3f2"` (with this image;
  refuses on any case/debit row), then API image `681ce3b37762`.
- **After `enforce`:** rollback is `CHARGEBACKS_MODE=off` on this image only. Never an older image.
- `enforce` is its own note, review and go (below). Auto-respond only after one real manual contest.

## Follow-ups (the `enforce` gate)

- Developers: E1 lock order (case holds before users; sorted user locks), E2 prove/refute the double loss on card money after
  write-off/partial recovery with a test, E3 taint holds bind whatever the modes, E4 admin detail masks `evidence_snapshot`,
  E5 `/sync` rate limit, E6 `handle_recover` error typing + partial-dispute cap, E7 real upload host.
- Adebayo: Paystack dashboard sends `charge.dispute.create/.remind/.resolve` to the live webhook.
- Platform: Loki alerts on the chargeback log lines (decoy tests); set `PAYSTACK_DISPUTE_UPLOAD_HOSTS` in gitops
  `commonEnv` once the first refused-host alert names it.
