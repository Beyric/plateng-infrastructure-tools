# SOP — web 7c live, wallet origin rules switched on (and API #65 alongside)

**Shipped:** 2026-10-13 · web #48 live 11:22 UTC (`4b9e2223c440`) → `ORIGIN_RULES_ENFORCED=true` live 11:49–11:51 UTC
(gitops [#72](https://github.com/Beyric/plateng-gitops/pull/72)) · Weysure-API #65 (`9df8ce6624d7`) promoted 11:46 UTC,
inside the same rollout · **Kind:** frontend release + gitops config flag + unannounced log-only API release · no migration ·
**Cost delta:** $0 · Builds on [wallet origins release](2026-10-10-wallet-origins-release-and-drift-alert.md)

**Status: live and verified; developers' smoke test passed ("flip checked").**

## What shipped

| Change | Where | Effect |
|---|---|---|
| Web #48 (PR 7c): wallet split Withdrawable / Spend only / On hold, Withdraw capped, `WITHDRAW_SPEND_ONLY` explained | `Weysure` → image `4b9e2223c440` | screens only; no env var |
| `ORIGIN_RULES_ENFORCED: "true"` | gitops `apps/api/values.yaml` `commonEnv` (api, api-scheduler, api-worker) | withdrawals limited to earned money; KYC limits on earned |
| `RISK_HOLDS_MODE: "off"`, `RISK_SIGNALS_CAPTURE_ENABLED: "false"`, `TRUSTED_PROXY_CIDRS: "10.0.0.0/16"` | same | none on this image; starting state for Weysure-API #64 and #66 |
| Weysure-API #65: email addresses out of logs (`user.email` → `user.id`, mail errors log the exception type) | image `9df8ce6624d7` | log text only |

## Why

The developers' note `weysure/docs/platform-note-2026-10-13-web-7c-origin-rules.md`: the flag must go on the **same day** as
7c, because in between the Top up dialog tells card-funded users the money cannot be withdrawn while the API still allows it.
#65 is the log-PII follow-up we asked for on 2026-10-12.

## How (key decisions)

- **Order, one at a time:** #48 → developers check → drift check → flag → developers' smoke test. Our reply:
  `weysure/docs/platform-reply-2026-10-13-web-48-and-api-64.md`.
- **Drift evidence from silence, proven first.** The reconciler logs nothing on a clean run, so "no drift" and "not running"
  look alike. Code read (`app/main.py`: each run in try/except; mismatch = WARNING, failure = ERROR; first run at startup),
  plus the paired `scheduler started` lines, showed the loop alive: 24 h with 0 `wallet_lot_drift`, 0 mismatches, 0 errors.
- **The flag is read only per request** (`wallet.py` withdrawal path, `kyc_limits.py`): no startup action, safe to roll.
- **Inert settings in the same ConfigMap change:** one restart instead of three; they record the starting state in git.
- **Render test** asserts all four values on all three ConfigMaps and that `enforce` never appears without origin rules.

## The release, as it happened (UTC)

| Time | Event |
|---|---|
| 11:11:47 | web #48 merged |
| 11:21:59 | `4b9e2223c440` promoted (gitops `2bd8e6c`); both web pods on it by 11:25, on two nodes (ADR-024) |
| ~11:27 | Argo `root` briefly OutOfSync (had not polled `2bd8e6c`); synced by itself; live `kyverno` spec identical to git |
| 11:26:01 | **Weysure-API #65 merged with no note to platform** |
| 11:42 | gitops #72 merged |
| 11:46:06 | `9df8ce6624d7` (#65) promoted (gitops `b8254ca`) |
| 11:49:08 | the three ConfigMaps show `true`; Reloader + new image roll api ×2, scheduler, worker 11:49–11:51 |
| ~12:00 | developers: "flip checked" (card top-up → Spend only, Withdraw disabled; earned deal → Withdrawable = Earned) |

## Verification

- Web: both pods `4b9e2223c440`, Ready, 0 restarts; sites 200; 0 error lines (web, api) in 15 min; 32/32 Argo.
- Flag: ConfigMaps `true`; api ×2 (`ip-10-0-4-52`, `ip-10-0-4-17`), scheduler, worker on `9df8ce6624d7`, 0 restarts;
  0 API error lines in 10 min after; 32/32 Synced/Healthy; sites 200.
- #65 diff reviewed after the fact (log text only).

## What went wrong (process)

**#65 deployed inside our flag rollout**: image and flag changed in the same pod restart, so a fault could not have been
attributed. Harmless this time (log text). Fourth unannounced developer merge (after wallet origins, gitops #67, Weysure-API #60).
Raised in `platform-reply-2026-10-13-origin-rules-on.md`. Structural fix (deploy hold / branch protection) is a follow-up.

## Roll back

- Flag: revert gitops #72 (~5 min: Argo + Reloader). Web needs nothing. **Do not revert web #48 while the flag is on.**
- #65: image revert is possible (no migration), but pointless; it only changes log text.

## Follow-ups

- **"Reconciliation stopped" alert was due before this flag (checklist Deferred); not done.** It needs a positive per-run log
  line to alert on its absence; asked the developers for `wallet reconciliation: N users, 0 mismatches` per run.
- Double reconciliation scheduler (one per gunicorn worker, `WEB_CONCURRENCY=2`): raised again with the developers.
- SonarQube `-pr` project: "new code" is measured against the previous PR's analysis, so the same commit can fail then pass
  (Weysure-API #64: PR-64 #1 FAILED, #2 PASSED on `5a92c33`; the "unnecessary `list()`" issue at `app/services/wallet_origins.py:167` stayed open). Read the issues, not
  the gate colour, until each PR is compared with `main`.
- Deploy hold during platform rollouts (developers merged #65 mid-change).
