# SOP — Phase 5: Data layer

**Shipped:** 2026-09-03 · **PRs:** infra #8, #9 · gitops #6, #7 · **Cost delta:** ~+$15/mo

## What shipped

The application will never hold a database password. Vault mints a Postgres user on
request, valid for one hour, and drops it.

| Component | Delivered by | Verified |
|---|---|---|
| **RDS PostgreSQL 16.13**, `db.t4g.micro`, single-AZ, TLS forced | Terraform | `available`; `terraform plan` → `No changes` |
| **Master password** — RDS-managed, in Secrets Manager only | Terraform (ADR-010) | never in tfvars, state, or git |
| **Security group** — 5432 from the EKS node SG only | Terraform | not the VPC CIDR |
| **`vault` Postgres role + `weysure` database** | bootstrap Job, step 2 | Vault engine config succeeded against them |
| **Vault database engine**, `rotate-root` applied | bootstrap Job, step 3 | `database/config/weysure` allows `[weysure-app weysure-migrate]` |
| **Dynamic role `weysure-app`** — rows only, 1h TTL | bootstrap Job | **minted live:** `v-userpass-weysure--…`, lease 3600 |
| **Dynamic role `weysure-migrate`** — DDL, 30m TTL | bootstrap Job | defined; consumed by the Alembic PreSync hook in Phase 7 |
| **Redis** 8.2, StatefulSet, 2Gi gp3, `allkeys-lru` | Argo CD | `1/1`, PVC `Bound` |

## The bootstrap Job — why three containers and a memory volume

The RDS master password has to be used exactly once, to create the `vault` role. It is
fetched via **pod identity** into an `emptyDir` with `medium: Memory`, consumed by `psql`
over TLS, and deleted from the volume before the third container starts. The third container
hands the `vault` role to Vault and immediately runs `rotate-root`, after which that role's
password exists nowhere but inside Vault. The Job's own Vault policy is scoped to the
database engine alone — no `secret/*`, no `auth/*`.

The Job is an Argo CD **Sync hook** with `BeforeHookCreation,HookSucceeded`: a success is
cleaned up, a failure is left for inspection and replaced on the next sync. "No resources
found" after a sync is therefore the success signal — confirmed against Vault, not assumed.

## Findings

**㉒ — Kubernetes rewrites `$$` in container args.** The first run failed at
`DO $ BEGIN`. Kubernetes expands `$(VAR)` in `command`/`args`, and `$$` is its escape for a
literal `$`, so PostgreSQL's `$$` dollar-quoting reached psql as `$`. Fixed with the named
tag `$body$`. General rule: any shell or SQL embedded in a Pod spec must not contain `$$`.

**㉓ — `tfplan` was tracked in git since Phase 1.** `.gitignore` covered `*.tfstate*` and
`*.tfvars` but not plan files; `git add -A` swept it up in `097b6bf` and six commits since.
Inspected before deciding: every `password` occurrence is a sensitivity marker or a module
variable declaration, gitleaks reports no leaks, and `manage_master_user_password` means
Terraform never held the value. Untracked and ignored; no history rewrite, proportionate to
an absent exposure. A future plan *could* carry something real, which is why it matters.

**`rds.force_ssl` perpetual diff.** A static parameter in PostgreSQL 16; AWS records it
`pending-reboot` regardless of what is sent, so the module default `immediate` produced a
1-change plan that survived its own apply. Pinned to `pending-reboot` in config; converged.

**Finding ⑱ closed by the module.** `terraform-aws-modules/rds` names the final snapshot
`<prefix>-<identifier>-<random>` with its own `random_id`. My hand-rolled duplicate was
removed after the module rejected the argument.

**Bitnami not used for Redis.** Bitnami restricted free image pulls in 2025; charts pinned
to `docker.io/bitnami/*` commonly fail with `manifest unknown`. Fifty lines of StatefulSet
on the official image has no upstream licensing dependency.

## Deferred — stated plainly

| Item | Why | Where |
|---|---|---|
| **Alembic schema build** | `env.py` reads `settings.DATABASE_URL` from the app's settings module — needs a container image with the code. None exists until Phase 6. Also where Finding ⑨ said it belongs: a PreSync hook, not container start. | Phase 7 |
| **Restore drill from PITR** | Planned for this phase; **not performed.** A backup never restored is not a backup. Folded into the DR drill. | Phase 10 |
| Vault Kubernetes-auth roles have no `audience` | Vault 1.21 will require one; deferred rather than changed mid-debug | before the Vault upgrade |
| `db-bootstrap` pod identity remains | One-shot role; harmless but idle | Phase 10 cleanup |

## Verification

| Test | Result |
|---|---|
| RDS reachable only from nodes | SG source = node SG; `publicly_accessible = false` |
| Master password never seen | not in tfvars, state, git, or Job logs |
| Vault → Postgres after `rotate-root` | credential minted live, lease 3600s |
| Drift | `terraform plan` → `No changes` |
| Redis | `sts 1/1`, `pvc data-redis-0 Bound gp3` |

## Rollback

`terraform destroy -target=module.rds` is blocked by `deletion_protection`; that is
deliberate. Redis: delete the StatefulSet from gitops — cold cache, no data loss.
