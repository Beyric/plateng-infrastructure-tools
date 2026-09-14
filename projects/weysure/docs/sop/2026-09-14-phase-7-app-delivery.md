# SOP — Phase 7: Application delivery

**Shipped:** 2026-09-13 · **PRs:** infra #18 (spec) · gitops #14–#25 · Weysure-API #11 (entrypoint),
#12 (developer baseline migration), #13 (coverage) · **Cost delta:** ~+$12/mo (one spot node for the apps)

## What shipped

A `beyric-ci[bot]` commit to `projects/weysure/environments/prod/images.yaml` is now a production
deployment. Both hosts serve with valid TLS:

```
images.yaml commit ─▶ Argo CD (≤3 min) ─▶ PreSync Job: alembic upgrade head (Vault: weysure-migrate user)
                                      └▶ api ×2 + api-scheduler ×1 (Vault Agent sidecar) · web ×2
                                      └▶ Service · Ingress (Traefik + cert-manager) · PDB · HPA
```

| Piece | Where | Notes |
|---|---|---|
| Library chart `beyric-app` | gitops `charts/beyric-app/` | one template set; each app is a values file; `tests/render-test.sh` = 30+ assertions on the real prod render |
| App values | gitops `projects/weysure/environments/prod/apps/{api,web}/values.yaml` | image tag read from `images.yaml` via `imageTagKey` |
| Argo apps `weysure-api`, `weysure-web` | gitops `bootstrap/apps/` wave 9 | `valueFiles: [values.yaml, ../../images.yaml]` |
| Vault Agent injector | `platform/vault/values.yaml` | on, namespace-selected (`vault-injection=enabled`), port 8443, `failurePolicy: Ignore` |
| Vault roles/policies | CLI, recorded in `runbooks/VAULT_CONFIG.md` | `weysure-api` (SAs api, api-scheduler) → `weysure-db-app`; `weysure-migrate` (SA db-migrate) → `weysure-db-migrate`; audience `https://kubernetes.default.svc` |
| Postgres role layout | gitops `bootstrap/db-grants-v2-job.yaml` (one-shot Job) | NOLOGIN groups `weysure_owner` (owns tables) and `weysure_app` (DML); ephemeral users join a group and own nothing |
| Entrypoint | Weysure-API `boot/docker-run.sh` | sources `$VAULT_ENV_FILE`; `RUN_MIGRATIONS=false` in Kubernetes |
| Secrets | Vault `secret/weysure/prod` (15 keys) → ESO → Secret `weysure-app-config` → `envFrom` | Reloader restarts on change |

Namespace is `weysure-prod` (spec said `weysure`; Redis and the Phase 5 Job already lived there).
Ingress is a plain `Ingress` + cert-manager annotation, as everywhere else — not IngressRoute.

## How the first deployment was reached — eleven loops

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Job pod refused: `service account db-migrate not found` | PreSync hooks run before every ordinary resource | ServiceAccount is a PreSync hook at wave -1 (#16) |
| 2 | `secret weysure-app-config not found` | same rule, ExternalSecret was ordinary | ExternalSecret is a PreSync hook at wave -2 (#17) |
| 3 | No agent container; injector logged nothing | injector listened on 8080; control plane can reach nodes only on 443/4443/6443/8443/9443/10250/10251 | `injector.port: 8443` (#18) |
| 4 | Webhook denied: `RunAsUser is nil for Container 0` | `agent-run-as-same-user` reads the *container* runAsUser | chart copies runAsUser/Group onto containers (#19) |
| 5 | Vault: `permission denied to grant role "vault"` | PostgreSQL 16 removed a role's implicit ADMIN OPTION on itself; Phase 5 role used `IN ROLE vault` | group-role layout (#20) |
| 6 | New Job never ran; roles reverted to Phase 5 SQL | hook-only change doesn't make an app OutOfSync; `db-bootstrap` hook re-ran on every sync | Jobs are plain immutable resources, `db-bootstrap` retired (#21) |
| 7 | alembic: `permission denied for schema public`; Job log `WARNING: no privileges were granted` | grants issued as `vault`, but master owns the database on RDS | grants run as master after `RESET ROLE` (#22) |
| 8 | alembic: `relation "users" does not exist` | no revision in 47 ever created `users` (pre-Alembic table) | developer baseline migration (Weysure-API #12); platform bootstrap (#23) withdrawn |
| 9 | Sonar quality gate failed on the baseline | generated migration flagged; coverage 0 % | pytest-cov + exclusions for `alembic/` (Weysure-API #13) |
| 10 | api CrashLoop: `Read-only file system: /app/logs` | loguru file sink at import | emptyDir `/app/logs` (#24) |
| 11 | api CrashLoop: `Read-only file system: uploads` | KYC uploads written to local disk | emptyDir `/app/uploads` (#25) + **high** developer follow-up |

Method every time: read the log to the failing line → reproduce locally (Postgres 16 in Docker,
non-superuser master; the developers' own venv) → fix → prove → push.

## Findings

**㉛ — EKS reaches admission webhooks only on the ports the eks module opens.** 443, 4443, 6443,
8443, 9443, 10250, 10251. A webhook on any other port fails silently under `failurePolicy: Ignore`.
The tell is an empty webhook log.

**㉜ — PostgreSQL 16 changed role-membership rules.** A role no longer holds ADMIN OPTION on itself;
`CREATE ROLE x IN ROLE vault` executed *as* `vault` fails. Correct shape: NOLOGIN group roles created
*by* `vault` (creator gets ADMIN via `createrole_self_grant`), ephemeral users join a group and own
nothing; migrate users `SET role` into the owner group so tables belong to the group.

**㉝ — Argo hooks are a phase, not a wave.** Everything a PreSync Job consumes must itself be a
PreSync hook. A hook-only change never makes an app OutOfSync. A hook with `HookSucceeded` is
re-created — and re-run — on every sync: `db-bootstrap` had been rotating Vault's DB password and
rewriting roles on every sync since Phase 5. One-shot work is a plain immutable Job, no TTL.

**㉞ — `GRANT` by a non-owner is a warning, not an error.** `no privileges were granted` sails past
`ON_ERROR_STOP`. Read Job logs for `WARNING:` lines. On RDS the master user, not `vault`, owns
`weysure` — Phase 5's `CREATE DATABASE … OWNER vault` did not take effect as assumed.

**㉟ — The API's Alembic history never created its first table.** `users` predates Alembic; every
dev machine and Supabase already had it. The first from-empty environment exposed it. Developer
fixed with a baseline migration; the chain also has three roots (autogenerate from stale checkouts).

**㊱ — `readOnlyRootFilesystem` found two hidden disk writes at first boot.** loguru's file sink and
KYC uploads. Every writable path is now an explicit `writableDirs` entry. KYC documents on a
per-pod emptyDir are ephemeral and unshared — object storage is a **high** developer follow-up.

Also: Cloudflare's bot protection returns 403 to the Python user-agent — external probes (Phase 9
Blackbox) need a browser-like UA or a WAF skip rule. Local `poetry run black` fell through to a
Homebrew 26.x binary because the venv lacked `black` — always confirm the tool comes from the venv.

## Deferred — stated plainly

- Staging environment (Adebayo, 2026-09-09).
- Zero-downtime rollout measured across a real deploy (DoD 5/6): the single-pod deletion test passed
  (replacement `2/2` in <45 s) but the probe window may have missed it; measure on the next promote.
- 24-hour Vault credential rotation observed end to end (agent re-render → gunicorn restart).
- Paystack webhook URL configured in the Paystack dashboard.
- Vault config into Terraform (ADR-021 follow-up); `external-secrets` auth role audience.
- Redis single replica evicted by Karpenter drift (15 s re-attach) — PDB or `do-not-disrupt` in Phase 8.

## Verification

`argocd app list` both Synced/Healthy · `kubectl -n weysure-prod get pods` api 2/2 ×2, scheduler 2/2,
web ×2 · migration Job `Completed`, 48 revisions to head `a1b2c3d4e5f6` · Vault agent log `renewed auth
token`, `rendered … /vault/secrets/env` · `curl https://weysure-api.beyrictech.com/api/v1/health` 200 ·
`https://weysure.beyrictech.com` 200 · `kubectl delete pod <api>` → replacement `2/2` in <45 s, other
replica untouched.

## Rollback

`git revert` the promote commit in plateng-gitops → Argo rolls the previous image (PreSync Job runs
`alembic upgrade head`, a no-op unless the schema changed — expand/contract rule for developers).
Whole-app removal: revert gitops #15; finalizers cascade every resource; namespace, Redis, Vault
config untouched. Runbook: [DEPLOYMENT_ROLLBACK.md](../runbooks/DEPLOYMENT_ROLLBACK.md).
