# Runbook — the staging environment

Stage is a second, smaller copy of Weysure that every change passes through **before** production: its own
namespace (`weysure-stage`), its own database (`weysure-stage-postgres`), its own Vault paths, its own hosts.
It runs the same chart, the same flags and the same API image as prod, on **test keys only**.

| | Prod | Stage |
|---|---|---|
| Web | `weysure.com` | `staging.weysure.com` |
| API | `api.weysure.com` | `api-staging.weysure.com` |
| Namespace | `weysure-prod` | `weysure-stage` (same cluster, same nodes) |
| Database | RDS `weysure-postgres-v2` | RDS `weysure-stage-postgres` (db.t3.micro, single-AZ, 20 GB) |
| Replicas | api 2 (HPA 2–4), worker 1, web 2 (HPA 2–4) | 1 each |
| `ENVIRONMENT` | `prelaunch` (`production` at launch) | `staging` |
| Keys | test today, live at launch | test, always |
| Who can open it | the world | the addresses on the Cloudflare rule |
| Git | `environments/prod/` | `environments/stage/` (gitops) |

## How a change flows

```
PR in Weysure-API / Weysure  ->  PR build (tests, Sonar, e2e)  ->  merge to main
   -> Jenkins on main: build, scan, push the image
   -> Promote: stage/images.yaml only (PROMOTE_TO_PROD=manual)
   -> Argo CD syncs weysure-api-stage / weysure-web-stage  -> migration runs on the STAGE database
   -> you check stage (smoke list below)
   -> you promote prod: a gitops PR copying the stage tags to prod/images.yaml
```

**The gate.** `PROMOTE_TO_PROD` is `manual` in both Jenkinsfiles (decision of 2026-11-20: stage is a gate before live keys). Jenkins promotes **stage only**;
prod is promoted by a plateng-gitops PR that sets `environments/prod/images.yaml` to the tag stage just ran (api: the same tag; web: the stage tag minus `-stage`),
after the smoke list is green. Rollback of prod is unchanged (revert the commit). **Emergency prod deploy:** change `PROMOTE_TO_PROD = 'manual'` to `'auto'` in the
`environment` block of the Jenkinsfile (the next main build then promotes stage and prod in one push), or edit prod's `images.yaml` directly.

Web has **two images per commit**: `weysure-web:<sha12>` (prod, `NEXT_PUBLIC_API_URL=https://api.weysure.com/api/v1`) and
`weysure-web:<sha12>-stage` (stage, `https://api-staging.weysure.com/api/v1`). The browser bundle bakes the API URL in at
build time, so the prod image on stage would call the production API. Both are built from the same commit on main; the
second build adds about 4–6 minutes (estimated: deps are cached, `next build` and the push are not; measure on the first run).
API: one image serves both.

## What stage cannot do: move real money

Four independent layers; any one of them is enough. Layers 1 and 2 are enforced by CI and at boot, 3 and 4 by the providers.

1. **Its Vault path holds no live key, and none can reach the pods.** `secret/weysure/stage` is seeded with the *test* Paystack
   pair. The stage ExternalSecret lists its 24 keys explicitly (`externalSecret.keys` in `stage/apps/api/values.yaml`);
   `PAYSTACK_LIVE_PUBLIC_KEY` and `PAYSTACK_LIVE_SECRET_KEY` are not on the list, so they would not arrive even if someone wrote them
   to that path. The chart render test (`charts/beyric-app/tests/render-test.sh`) fails the PR if a `PAYSTACK_LIVE*` key appears.
2. **The API refuses to boot with a live wallet key when `ENVIRONMENT=staging`**
   (`app/core/boot_guard.py`, `LIVE_KEY_FORBIDDEN_ENVS`; read on API main `de5e9d06`). The pod would crash-loop, not charge.
   *Known gap:* that check covers `PAYSTACK_SECRET_KEY` only; a live key placed in the separate `PAYSTACK_LIVE_SECRET_KEY` slot
   passes it. Layer 1 is what covers that slot. Follow-up for the developers: make the boot guard refuse a live key in either slot in staging.
3. **A Paystack `sk_test_` key only reaches Paystack's test mode:** no real card is charged and no real transfer is paid, whatever the code does.
4. **Dojah is the sandbox** (`DOJAH_ENVIRONMENT=sandbox`, sandbox base URL, sandbox keys).

Stage still sends **real email and real SMS** (Resend/SMTP and Termii): the API requires a real Termii key outside dev/test
(`app/integrations/termii/factory.py` refuses the fake provider in `staging`). Only numbers and addresses a tester types in receive anything.

## Steps only Adebayo can run, in this order

Every command below changes AWS, Vault, Cloudflare or the cluster, so each is yours (`docs/conventions/HUMAN_GATED_COMMANDS.md`).
Nothing here has been run. Do them in this order; each step says what to expect.

**Step 0 — sign in.**

```bash
export AWS_PROFILE=beyric-admin
aws sso login
aws sts get-caller-identity --query Arn --output text    # must contain "assumed-role"
kubectl config current-context                           # must contain beyric-prod
```

**Step 1 — merge the infra PR (`feature/staging-rds`), then create the database.**

*Where:* `plateng-infrastructure-tools/projects/weysure/terraform` on `main` after the merge (`git pull` first).

```bash
terraform init
terraform plan -out=stage.tfplan
```

*Expect:* `Plan: 8 to add, 0 to change, 0 to destroy.` Anything that changes or destroys an existing resource means stop and send me the plan.

```bash
terraform apply stage.tfplan
```

*Expect:* `Apply complete! Resources: 8 added, 0 changed, 0 destroyed.` It takes about 10 minutes (the database). Then:

```bash
terraform output rds_stage_endpoint
```

*Expect:* `weysure-stage-postgres.cm7yqww8uycm.us-east-1.rds.amazonaws.com:5432`. That host is already written in the gitops files; if yours differs, stop.
*If it goes wrong:* a failed apply leaves the resources it did create in state; fix the error and apply again. Nothing here touches prod
resources (the plan shows 0 changed). Deletion protection is on, so the database cannot be destroyed by accident; to remove it later you turn that off first.

**Step 2 — Vault: the stage policies and roles** (the Vault side of the bootstrap Job; Vault is configured by hand, see `VAULT_CONFIG.md`).

```bash
kubectl -n vault port-forward svc/vault 8200:8200
```

(leave it running; in a second terminal)

```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault login -method=userpass username=adebayo
```

First look at what prod has, so the stage objects match it:

```bash
vault policy read weysure-db-app
vault read auth/kubernetes/role/weysure-api
vault read auth/kubernetes/role/weysure-migrate
```

Then write the stage policies (three commands) and roles (three commands):

```bash
vault policy write weysure-stage-db-app - <<'EOF'
path "database/creds/weysure-stage-app" { capabilities = ["read"] }
path "sys/leases/renew" { capabilities = ["update"] }
EOF
```

```bash
vault policy write weysure-stage-db-migrate - <<'EOF'
path "database/creds/weysure-stage-migrate" { capabilities = ["read"] }
EOF
```

```bash
vault policy write db-bootstrap-stage - <<'EOF'
path "database/config/weysure-stage" { capabilities = ["create", "read", "update", "delete"] }
path "database/rotate-root/weysure-stage" { capabilities = ["update"] }
path "database/roles/weysure-stage-*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "database/creds/weysure-stage-app" { capabilities = ["read"] }
EOF
```

```bash
vault write auth/kubernetes/role/weysure-stage-api bound_service_account_names=api,api-worker bound_service_account_namespaces=weysure-stage policies=weysure-stage-db-app ttl=1h max_ttl=24h audience=https://kubernetes.default.svc
```

```bash
vault write auth/kubernetes/role/weysure-stage-migrate bound_service_account_names=db-migrate bound_service_account_namespaces=weysure-stage policies=weysure-stage-db-migrate ttl=30m max_ttl=1h audience=https://kubernetes.default.svc
```

```bash
vault write auth/kubernetes/role/db-bootstrap-stage bound_service_account_names=db-bootstrap bound_service_account_namespaces=weysure-stage policies=db-bootstrap-stage ttl=15m
```

*Expect:* `Success! Uploaded policy` ×3 and `Success! Data written` ×3. If the prod `weysure-api` role you read above has fields this
doc does not (for example a different `audience`), copy prod's. Nothing else in Vault changes; the existing `external-secrets` role already
reads every path under `secret/weysure/*`, so `weysure/stage` needs no new ESO policy.
Record these objects in `VAULT_CONFIG.md` (a one-line table row each) once they exist.

**Step 3 — Vault: the stage secret. Do this BEFORE live keys go into prod.** It copies prod's *test-phase* values for the providers
that have a sandbox (Cloudinary, SMTP, Dojah sandbox, Termii), makes stage's own random application secrets (so a token minted
on stage is worthless on prod and the reverse), and makes the Paystack slots the *test* pair. Nothing is printed.
The script stops (and writes nothing) if prod's test Paystack key is missing or is not `sk_test_…`.
After prod holds live keys, **never** run this again: type the sandbox Dojah and Termii keys in by hand instead of copying.

```bash
(
  set -o pipefail
  export SK=$(vault write -field=random_bytes sys/tools/random/32 format=hex)
  export PEP=$(vault write -field=random_bytes sys/tools/random/32 format=hex)
  export FP=$(vault write -field=random_bytes sys/tools/random/32 format=hex)
  export RH=$(vault write -field=random_bytes sys/tools/random/32 format=hex)
  export MFA=$(vault write -field=random_bytes sys/tools/random/32 format=base64 | tr '+/' '-_')
  vault kv get -format=json secret/weysure/prod | jq '
    .data.data
    | del(.PAYSTACK_LIVE_PUBLIC_KEY, .PAYSTACK_LIVE_SECRET_KEY)
    | .PAYSTACK_SECRET_KEY = .PAYSTACK_TEST_SECRET_KEY
    | .PAYSTACK_PUBLIC_KEY = .PAYSTACK_TEST_PUBLIC_KEY
    | .PAYSTACK_WEBHOOK_SECRET = .PAYSTACK_TEST_SECRET_KEY
    | .SECRET_KEY = $ENV.SK | .MFA_CODE_PEPPER = $ENV.PEP | .KYC_FINGERPRINT_KEY = $ENV.FP
    | .RISK_SIGNAL_HASH_KEY = $ENV.RH | .MFA_ENCRYPTION_KEY = $ENV.MFA
    | if (.PAYSTACK_SECRET_KEY | startswith("sk_test_")) then . else error("stage needs a TEST Paystack key") end
  ' | vault kv put secret/weysure/stage -
)
```

(The brackets run it in a sub-shell, so the generated values are gone from your shell afterwards.) The random values come from Vault, not your laptop.

*Expect:* a `Secret Path`, `version 1` table (no values). Check the key **names** (not values):

```bash
vault kv get -format=json secret/weysure/stage | jq -r '.data.data | keys[]'
```

*Expect:* 24 names: `ADMIN_NOTIFICATION_EMAILS CLOUDINARY_API_KEY CLOUDINARY_API_SECRET CLOUDINARY_CLOUD_NAME DOJAH_API_KEY DOJAH_WEBHOOK_SECRET EMAILS_FROM_EMAIL EMAILS_FROM_NAME KYC_FINGERPRINT_KEY MFA_CODE_PEPPER MFA_ENCRYPTION_KEY PAYSTACK_PUBLIC_KEY PAYSTACK_SECRET_KEY PAYSTACK_TEST_PUBLIC_KEY PAYSTACK_TEST_SECRET_KEY PAYSTACK_WEBHOOK_SECRET RISK_SIGNAL_HASH_KEY SECRET_KEY SMTP_HOST SMTP_PASSWORD SMTP_PORT SMTP_TLS SMTP_USER TERMII_API_KEY`
(each once) and **no** `PAYSTACK_LIVE_*`. These are the only keys the pods read. *Two choices to make, both fine to leave as copied:* stage shares prod's Cloudinary
account (stage uploads land beside prod's; a separate Cloudinary cloud avoids that) and sends to `ADMIN_NOTIFICATION_EMAILS` (prod's admin inbox).
To change either later: `vault kv patch secret/weysure/stage KEY=value`.
*If it goes wrong:* `vault kv metadata delete secret/weysure/stage` removes the path; run the step again.

**Step 4 — Cloudflare (dashboard, zone `weysure.com`).**

a. DNS → add two records, both **Proxied** (orange cloud), exactly like `api`:

| Type | Name | Target |
|---|---|---|
| CNAME | `staging` | `k8s-traefik-traefik-1b6c471b42-26334752ea7a5cd9.elb.us-east-1.amazonaws.com` |
| CNAME | `api-staging` | `k8s-traefik-traefik-1b6c471b42-26334752ea7a5cd9.elb.us-east-1.amazonaws.com` |

(That hostname is the Traefik load balancer; confirm with `kubectl -n weysure-prod get ingress api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`.)
They are one level under `weysure.com`, so Cloudflare's free certificate covers them; the zone's "Full (strict)" and "Always HTTPS"
settings already apply. cert-manager issues the Let's Encrypt certificates by DNS-01, as for `api.weysure.com`.

b. **Who may open stage.** Security → WAF → Custom rules → Create rule, action **Block**, name `stage: allow-list only`, expression
(Edit expression), with your real public IPs in place of the two documentation addresses:

```
(http.host in {"staging.weysure.com" "api-staging.weysure.com"}
 and not ip.src in {203.0.113.7 198.51.100.4}
 and not (http.host eq "api-staging.weysure.com"
          and http.request.uri.path in {"/api/v1/wallet/paystack/webhook" "/api/v1/kyc/dojah/webhook"}))
```

The last line lets Paystack and Dojah deliver webhooks (they come from addresses we do not control; the API still checks their signature,
as on prod). Add or remove people by editing the list. **Why Cloudflare and not a rule in the cluster:** Traefik never sees the real client
address (its access log shows only the load balancer's private addresses), so an in-cluster IP list would lock everyone out. Cloudflare sees the real address.
*Not covered:* the load balancer admits every Cloudflare customer (known, accepted for prod, see the domain-cutover plan), so another Cloudflare
account could in theory reach stage by sending the right `Host`. Stage holds test data only; hardening is Authenticated Origin Pulls, noted as a follow-up.

**Step 5 — merge the gitops PR (`feature/staging-environment`).** Do it only after steps 1–4. Argo CD creates the three Applications by itself.
Nothing to sync by hand. Watch (read-only):

```bash
kubectl -n argocd get applications | grep stage
kubectl -n weysure-stage get job,pods,externalsecret,certificate,ingress
kubectl -n weysure-stage logs job/db-bootstrap-v1 -c configure-vault-db-engine
```

*Expect, within about 5 minutes:* `db-bootstrap-v1` Complete, its log ending `stage db bootstrap complete` after one username line (`v-…`);
`weysure-app-config` `SecretSynced`; certificates `Ready`; `redis-0` Running; `weysure-api-stage` Synced after a PreSync migration Job
(`weysure-api-db-migrate`) ran every migration on the empty stage database; `api` and `api-worker` Running. **`web` shows `ImagePullBackOff` until step 6: expected.**
*If the bootstrap Job fails:* `kubectl -n weysure-stage logs job/db-bootstrap-v1 --all-containers` says which of its three steps. Jobs are immutable: fix the cause,
delete the Job (`kubectl -n weysure-stage delete job db-bootstrap-v1`) and let Argo re-create it. Nothing in Vault is half-written in a harmful way:
the Job rewrites the same config and re-rotates.

**Step 6 — merge the two Jenkinsfile PRs (`ci/promote-to-stage-first`), one at a time.** Weysure (web, PR 90) first, then Weysure-API. Each merge starts a main build
(about an hour; the web one builds twice). Afterwards `stage/images.yaml` carries the new tags and `weysure-web-stage` pulls
`weysure-web:<sha12>-stage`. **Prod no longer deploys by itself after these merges** (`manual`): see "The gate". Until the gitops PR is merged, a missing stage file is skipped, so the merge order does not break CI.
Check: `curl -s https://api-staging.weysure.com/api/v1/health` from an allowed address (200), and `https://staging.weysure.com` loads.

**Step 7 — Paystack dashboard (test mode).** Settings → API Keys & Webhooks → *Test* webhook URL =
`https://api-staging.weysure.com/api/v1/wallet/paystack/webhook`. The test webhook is not on prod today, so this does not move anything.
(Paystack's live webhook URL, set at launch, points at `api.weysure.com`.)

**Step 8 — the first admin on stage.** A fresh database has no admin. Follow `sop/2026-10-09-secret-key-first-superadmin-sonar-gate.md` steps 2 and 3
with stage targets: step 2's insert via `TARGET=stage scripts/db-oneoff.sh <api image tag> write "<the INSERT from that SOP>"`, and step 3 against
`kubectl -n weysure-stage exec -it <stage api pod> -c api -- …` (exec into the **stage** pod is fine; never prod). Then sign in at `https://staging.weysure.com/admin/login`.

## What to check on stage before prod

Run on `https://staging.weysure.com`, from an allowed address, with test data. Tick each; any failure stops the prod promotion.

| # | Check | Pass |
|---|---|---|
| 1 | Open the site; the header shows no error and `https://api-staging.weysure.com/api/v1/health` is 200 | |
| 2 | Sign up a new user, verify the email (real mail arrives), sign in, sign out | |
| 3 | Sign in as an admin; the 2FA step appears (stage runs MFA as prod does) | |
| 4 | Create a deal (escrow) as buyer, invite the seller (Tier 2 users via admin "set tier 2") | |
| 5 | Fund it with a **Paystack test card** (Paystack's published test card numbers only; never a real card) | |
| 6 | The webhook credits it (watch the API logs: `kubectl -n weysure-stage logs deploy/api -c api --tail=50`) | |
| 7 | Seller delivers, buyer releases; both wallets show the amounts | |
| 8 | Withdraw to a **Paystack test bank account** from the seller wallet; the withdrawal settles | |
| 9 | Anything the change itself touched (read the PR description) | |
| 10 | `kubectl -n weysure-stage get pods` all Running, no restarts; `kubectl -n argocd get applications | grep stage` Synced and Healthy | |

Known differences from prod that the check cannot judge: one replica (no rolling-update test across two pods), `ENVIRONMENT=staging` also returns the
bank-account verification link in the API response, and no alerts watch stage (prod's alert rules name `weysure-prod`).

## Reset stage data

When stage is full of old test data, or to rehearse every migration from an empty database. All commands change stage only.

```bash
kubectl -n weysure-stage scale deploy api api-worker --replicas=0
```

```bash
kubectl create -f plateng-gitops/projects/weysure/environments/stage-maintenance/db-reset-job.yaml
```

```bash
kubectl -n weysure-stage logs job/<the db-reset-… name printed above> -c reset-schema
```

*Expect:* `tables_left 0` and `stage database reset: empty schema, roles and grants intact`.

```bash
kubectl -n weysure-stage exec redis-0 -- redis-cli FLUSHALL
```

```bash
argocd app sync weysure-api-stage
```

*Expect:* the PreSync migration Job runs every migration on the empty database, api and worker come back at 1 replica. Then redo step 8 (the first admin).
The Job can only reach the stage database (the host is the stage instance and its pod-identity role reads only the stage secret).
Never run it with prod's namespace or host.

## Roll back stage

A bad stage deploy: revert the `ci(weysure-…): promote … to stage` commit in plateng-gitops (as on prod). A broken stage database: reset (above), or restore a snapshot
(`RESTORE_DRILL.md`; backups are 7 days). Taking stage away completely: delete the three `weysure-*stage*` Applications' files, then (human) turn off
`deletion_protection` for `module.rds_stage` and destroy; the monthly cost below goes to zero.

## Cost (estimate, USD per month, us-east-1)

| Piece | $/mo | Basis |
|---|---|---|
| RDS `db.t3.micro`, single-AZ, PostgreSQL | 13.14 | AWS price list: $0.018/h × 730 h |
| RDS storage, 20 GB gp3 | 2.30 | AWS price list: $0.115/GB-month |
| RDS backups (7 days) | 0 | free up to the size of the database |
| Master password secret (Secrets Manager) | 0.40 | per secret |
| CloudWatch log export (`postgresql`, `upgrade`) | ~0.20 | tiny volume; estimate |
| Redis volume, 2 GB gp3 | 0.16 | EBS $0.08/GB-month |
| Extra node | 0 | fits on the existing Karpenter nodes (below) |
| Load balancer, ingress | 0 | stage shares the Traefik NLB |
| DNS, certificates | 0 | Cloudflare free plan, Let's Encrypt |
| ECR | ~0.5 | one more web image (~84 MB) per main merge; no expiry rule matches `-stage` tags |
| Jenkins | ~0.02 per merge | second web build, about 5 min of an on-demand build node |
| **Total** | **≈ 16–17** | |

Capacity (read from the cluster 2026-11-20): two Karpenter workload nodes (c6a.xlarge on-demand, c5a.xlarge spot), 3.9 vCPU and about 6.9 GiB
allocatable each; free CPU/memory requests about 1.3 vCPU / 1.6 GiB and 2.5 vCPU / 3.2 GiB. Stage requests 0.56 vCPU and 1.25 GiB in total (api 250m/512Mi,
worker 100m/256Mi, web 100m/256Mi, redis 50m/128Mi, three Vault sidecars 60m/96Mi), so it fits. If Jenkins builds and stage ever
crowd a node, Karpenter adds one by itself (c6a.xlarge on-demand about $112/mo, spot about $45/mo, while it is needed). That already happens for Jenkins today.
