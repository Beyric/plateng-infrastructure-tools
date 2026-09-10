# Phase 7 implementation plan — application delivery

Spec: [2026-09-10-phase-7-app-delivery.md](../specs/2026-09-10-phase-7-app-delivery.md).
Command split per `docs/conventions/HUMAN_GATED_COMMANDS.md`: Adebayo runs `vault`, `kubectl`,
`argocd`; I write manifests/charts, open PRs, and verify read-only.

Fact found while planning: Vault's Kubernetes auth roles and DB roles from Phase 5 were created
imperatively (CLI), not from git — `platform/vault/` holds only chart values, and the chart's
**injector is disabled**. Phase 7 keeps the imperative pattern for Vault config (fast-track,
recorded in `runbooks/VAULT_CONFIG.md`) and adds ADR-021: move Vault config to the Terraform
`vault` provider as a follow-up.

| # | Task | Repo / files | Owner | Depends on |
|---|---|---|---|---|
| 1 | Write prod app secrets to `kv secret/weysure/prod` (JSON via stdin) | Vault | Adebayo | — |
| 2 | Enable Vault Agent injector (`injector.enabled: true`, system nodes, small requests) | gitops `platform/vault/values.yaml` | me → PR | — |
| 3 | Vault policies `weysure-db-app`, `weysure-db-migrate`; K8s auth roles `weysure-api`, `weysure-migrate`; extend `weysure-read` for ESO to `secret/data/weysure/prod`; pin DB password policy | Vault CLI (commands in PR) + `runbooks/VAULT_CONFIG.md` | me writes, Adebayo runs | — |
| 4 | Library chart `charts/beyric-app` (Deployment, Service, IngressRoute, PDB, HPA, ConfigMap, ServiceAccount, migrate Job hook, agent annotations) + `helm lint`/`helm template` golden test | gitops | me → PR | — |
| 5 | `weysure-secrets` app: namespace, ExternalSecret `weysure-app-config` | gitops `projects/weysure/environments/prod/secrets/`, `bootstrap/apps/weysure-secrets.yaml` (wave 8) | me → PR | 1, 3 |
| 6 | `Weysure-API` entrypoint: source `/vault/secrets/env`; `RUN_MIGRATIONS` gate | `boot/docker-run.sh` | me → PR to developers' repo | — |
| 7 | `api` + `api-scheduler` values, `web` values; Argo apps `weysure-api`, `weysure-web` (wave 9) reading `images.yaml` as second values file | gitops | me → PR | 4, 5, 6 merged & built |
| 8 | Sync + verify: definition of done §8 in the spec | cluster | Adebayo runs, I read | 7 |
| 9 | SOP, checklist, runbooks `DEPLOY_ROLLBACK.md`, `VAULT_CONFIG.md`, ADR-021, Findings | infra docs | me → PR | 8 |

Parallel lanes: 1 ‖ 2 ‖ 3 ‖ 4 ‖ 6. Task 7 is the integration point.

## Rollback per task
- 2: revert values PR — injector Deployment removed, nothing depends on it yet.
- 3: `vault policy delete`, `vault delete auth/kubernetes/role/<r>` — commands in the runbook.
- 5/7: delete the Argo Application manifest (finalizer cascades the namespace resources) or `git revert`.
- 6: image tag before the change stays in ECR; revert the promote commit.

## Risks
- Rendered `DATABASE_URL` with an unsafe character → pinned password policy (task 3), tested by `vault read database/creds/weysure-app` once.
- Injector webhook adds a mutating admission call on every pod create in the cluster: `failurePolicy: Ignore` default, namespace-selector limited to `weysure` — pods elsewhere unaffected.
- Migration Job runs with the *new* image against the *old* pods: expand/contract rule documented for developers.
