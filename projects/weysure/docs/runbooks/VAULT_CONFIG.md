# Runbook — Vault configuration (imperative, recorded)

Vault's auth roles, policies and database roles are created with the CLI (Phase 5/7), not from
git — moving them to the Terraform `vault` provider is a follow-up (ADR-021). This file is the
record. Log in first: `kubectl exec -n vault -it vault-0 -- vault login -method=userpass username=adebayo`.

| Object | Definition |
|---|---|
| policy `weysure-read` | read `secret/data/weysure/*`, list `secret/metadata/weysure/*` (ESO) |
| policy `platform-read` | read `secret/data/platform/*` (ESO) |
| policy `weysure-db-app` | read `database/creds/weysure-app`; update `sys/leases/renew` |
| policy `weysure-db-migrate` | read `database/creds/weysure-migrate` |
| policy `db-bootstrap` | manage `database/config/weysure`, `database/roles/*` (one-shot Jobs) |
| k8s role `external-secrets` | SA `external-secrets/external-secrets` → `platform-read`, `weysure-read` (no audience yet) |
| k8s role `weysure-api` | SAs `weysure-prod/{api,api-scheduler}` → `weysure-db-app`; ttl 1h, max 24h; audience `https://kubernetes.default.svc` |
| k8s role `weysure-migrate` | SA `weysure-prod/db-migrate` → `weysure-db-migrate`; ttl 30m, max 1h; same audience |
| k8s role `db-bootstrap` | SA `weysure-prod/db-bootstrap` → `db-bootstrap` |
| policy `vault-snapshot` | read `sys/storage/raft/snapshot` - nothing else (2026-09-28) |
| k8s role `vault-snapshot` | SA `vault/vault-snapshot` → `vault-snapshot`; ttl 15m; audience `https://kubernetes.default.svc` |
| db config `weysure` | postgres plugin, user `vault` (password rotated, known only to Vault), allowed roles below |
| db role `weysure-app` | `CREATE ROLE "{{name}}" … IN ROLE weysure_app`; ttl 1h, max 24h; revoke `DROP ROLE` |
| db role `weysure-migrate` | `… IN ROLE weysure_owner; ALTER ROLE "{{name}}" SET role = 'weysure_owner'`; ttl 30m, max 1h |
| kv `secret/platform/healthchecks` | `api_key` - read-write project key, read by `scripts/platform-sleep.sh` only (not synced into the cluster) |
| kv `secret/weysure/prod` | 15 application keys (names in the Phase 7 SOP) |

Postgres groups `weysure_owner` / `weysure_app` were created by gitops `db-grants-v2` (as master,
`SET ROLE vault`, `createrole_self_grant = 'set, inherit'`).

Read-only checks: `vault policy list` · `vault list auth/kubernetes/role` · `vault read
database/roles/weysure-app` · `vault read -field=username database/creds/weysure-app` (mints a user).
