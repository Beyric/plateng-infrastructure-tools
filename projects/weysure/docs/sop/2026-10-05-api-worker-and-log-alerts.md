# SOP — api-worker (background jobs) and log-based alerts

**Shipped:** 2026-10-04 → 2026-10-05 · **PRs:** gitops #59 (prepare, off), #60 (Loki ruler), #61 (switch on),
#62 (restart-pattern fix), #63 (`replicas: 0`) · infra #47, #48, #49, #50 (`db-oneoff.sh`, rollback runbook) · app: Weysure-API #43 (`710208c2c6d4`) ·
**Cost delta:** ≈ $0 (120m CPU / 288Mi requested on existing nodes) ·
Developer notes: `weysure/docs/platform-note-2026-10-03b.md`, `platform-note-2026-10-04.md`; reply
`platform-reply-2026-10-04.md` · Runbooks: [ALERTS](../runbooks/ALERTS.md), [SLEEP_WAKE](../runbooks/SLEEP_WAKE.md),
[VAULT_CONFIG](../runbooks/VAULT_CONFIG.md)

**Status: shipped and verified in production.** Worker running since 2026-10-05 10:43 UTC; fixed pod
`api-worker-6f9bd4457b-*` 0 restarts; one `jobs_stats` line a minute; three Loki rules `inactive | ok`.

## What shipped

| Piece | Where | Proof |
|---|---|---|
| **`api-worker` Deployment** — same image as api, `python -m app.worker`, 1 replica, own SA, Vault DB role `weysure-api`, same ConfigMap values + `weysure-app-config`, 100m/256Mi req, 512Mi limit, 60 s grace | gitops `projects/weysure/environments/prod/apps/api/values.yaml` (#59, #61) | 2/2 Running, DB queries every minute |
| **Chart: exec probes** for port-less components (startup + liveness, no readiness); **per-component Vault restart command**; no preStop sleep without a port | gitops `charts/beyric-app/templates/deployment.yaml`, `_helpers.tpl` (#59) | existing renders byte-identical; render test 11 worker assertions |
| **Heartbeat liveness** — `/tmp/worker-heartbeat` younger than 45 s | values `probes.exec` | 10 s old in prod |
| **Vault binding** — `api-worker` added to `auth/kubernetes/role/weysure-api` | Vault, by hand (Adebayo, 2026-10-04) | read before/after: only `bound_service_account_names` changed |
| **NetworkPolicy** — api-worker in `api-egress` and `redis-ingress-from-api` | gitops `network/allow.yaml` (#59) | live selectors include it |
| **Loki ruler** — rules from `/rules` (chart sidecar `loki-sc-rules`, already running), alerts to `kps-alertmanager` | gitops `bootstrap/apps/loki.yaml` (#60) | live config; sidecar log `placing the loki-rules-jobs in: /rules/fake` |
| **Log-based alerts** `JobsQueueLagging` (warning), `JobsDeadIncreased` (critical), `JobsStatsMissing` (warning) | gitops `platform/monitoring/loki-rules-jobs.yaml` (#60, #61) | all three `inactive \| ok` in prod |
| **End-to-end rule test** — real Loki 3.6.11 + Alertmanager in Docker, 5 scenarios | gitops `platform/monitoring/tests/loki-rules-test.sh` | all PASS |
| `DeploymentReplicasMissing` covers api-worker | gitops `platform/monitoring/alerts.yaml` (#59) | promtool OK |
| **Sleep** scales api-worker to 0 with the other app Deployments | infra `scripts/platform-sleep.sh` (#48) | bash dry-run on the live cluster |
| **`scripts/db-oneoff.sh`** — one SQL statement (`read` in a read-only transaction / `write`) or one alembic command as a Job with the migration's identity, rendered from the chart | infra `scripts/` (#50) | real API image vs Postgres 16: read refuses `UPDATE`, write commits, alembic builds the schema; server dry run accepted by Kyverno |
| **Chart: `replicas: 0` renders 0** (was 1: `default` treats 0 as unset) — the worker is stopped in git during a rollback | gitops #63 | render test fails without the fix |

## Why

The developers moved timed escrow rules (auto-release, deadlines, expiries, dispute escalation) from
in-process timers to a Postgres `jobs` table polled with `FOR UPDATE SKIP LOCKED`, run by a separate worker.
Redis stays a wake-up signal only (`allkeys-lru` is a cache). The platform had to run it, give it database
access, and alert when the queue is late or a job gives up.

## How — decisions and the problems found

| Decision | Why | Rejected |
|---|---|---|
| Worker wrapper in the chart: wait for `$VAULT_ENV_FILE`, export it, `exec python -m app.worker` | The image has no ENTRYPOINT; `CMD /opt/run.sh` loads the credential and then **always starts gunicorn**, so `command:` skips the credential step | a worker mode in `run.sh` (developers' image; not needed) |
| Own restart command for the Vault agent | api's `[b]in/gunicorn` never matches the worker: after max TTL (≤ 24 h) it would run on a revoked credential | — |
| Ship disabled (#59), switch on separately (#61) | api and worker share the image tag; on before `app.worker` existed → `No module named app.worker` | one PR timed to the app merge |
| Alerts from logs, not the admin endpoint | Prometheus would need an admin credential for `/admin/jobs/stats` | scraping with a stored admin token |
| Loki ruler | made for this; Slack routing unchanged; reusable for other log alerts | Alloy `stage.metrics` → Prometheus: one gauge per Alloy pod, stale series when the worker moves node |
| `JobsDeadIncreased` = latest `dead` > max of the previous 10 min, `max()` across pods | `dead` only falls when a person acts, so `dead > 0` would fire for ever; a replaced pod is a new series | `dead > 0`; first/last within one series |

**Bugs found on the way (all before or within minutes of production):**

1. **Rule that could never fire.** A plain `| json` turns every field and the whole line into labels, so each
   distinct line is its own series and "first vs last" compares a value with itself. Caught by the Docker test;
   fixed by `| drop stats` and extracting only the needed field.
2. **One restart on every new worker pod** (exit 143 at 10:43:11). The Vault agent runs its inject command on its
   **first** render too, while the wrapper is still waiting; the wrapper's command line contains `app.worker`.
   The #59 Docker test missed it because there the wrapper was **PID 1**, which ignores a default SIGTERM; in the
   pod the pause container is PID 1. Fixed with `^python -m app[.]worker` (#62); reproduced and verified with
   `docker run --init`.

## What's involved

- gitops: `charts/beyric-app/{templates/deployment.yaml,templates/_helpers.tpl,values.yaml,tests/render-test.sh}`,
  `projects/weysure/environments/prod/apps/api/values.yaml` (`api-worker`), `projects/weysure/environments/prod/network/allow.yaml`,
  `bootstrap/apps/loki.yaml` (`rulerConfig`), `platform/monitoring/{alerts.yaml,loki-rules-jobs.yaml,tests/loki-rules-test.sh}`
- infra: `scripts/platform-sleep.sh` (step 6), runbooks `ALERTS.md`, `SLEEP_WAKE.md`, `VAULT_CONFIG.md`
- Vault: `auth/kubernetes/role/weysure-api` → SAs `api, api-scheduler, api-worker`
- App contract (Weysure-API #43): `app/worker/__main__.py`; heartbeat thread every 10 s, stops after 300 s without
  progress; SIGTERM finishes the running job, unstarted claims go back; every job ≤ 45 s; stats line
  `json.dumps({"event": "jobs_stats", "pending", "oldest_overdue_pending_seconds", "dead"})` once a minute;
  migration `9b2e7c4d1a30` (jobs table) runs in the PreSync Job. Payouts: deterministic Paystack `reference`
  from the escrow, verified before every send (Weysure-API #40).

## Verification

| Check | Result |
|---|---|
| Existing renders with the worker off | byte-identical to main (#59) |
| Wrapper: late Vault file / missing file | starts with `DATABASE_URL` / exits 1 after 60 s |
| Heartbeat probe: fresh, 30 s, 60 s, missing | pass, pass, fail, fail (in the real API image) |
| Agent `pkill` as uid 1000 in a shared PID namespace | worker SIGTERM → exit 0; api's pattern leaves it alone |
| Anchored pattern with an init at PID 1 | old: wrapper killed (exit 143); new: untouched, rotation still works |
| Loki rules test | lag fires · steady silent · dead 0→1 fires · pod change fires · silent → `JobsStatsMissing` pending · Alertmanager gets both severities |
| Prod after #62 | 0 restarts, stats every 60 s, heartbeat 10 s, rules `inactive \| ok`, api/web untouched, sites 200 |

## Operate / roll back

- Logs: `kubectl -n weysure-prod logs deploy/api-worker -c api-worker --tail=20`. Queue numbers for people:
  `GET /api/v1/admin/jobs/stats` (admin auth).
- More throughput: raise `replicas` (safe: `SKIP LOCKED`, no leader election).
- Off: `replicas: 0` (keeps the objects) or `enabled: false` in values. Jobs wait in the table; nothing is lost.
  Not `kubectl scale`: the next sync re-applies git.
- **Rolling back a release that added a migration:** downgrade with the NEW image first (`db-oneoff.sh <new-tag> alembic "downgrade <rev>"`), then revert the image. The other order fails at PreSync: the old image cannot locate the newer revision (proven). [DEPLOYMENT_ROLLBACK.md](../runbooks/DEPLOYMENT_ROLLBACK.md).
- Re-run the rule test after any change to `loki-rules-jobs.yaml`: `bash platform/monitoring/tests/loki-rules-test.sh` (~4 min).
- Sleep stops the worker before RDS; wake restores `replicas: 1` from git.

## Follow-ups

- Money-moving job types (later Weysure-API PRs): announced before each merge; confirm each stays ≤ 45 s.
- Outbound merchant webhooks on the jobs table: widen `api-egress`'s blocked list to all private, link-local and
  CGNAT ranges in the same release (app does the SSRF guard).
- `KubeCPUOvercommit` fires because Karpenter packs nodes (requests 5165m > allocatable minus largest node 3860m);
  not caused by the worker. Decision pending: disable it (and `KubeMemoryOvercommit`) or accept it.
- Kaniko cache repo split (ECR, ~$0.50/mo) — not worth doing now; see COST_CONTROLS.md.
