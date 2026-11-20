# SOP — runbook: move Weysure from AWS to one plain VPS

**Shipped:** docs PR in plateng-infrastructure-tools (branch `docs/vps-migration-runbook`) — **open, not merged** · **Kind:** documentation + reference files, no cluster or AWS change · **Cost delta:** $0
Runbook: [VPS_MIGRATION.md](../runbooks/VPS_MIGRATION.md) · files: `runbooks/vps/` · proof log: [evidence/2026-11-20-vps-migration-proof.txt](../evidence/2026-11-20-vps-migration-proof.txt)
Builds on the nightly Drive backup ([SOP](2026-11-20-db-offsite-backup.md), gitops #108): merge or read it first, it is the data source.

**Status: written and partly proven on a laptop; never run on a real server.**

## Why

Adebayo wants to be able to leave AWS for a plain VPS at any time (2026-11-20), starting from the encrypted nightly dump on Google Drive.

## How, and the decisions

| Decision | Choice | Rejected / why |
|---|---|---|
| Layout | Docker Compose on one VPS: Caddy, api, worker, web, Postgres 16, Redis | Kubernetes on a VPS (k3s): far more to run for one small app; a managed Postgres is allowed but not assumed |
| TLS / edge | Caddy with automatic Let's Encrypt, DNS **only** (Cloudflare proxy off) | Cloudflare proxy on: needs the client-IP header left alone and ports limited to Cloudflare's ranges (the API trusts `CF-Connecting-IP` from a trusted peer); listed as not written |
| Client address | Caddy at fixed `172.28.0.10` on the `edge` network, IPv4-only published ports (no AAAA records: Docker's IPv6 proxy hides the client), `TRUSTED_PROXY_CIDRS=172.28.0.10/32`, Caddy overwrites `CF-Connecting-IP` with the real peer | trusting the whole network, or leaving the header: a caller could choose its own rate-limit bucket |
| Database restore | `pg_restore --no-owner --no-privileges` into the compose `db`, owner `weysure`; decrypt on the Mac and stream over SSH | putting the age private key on the server (it must never be there) |
| Images | out of ECR via the Mac (`docker save`), or rebuild; web needs the `NEXT_PUBLIC_*` build args | an AWS login on the VPS |
| Domains | keep them: then no webhook URL, CORS, cookie or passkey change | changing domain at the same time (passkeys break; separate step) |
| Networks | `edge` (caddy, web, api, worker) + `backend` (`internal: true`: api, worker, db, redis); no Redis password | one flat network; a Redis password (only api/worker can reach it; revisit if other containers share the host) |
| Cutover order | freeze AWS, final dump, restore, start everything but Caddy, flip DNS, then start Caddy | flipping DNS first (certificate has nothing to answer; more downtime) |
| Backups on the VPS | `backup.sh`: same recipe as the CronJob (age, Drive, verify, 30 daily + 12 monthly, optional ping) | none was the starting point |

## What's involved

| Path (`projects/weysure/docs/`) | What |
|---|---|
| `runbooks/VPS_MIGRATION.md` | the runbook (what moves, settings names, images, compose gaps, server build, rehearsal, cutover, backups, rollback, proof) |
| `runbooks/vps/docker-compose.yaml` | production compose file (digest-pinned db, redis, caddy) |
| `runbooks/vps/Caddyfile` | routing + TLS + client-address rule |
| `runbooks/vps/env.example` | names and example shapes only; values come from Vault and the gitops values |
| `runbooks/vps/backup.sh` | nightly encrypted off-server backup for the VPS |
| `evidence/2026-11-20-vps-migration-proof.txt` | proof log |

Read for the runbook (no values copied): `Weysure-API/app/core/config.py`, `.env.example`, `docker-compose.yaml`, `Dockerfile`, `boot/docker-run.sh`, `app/core/client_ip.py`, `Weysure/Dockerfile`, `Weysure/Jenkinsfile`, gitops `apps/api/values.yaml`, `images.yaml`.

## Verification

| Check | Result |
|---|---|
| Dump → age → decrypt → restore into the compose `db` service: 13/13 checks identical | proven locally |
| `backup.sh` unmodified: upload, verify, monthly keeper, retention, restore of its output 13/13 identical, two failure cases | proven locally |
| `docker compose config`, `caddy validate`, `shellcheck` | pass |
| Full stack, certificates, DNS, firewall, ECR copy, real Drive, provider dashboards, sizing, rollback after real writes | **not proven** |

## Operate / roll back

Docs only: revert the PR. The runbook carries its own cutover rollback table.

## Follow-ups

- [ ] Rehearse on a real VPS and fix whatever it finds (this is the real test).
- [ ] Decide the image store for releases after ECR (GitHub registry or `docker save` files) and how releases are built without Jenkins.
- [ ] Replacement for the Loki/Prometheus money alerts (wallet drift, withdrawals stuck, auto-pause): a small log watcher, before leaving the cluster.
- [ ] Write the "Cloudflare proxy on" variant and the reverse (VPS → RDS) rollback if you want them.
- [ ] Export plan for Cloudinary (the only copy of uploaded documents).
