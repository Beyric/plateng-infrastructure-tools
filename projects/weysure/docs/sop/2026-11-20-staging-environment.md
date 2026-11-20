# SOP — staging environment (`weysure-stage`)

**Status: prepared, NOT applied.** Nothing below exists in AWS, Vault, Cloudflare or the cluster until Adebayo runs the steps in
[`runbooks/STAGING_ENVIRONMENT.md`](../runbooks/STAGING_ENVIRONMENT.md). PRs: plateng-infrastructure-tools `feature/staging-rds` (Terraform, runbook, this SOP),
plateng-gitops `feature/staging-environment` (stage manifests, Argo applications, chart, Kyverno), Weysure-API and Weysure `ci/promote-to-stage-first` (Jenkinsfiles).
**Kind:** infra + gitops + CI · **Cost delta:** ≈ +$16–17/mo (table in the runbook).

## Why

Prod is about to hold live provider keys and real money. Until now a merge to `main` was a production deploy with no place to look at it first.
Stage is a second copy that every change reaches first, on test keys, so a bad migration, a boot-guard refusal or a broken screen shows up where it costs nothing.

## How (decisions and what was rejected)

| Decision | Why | Rejected |
|---|---|---|
| Same cluster, namespace `weysure-stage`, one replica each | Capacity read from the cluster: stage requests 0.56 vCPU / 1.25 GiB against about 1.3 vCPU / 1.6 GiB and 2.5 vCPU / 3.2 GiB free on the two workload nodes. No new node | A second cluster (≥ $150/mo of control plane and nodes) |
| Second RDS instance, same size and settings as prod | A migration, reset or runaway query on stage cannot touch the prod database | A second database on the prod instance |
| Same chart, stage values copied from prod; a render test asserts stage config equals prod's except six host keys | "Stage rehearses what prod runs" stays true as flags change; verified: prod's rendered ConfigMap equals the live one | A hand-maintained copy |
| `ENVIRONMENT=staging` | The API treats it as a real deployment (no fake providers) yet refuses a live wallet key at boot and allows the Dojah sandbox | `development`/`test` (fake providers, rate limits off) |
| ExternalSecret with an explicit key list (chart `externalSecret.keys`) | A live Paystack key cannot reach stage pods even if written to `weysure/stage`; the default `extract` would pass any key | `dataFrom.extract` as in prod |
| Access control in Cloudflare (WAF rule on the two hosts), not in Traefik | Traefik's access log shows only the NLB's private addresses (10.0.1.x / 10.0.2.x): the NLB does not preserve the client IP and Traefik trusts `X-Forwarded-For` only from Cloudflare ranges. An IP allow-list in the cluster would block everyone | Traefik `ipAllowList` (built, then dropped after reading the logs); Cloudflare Access with the `access-verify` middleware (needs per-app tags in `edge-auth` and CORS settings for the API) |
| A separate web image per commit, `<sha12>-stage` | `NEXT_PUBLIC_API_URL` is baked in at build time; the prod image on stage would call `api.weysure.com` | One image for both (stage would hit the production API) |
| One consolidated one-shot bootstrap Job (`db-bootstrap-v1`), plain Job, non-root | Prod needed three jobs over its history; stage starts empty. Kyverno is `Enforce` in stage too, so the Job must pass the baseline | Copying prod's retired hook Job (re-ran on every sync) |
| Promote writes stage, then prod, in one push; `PROMOTE_TO_PROD` switch (`auto` today) | Keeps prod behaviour; flipping to `manual` is one word and makes stage a real gate | Making prod manual now (a policy change for Adebayo) |

## What's involved

| Where | What |
|---|---|
| `projects/weysure/terraform/rds-stage.tf` | SG, `module.rds_stage` (encrypted, 7-day backups, single-AZ, deletion protection, TLS forced, managed master password, own subnet/parameter group, maintenance window the day before prod's), IAM role + pod identity for `weysure-stage/db-bootstrap` (reads only the stage master secret) — plan: 8 to add, 0 to change, 0 to destroy |
| `scripts/db-oneoff.sh` | `TARGET=stage` runs the same one-off Job against stage; default unchanged (prod) |
| gitops `projects/weysure/environments/stage/` | namespace, quota, network policies (prod's, namespace swapped, plus Vault egress for the bootstrap Job), Redis, `images.yaml`, bootstrap Job, noindex Middleware, api/web values |
| gitops `bootstrap/apps/weysure-stage.yaml`, `weysure-api-stage.yaml`, `weysure-web-stage.yaml` | the three Argo CD Applications (auto-sync, no self-heal, as prod) |
| gitops `stage-maintenance/db-reset-job.yaml` | the reset Job, outside the synced path, run by hand |
| gitops `charts/beyric-app` | optional `ingress.annotations` and `externalSecret.keys`; prod's render is byte-identical before and after |
| gitops `platform/kyverno/*` | `weysure-stage` added to the `Enforce` namespaces |
| Weysure-API / Weysure `Jenkinsfile` | Promote: stage then prod, `PROMOTE_TO_PROD`; web: second build `-stage`, both scanned |

## Verification

| Check | Result |
|---|---|
| `terraform fmt -check`, `terraform validate` | clean |
| `terraform plan` (read-only, no lock, against the real state) | 8 to add, 0 to change, 0 to destroy; no prod resource touched |
| `helm lint` + `charts/beyric-app/tests/render-test.sh` (prod and stage) | pass; negative test: a planted `PAYSTACK_LIVE_SECRET_KEY` or a prod host in stage fails it |
| Prod chart render before vs after the chart change | byte-identical (api and web) |
| Rendered prod ConfigMap vs the live `api-config` | no differences (stage's flags are therefore prod's live flags) |
| Stage vs prod ConfigMap | differ only in `ENVIRONMENT`, `SERVER_HOST`, `FRONTEND_URL`, `BACKEND_CORS_ORIGINS`, `WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGINS` |
| Raw manifests | `kubectl apply --dry-run=client` accepts them; Kyverno baseline read against the Job by hand (no Kyverno CLI here) |
| Jenkins Promote script, extracted and run against a local fake gitops repo | stage then prod in one push; rerun is a no-op; `manual` leaves prod; missing stage file skipped; push-race retry works |
| Secret-seed filter (`jq`) on dummy data | live keys dropped, Paystack slots become the test pair, aborts without a test key |
| **Not verified (needs the apply)** | the Terraform apply itself; Vault roles and the bootstrap Job end to end; ESO sync of `weysure/stage`; certificates; the Cloudflare rule; Argo sync of the new Applications; the web `-stage` build and Groovy of the two Jenkinsfiles (no Jenkins to run them; brace balance and the shell were checked); Kyverno admission of the Job |

## Operate / roll back

Runbook: [`runbooks/STAGING_ENVIRONMENT.md`](../runbooks/STAGING_ENVIRONMENT.md) (steps, smoke list, reset, rollback, cost). Remove: delete the three Applications' files and the stage directory
in gitops, then turn off deletion protection and destroy `module.rds_stage` (human).

## Known limitation: stage can reach prod's database port

Both RDS security groups admit the **shared node security group**, and stage's `api-egress` policy (a copy of prod's) allows TCP 5432 to the whole VPC `10.0.0.0/16`.
A compromised stage pod could therefore open a connection to the production database. It could not log in: the stage pods hold no prod credential (their Vault roles
`weysure-stage-*` mint users on the stage database only, `weysure/stage` carries no prod value, and the stage pod-identity role reads only the stage master secret). Both
instances sit in the same private subnets, so a CIDR rule cannot tell them apart, and a `/32` for the stage instance would break whenever AWS moves it. Proper separation
needs security groups for pods or an FQDN-aware policy: tracked below, accepted for a test-data environment.

## Follow-ups

- Secret store scope: the shared `vault` ClusterSecretStore lets any namespace read any `secret/weysure/*` path (ESO role `external-secrets`), so a stage ExternalSecret could name `weysure/prod`. Existing property of the cluster; fix with per-namespace store conditions or a store per environment.
- Cookie tossing: stage is a sibling subdomain of weysure.com. Prod's `__Host-` cookies cannot be set from a subdomain; the old-name fallback (dropped 2026-12-15) can. A separate registrable domain for stage removes the question.
- Origin access: only the Cloudflare rule gates stage. Authenticated Origin Pulls (or Cloudflare Access + `access-verify`) would enforce it at the origin too.
- Separate stage from prod at the network layer (security groups for pods, or an FQDN-aware egress policy), see the limitation above.

- Developers: boot guard should refuse a live key in `PAYSTACK_LIVE_SECRET_KEY` too when `ENVIRONMENT=staging`.
- Web: a visible STAGING banner and `robots` noindex need a code change (`NEXT_PUBLIC_ENV_LABEL`); not done (the web app has none today). Stage sends `X-Robots-Tag: noindex` from Traefik.
- Alerts and a Blackbox probe for `weysure-stage` (prod's rules name `weysure-prod`).
- Decide `PROMOTE_TO_PROD=manual` (recommended before live keys).
- Authenticated Origin Pulls on the `weysure.com` zone (hardens prod and stage against other Cloudflare accounts).
- Optional: stage CI e2e against the stage URL after each promotion.
