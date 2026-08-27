# Phase 0 — Foundations & Guardrails: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put every repository, credential and piece of infrastructure code under governance
before a single AWS resource is created.

**Architecture:** Nothing is provisioned in this phase. We make the *wrong thing hard* first:
secret scanning that blocks commits, Terraform that parses and validates, repositories that
require review, short-lived AWS credentials replacing permanent ones, and a budget alarm that
fires before a surprise bill does. Every later phase depends on these guardrails existing.

**Tech Stack:** Terraform 1.15.8 · Gitleaks · pre-commit · TFLint · AWS CLI 2.35.11 · GitHub CLI 2.93.0 · AWS IAM Identity Center · AWS Organizations · AWS Budgets

**Spec:** [`../specs/2026-08-26-weysure-platform-design.md`](../specs/2026-08-26-weysure-platform-design.md)

## Global Constraints

- **AWS spend for this entire phase: $0.** No `terraform apply`. AWS Organizations, IAM Identity Center and AWS Budgets are all free.
- **Region:** `us-east-1` (ADR-002). Every AWS command uses `--region us-east-1`.
- **AWS account:** `767397877316`. Current profile: `personal`.
- **No AI attribution** in any commit message, PR body, or issue body.
- **Never commit to a default branch.** Work on `feature/*`; every change lands via pull request.
- **Never print a secret value.** Key *names* may be listed; values never.
- **Terraform state bucket:** `victor-terraform-state-2026`, key prefix `weysure/`, region `us-east-1`.
- **Resource tagging:** every AWS resource carries `Project=weysure`, `Environment`, `ManagedBy=terraform`, `Repository=Beyric/plateng-infrastructure-tools`, applied through the provider's `default_tags`. Cost Explorer grouping depends on this.

### Inputs you must supply

These are the only values this plan cannot determine. Substitute them wherever they appear;
do not leave the literal placeholder in a command you run.

| Placeholder | Where | What to supply |
|---|---|---|
| `you@example.com` | Task 8, Step 2 | The address that should receive budget alerts |
| SSO start URL | Task 7, Step 5 | The AWS access portal URL shown after enabling Identity Center in Step 3 |
- **Repositories:**
  - `Beyric/plateng-infrastructure-tools` — Terraform + docs (this repo)
  - `Beyric/plateng-gitops` — Kubernetes desired state (empty)
  - `innocent98/Weysure-API` — FastAPI backend, default branch `main`
  - `innocent98/Weysure` — Next.js frontend, default branch `main`
- **Local paths:**
  - `~/Documents/plateng-infra/plateng-infrastructure-tools`
  - `~/Documents/plateng-infra/plateng-gitops`
  - `~/Documents/plateng-infra/weysure-infrastructure` — legacy Terraform, source for the migration
  - `~/Documents/dev/weysure/Weysure-API`, `~/Documents/dev/weysure/Weysure`

---

## New findings discovered while planning

These were not in the original spec. Both are added to the findings register.

### Finding ⑮ — The existing Terraform does not parse

`weysure-infrastructure/modules/rds/variables.tf:9`:

```hcl
variable "db_password"        { type = string  sensitive = true }
```

`terraform fmt -check` rejects it:

```
Error: Invalid single-argument block definition
A single-line block definition must end with a closing brace immediately
after its single argument definition.
```

A single-line HCL block may contain **one** argument. This proves the configuration was never
successfully planned. Resolved in Task 4 — by deleting the variable entirely, per ADR-010.

### Finding ⑯ — `.env` with live secrets is in `Weysure-API` git history

Commit `52f89f2` ("feat: Auth flow enhanced") **added a real `.env`**. Commit `6b2e901` removed
it — but removal from `HEAD` does not remove it from history. Anyone who can clone the
repository can run `git show 52f89f2:.env`.

Key names present (values deliberately not recorded here):

| Key | Why it matters |
|---|---|
| `SECRET_KEY` | Signs every application JWT. Unrotated, anyone with repo history can forge an authentication token for any user. |
| `SUPABASE_SERVICE_ROLE_KEY` | Full admin access to the Supabase project, bypassing row-level security. |
| `SUPABASE_JWT_SECRET`, `SUPABASE_WEBHOOK_SECRET` | Token forgery and webhook spoofing. |
| `DATABASE_URL` | Complete Postgres credentials. |
| `SMTP_PASSWORD` | Outbound mail as your domain. |

`innocent98/Weysure` also committed a `.env` (commit `fad698b`), but it contained only
`NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_WS_URL` — public by definition. No action needed.

**Severity is bounded** — the repository is private and you are the only collaborator, and there
are no live users yet. It is not an emergency. It *is* a real exposure, and rotation is the only
true remediation: history rewriting reduces future risk but cannot un-disclose a credential.
Resolved in Task 3.

---

## File structure

| Path | Responsibility |
|---|---|
| `.gitleaks.toml` | Gitleaks rules and allowlist for this repo |
| `.pre-commit-config.yaml` | Pre-commit hooks: gitleaks, terraform fmt, TFLint |
| `.tflint.hcl` | TFLint ruleset and AWS plugin configuration |
| `CODEOWNERS` | Review ownership |
| `modules/vpc/{main,variables,outputs}.tf` | Reusable VPC module — migrated |
| `modules/eks/{main,variables,outputs}.tf` | Reusable EKS module — migrated |
| `modules/rds/{main,variables,outputs}.tf` | Reusable RDS module — migrated, parse error fixed, ADR-010 applied |
| `projects/weysure/terraform/{versions,variables,main,outputs}.tf` | Weysure root module |
| `projects/weysure/terraform/terraform.tfvars.example` | Documented example values — **never real secrets** |
| `projects/weysure/docs/runbooks/SECRET_ROTATION.md` | Rotation procedure produced by Task 3 |
| `docs/conventions/REPOSITORY_STANDARDS.md` | Cross-project repo governance rules |

Tasks run in order. Task 2 precedes Task 4 deliberately: secret scanning must be active
*before* Terraform containing a password is moved into a repository.

---

## Task 1: Correct the phase ordering in the design documents

The spec's phase plan contradicts `ARCHITECTURE.md` diagram 7. The diagram says
Terraform → Argo CD → Vault → ESO → applications. The phase plan installs Traefik and
cert-manager in Phase 2 but Argo CD in Phase 5 — which would mean `helm install`-ing three
platform components by hand and retrofitting them into Argo CD later. That is exactly the
imperative drift this design exists to prevent.

Reordering also **reduces hand-created bootstrap secrets from three to one**. Vault needs no
ingress to be configured (`kubectl port-forward` suffices), so if Vault precedes Traefik, the
Cloudflare API token that `external-dns` and `cert-manager` require comes *out of Vault*
rather than from `kubectl create secret`.

**Files:**
- Modify: `projects/weysure/docs/specs/2026-08-26-weysure-platform-design.md` — the phase table in §5
- Modify: `projects/weysure/docs/checklist/BUILD_CHECKLIST.md` — phase section order and headings
- Modify: `projects/weysure/docs/architecture/blueprint.html` — the `.phases` block
- Modify: `projects/weysure/memory/DECISIONS.md` — append ADR-014

**Interfaces:**
- Produces: the canonical phase numbering every later plan refers to.

- [ ] **Step 1: Confirm the contradiction exists**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
grep -n 'Argo CD' projects/weysure/docs/specs/2026-08-26-weysure-platform-design.md | grep -E '^\s*[0-9]+:\| \*\*[0-9]'
```

Expected: Argo CD appears on the row for Phase **5**, while diagram 7 places it second. This is the defect.

- [ ] **Step 2: Apply the new ordering to the spec phase table**

Replace rows 2–5 of the phase table in §5 with:

| # | Phase | Exit criteria | Spend |
|---|---|---|---|
| **2** | **GitOps bootstrap** | Default `gp3` StorageClass binds a test PVC; metrics-server serving; Argo CD installed via the one documented manual bootstrap and **self-managing**; app-of-apps root reconciling | — |
| **3** | **Secrets** | Vault deployed by Argo CD, initialised once, KMS auto-unseal working; recovery keys in AWS Secrets Manager; root token revoked; KV v2 populated; ESO syncing; Reloader verified by rotating a secret | — |
| **4** | **Ingress & TLS** | Namecheap NS delegated to Cloudflare; Traefik behind an NLB; **NLB security group restricted to Cloudflare IP ranges**; cert-manager issuing a real Let's Encrypt certificate via Cloudflare DNS-01 using a **token read from Vault**; external-dns writing records; Traefik honouring `CF-Connecting-IP` | + LB |
| **5** | **Data layer** | RDS applied with `manage_master_user_password`; Supabase→RDS migration rehearsed, verified and cut over; Redis running; **Vault database engine issuing 1-hour credentials**; restore drill timed | + DB |

- [ ] **Step 3: Reorder the matching sections in the build checklist**

Move the `## Phase 5 — GitOps` section to sit directly after Phase 1 and renumber it to
`## Phase 2 — GitOps bootstrap`. Move `## Phase 4 — Secrets` to `## Phase 3 — Secrets`.
Rename `## Phase 2 — Cluster baseline` to `## Phase 4 — Ingress & TLS` and move it after
Secrets. Renumber `## Phase 3 — Data layer` to `## Phase 5 — Data layer`. Phases 0, 1 and
6–10 keep their numbers and content.

In the new Phase 4 section, change this line:

```markdown
- [ ] Cloudflare API token (scoped: Zone.DNS edit only) → Vault
```

to:

```markdown
- [ ] Cloudflare API token (scoped: Zone.DNS edit only) read **from Vault** via ExternalSecret — no hand-created Secret
```

- [ ] **Step 4: Update the phase list in the published blueprint**

In `projects/weysure/docs/architecture/blueprint.html`, inside `<div class="phases">`, replace
the four `<div class="ph">` blocks numbered 02–05 with:

```html
<div class="ph"><span class="ph-n">02</span><span class="ph-t">GitOps bootstrap</span><span class="ph-d">Storage, metrics-server, Argo CD installed once by hand and thereafter self-managing. The cluster stops being something you talk to directly.</span></div>
<div class="ph"><span class="ph-n">03</span><span class="ph-t">Secrets</span><span class="ph-d">Vault with KMS auto-unseal, ESO, Reloader. Deployed by Argo CD; needs no ingress, so it comes first.</span></div>
<div class="ph"><span class="ph-n">04</span><span class="ph-t">Ingress &amp; TLS</span><span class="ph-d">Cloudflare delegation, Traefik, cert-manager, external-dns — with the Cloudflare token read from Vault, not hand-created.</span></div>
<div class="ph"><span class="ph-n">05</span><span class="ph-t">Data layer</span><span class="ph-d">RDS with managed master password, migration rehearsed and cut over, Redis, Vault database engine, restore drill timed.</span></div>
```

- [ ] **Step 5: Record ADR-014**

Append to `projects/weysure/memory/DECISIONS.md`:

```markdown
---

## ADR-014 — Phase order: GitOps and Secrets before Ingress

**Date:** 2026-08-26 · **Status:** Accepted · **Corrects** the phase plan in the original spec

**Context.** The original phase plan installed Traefik, cert-manager and external-dns in Phase 2
but Argo CD in Phase 5, contradicting the bootstrap ordering in ARCHITECTURE.md diagram 7. Left
alone it would have meant installing three platform components imperatively with `helm install`
and retrofitting them into Argo CD three phases later.

**Decision.** Argo CD lands immediately after the cluster (Phase 2), Vault and ESO next
(Phase 3), ingress and TLS after that (Phase 4), data layer fifth.

**Consequences.** Every platform component after Phase 2 is installed *by* Argo CD, so no
component is ever adopted retroactively. Because Vault is usable through `kubectl port-forward`
and needs no ingress, placing it before Traefik means the Cloudflare API token required by
external-dns and cert-manager is read from Vault rather than hand-created — reducing the count
of manual bootstrap secrets from three to one.

The one remaining hand-created secret is Argo CD's git credential, which is irreducible: Vault
is installed by Argo CD, so it cannot supply the credential Argo CD needs to find Vault.

**Revisit if:** a future component genuinely requires ingress before secrets are available.
```

- [ ] **Step 6: Verify no stale phase references remain**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
grep -rn 'Phase 5' projects/weysure/docs/specs projects/weysure/docs/checklist | grep -i 'gitops\|argo'
```

Expected: **no output.** Any hit is a stale reference that must be corrected.

- [ ] **Step 7: Verify all diagrams still render**

```bash
export PUPPETEER_EXECUTABLE_PATH=$(find ~/.cache/puppeteer -name chrome-headless-shell -type f | head -1)
cd /tmp && rm -rf mmcheck && mkdir mmcheck && cd mmcheck
printf '{"args":["--no-sandbox"]}' > pc.json
python3 -c "
import re,pathlib
src=pathlib.Path('$HOME/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/docs/architecture/ARCHITECTURE.md').read_text()
for i,b in enumerate(re.findall(r'\`\`\`mermaid\n(.*?)\`\`\`',src,re.S),1):
    pathlib.Path(f'd{i:02d}.mmd').write_text(b)
"
for f in d*.mmd; do mmdc -i "$f" -o "${f%.mmd}.svg" -p pc.json -q 2>/dev/null; done
echo "rendered: $(ls -1 *.svg 2>/dev/null | wc -l) / 10"
```

Expected: `rendered: 10 / 10`

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add projects/weysure/docs projects/weysure/memory
git commit -m "docs(platform): reorder phases so GitOps and Secrets precede Ingress

The phase plan contradicted the bootstrap ordering in ARCHITECTURE.md
diagram 7: Traefik and cert-manager were scheduled for Phase 2 but Argo CD
for Phase 5, which would have meant installing platform components
imperatively and adopting them into Argo CD later.

Argo CD now lands in Phase 2, Vault and ESO in Phase 3, ingress in Phase 4.
Because Vault needs no ingress, the Cloudflare API token required by
external-dns and cert-manager is now read from Vault rather than
hand-created, reducing manual bootstrap secrets from three to one.

Recorded as ADR-014."
```

---

## Task 2: Install and configure the security toolchain

None of `gitleaks`, `pre-commit`, `tflint`, `checkov` is currently installed — verified. Secret
scanning must be working before Task 4 moves a file containing a password into this repository.

**Files:**
- Create: `.gitleaks.toml`
- Create: `.pre-commit-config.yaml`
- Create: `.tflint.hcl`

**Interfaces:**
- Produces: a working `gitleaks detect` command and installed pre-commit hooks that Task 4 relies on.

- [ ] **Step 1: Verify the tools are absent (this is the failing test)**

```bash
for t in gitleaks pre-commit tflint; do printf '%-12s ' "$t"; command -v $t >/dev/null 2>&1 && echo present || echo ABSENT; done
```

Expected: all three report `ABSENT`.

- [ ] **Step 2: Install them**

```bash
brew install gitleaks pre-commit tflint
```

- [ ] **Step 3: Verify installation**

```bash
gitleaks version && pre-commit --version && tflint --version
```

Expected: three version strings, no errors.

- [ ] **Step 4: Write the Gitleaks configuration**

Create `.gitleaks.toml` in the repository root:

```toml
# Extends the maintained default ruleset rather than replacing it.
[extend]
useDefault = true

[allowlist]
description = "Paths that legitimately contain secret-shaped strings"
paths = [
  '''\.gitleaks\.toml$''',
  '''terraform\.tfvars\.example$''',
  '''projects/weysure/docs/.*\.md$''',
]

[[rules]]
id = "terraform-inline-password"
description = "A password, secret or token assigned literally in a .tf or .tfvars file"
regex = '''(?i)(password|secret|token|access_key)\s*=\s*"[^"$][^"]{7,}"'''
path = '''\.tfvars?$'''
[rules.allowlist]
regexes = [
  '''=\s*"(<redacted>|REPLACE_ME|CHANGEME|example)"''',
]
```

- [ ] **Step 5: Prove the rule catches a real secret**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
printf 'db_password = "NotARealPasswordButLooksLikeOne123"\n' > /tmp/canary.tfvars
cp /tmp/canary.tfvars ./canary.tfvars
gitleaks detect --no-git --source . --config .gitleaks.toml --redact -v ; echo "exit=$?"
```

Expected: a finding for `canary.tfvars`, rule `terraform-inline-password`, and `exit=1`.
`--redact` ensures the value is never printed.

- [ ] **Step 6: Remove the canary and confirm the scan is clean**

```bash
rm ./canary.tfvars /tmp/canary.tfvars
gitleaks detect --no-git --source . --config .gitleaks.toml --redact ; echo "exit=$?"
```

Expected: `exit=0`, no findings.

- [ ] **Step 7: Write the pre-commit configuration**

Create `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.0
    hooks:
      - id: gitleaks
        args: ["--config", ".gitleaks.toml", "--redact"]

  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.104.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
        args: ["--args=--config=__GIT_WORKING_DIR__/.tflint.hcl"]

  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: check-merge-conflict
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-yaml
      - id: detect-private-key
```

> If a `rev` no longer resolves, run `pre-commit autoupdate` and commit the result rather than
> guessing a tag.

- [ ] **Step 8: Write the TFLint configuration**

Create `.tflint.hcl`:

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

- [ ] **Step 9: Install the hooks and TFLint plugins**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
pre-commit install
tflint --init
```

Expected: `pre-commit installed at .git/hooks/pre-commit`, and TFLint reports the AWS plugin installed.

- [ ] **Step 10: Verify the hooks run**

```bash
pre-commit run --all-files
```

Expected: every hook reports `Passed` or `Skipped`. Terraform hooks skip because no `.tf` files
exist yet — that is correct at this point; Task 4 exercises them.

- [ ] **Step 11: Scan the full history of all four repositories**

```bash
for R in ~/Documents/plateng-infra/plateng-infrastructure-tools \
         ~/Documents/plateng-infra/plateng-gitops \
         ~/Documents/dev/weysure/Weysure-API \
         ~/Documents/dev/weysure/Weysure; do
  echo "═══ $(basename $R) ═══"
  gitleaks detect --source "$R" --redact --exit-code 0 --report-format json --report-path "/tmp/gl-$(basename $R).json" 2>&1 | tail -3
  python3 -c "
import json,collections,sys
d=json.load(open('/tmp/gl-$(basename $R).json'))
print(f'  findings: {len(d)}')
for k,v in collections.Counter(x['RuleID'] for x in d).items(): print(f'    {k}: {v}')
" 2>/dev/null || echo "  findings: 0"
done
```

Expected: `plateng-*` report 0. `Weysure-API` reports findings against commit `52f89f2` — that
is Finding ⑯ and Task 3 handles it. Record the counts; do not print values.

- [ ] **Step 12: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add .gitleaks.toml .pre-commit-config.yaml .tflint.hcl
git commit -m "chore(security): add gitleaks, pre-commit and tflint configuration

Secret scanning must be active before Terraform containing a database
password is migrated into this repository.

Adds a custom gitleaks rule for literal password, secret, token and
access_key assignments in .tf and .tfvars files, verified against a canary
that the rule correctly rejects."
```

---

## Task 3: Rotate the secrets exposed in `Weysure-API` git history

Remediates Finding ⑯. Rotation is the only real fix — removing a file from history reduces
future exposure but cannot un-disclose a credential that has already been readable.

**Files:**
- Create: `projects/weysure/docs/runbooks/SECRET_ROTATION.md`
- Modify: `projects/weysure/docs/specs/2026-08-26-weysure-platform-design.md` — findings table

**Interfaces:**
- Consumes: the Gitleaks report from Task 2 Step 11.
- Produces: a rotation runbook reused in Phase 3 and by `SECRETS_ROTATION.md` in Phase 10.

> **These steps are performed by a human in provider consoles.** They cannot be scripted, and
> an agent must not attempt them. An agent's role here is to write the runbook, update the
> findings register, and confirm afterwards that the application still starts.

- [ ] **Step 1: Confirm the exposure and list affected key names**

```bash
cd ~/Documents/dev/weysure/Weysure-API
git show 52f89f2:.env | grep -oE '^[A-Z_]+' | sort -u
```

Expected: `ACCESS_TOKEN_EXPIRE_MINUTES DATABASE_URL EMAILS_FROM_EMAIL EMAILS_FROM_NAME
FRONTEND_URL PROJECT_NAME SECRET_KEY SMTP_HOST SMTP_PASSWORD SMTP_PORT SMTP_TLS SMTP_USER
SUPABASE_ANON_KEY SUPABASE_JWT_SECRET SUPABASE_SERVICE_ROLE_KEY SUPABASE_URL
SUPABASE_WEBHOOK_SECRET`

Never pipe this command's raw output anywhere. `grep -oE '^[A-Z_]+'` prints names only.

- [ ] **Step 2: Write the rotation runbook**

Create `projects/weysure/docs/runbooks/SECRET_ROTATION.md`:

```markdown
# Runbook — Rotating secrets exposed in git history

**Trigger:** a credential is found in git history, a Gitleaks finding is confirmed, or a
credential is suspected compromised.

**Principle:** rotation is the remediation. History rewriting is hygiene. A credential that has
been readable must be treated as disclosed, regardless of who you believe had access.

## Scope — Finding ⑯, commit `52f89f2` in `innocent98/Weysure-API`

| Secret | Where to rotate | Blast radius if not rotated |
|---|---|---|
| `SECRET_KEY` | Application config — generate with `python3 -c "import secrets;print(secrets.token_urlsafe(64))"` | Anyone can forge a JWT for any user |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase dashboard → Project Settings → API → Rotate | Full admin access, bypasses row-level security |
| `SUPABASE_JWT_SECRET` | Supabase dashboard → Project Settings → API | Token forgery |
| `SUPABASE_WEBHOOK_SECRET` | Supabase dashboard → Database → Webhooks | Webhook spoofing |
| `SUPABASE_ANON_KEY` | Rotates with the JWT secret | Public by design — low risk |
| `DATABASE_URL` password | Supabase → Settings → Database → Reset password | Direct database access |
| `SMTP_PASSWORD` | Mail provider console | Outbound mail as your domain |

## Order of operations

1. **Rotate `SECRET_KEY` last.** Changing it invalidates every issued JWT, logging all sessions
   out. Do it during a quiet window. There are no live users at time of writing, so this is free
   today — it will not be later.
2. Rotate Supabase keys first; update `.env` locally; restart the API; confirm health.
3. Rotate SMTP; send one test message.
4. Rotate `SECRET_KEY`; restart; log in again.

## Verification

```bash
cd ~/Documents/dev/weysure/Weysure-API
docker compose up -d && sleep 15
curl -fsS http://localhost:8000/api/v1/health && echo " health OK"
docker compose logs api --tail 30 | grep -iE 'error|traceback' || echo "no errors in startup log"
```

## History rewriting — optional, and second in priority

The repository is private with a single collaborator, so rewriting is hygiene rather than
containment. If performed:

```bash
brew install git-filter-repo
cd ~/Documents/dev/weysure/Weysure-API
git filter-repo --path .env --invert-paths --force
git push --force --all && git push --force --tags
```

**Consequences:** every commit SHA changes; open pull requests close; every existing clone must
be re-cloned. Do not do this while a pull request is open. Do not do it *instead of* rotating.

## Prevention

- Gitleaks pre-commit hook (Task 2) blocks the next occurrence at commit time.
- `.gitignore` already covers `.env` in both application repositories — verified.
- From Phase 3, application secrets live in Vault and reach pods through External Secrets, so
  there is no `.env` to leak.
```

- [ ] **Step 3: Perform the rotation** *(human, in provider consoles)*

Follow the runbook's order of operations. Do not record any new value in git, in this plan, or
in any chat transcript.

- [ ] **Step 4: Verify the application still starts**

```bash
cd ~/Documents/dev/weysure/Weysure-API
docker compose up -d && sleep 15
curl -fsS http://localhost:8000/api/v1/health && echo " health OK"
```

Expected: a successful health response. If it fails, a rotated value was not propagated to
`.env` — fix before continuing.

- [ ] **Step 5: Add the finding to the register**

In `projects/weysure/docs/specs/2026-08-26-weysure-platform-design.md`, append two rows to the
findings table in §2:

```markdown
| ⑮ | **High** | The existing Terraform does not parse. `modules/rds/variables.tf:9` uses a single-line block with two arguments, which HCL rejects. Proves the configuration was never successfully planned. | `terraform fmt -check` | Phase 0 · Task 4 |
| ⑯ | **Critical** | `.env` containing live secrets is in `Weysure-API` history at commit `52f89f2` — `SECRET_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`, `SUPABASE_WEBHOOK_SECRET`, `DATABASE_URL`, `SMTP_PASSWORD`. Removed from `HEAD` in `6b2e901`, still readable in history. | `git show 52f89f2:.env` | Phase 0 · Task 3 |
```

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add projects/weysure/docs/runbooks/SECRET_ROTATION.md projects/weysure/docs/specs
git commit -m "docs(security): add secret rotation runbook and record findings 15 and 16

Finding 16: .env containing SECRET_KEY, Supabase service-role and JWT
secrets, DATABASE_URL and SMTP_PASSWORD is present in Weysure-API history
at commit 52f89f2. Removed from HEAD but still readable in history.

Finding 15: the existing Terraform does not parse; a single-line HCL block
in modules/rds/variables.tf declares two arguments.

Rotation is the remediation; history rewriting is documented as secondary
hygiene, not containment."
```

---

## Task 4: Migrate Terraform into this repository

Resolves Findings ①, ②, ⑪ and ⑮. The legacy configuration at
`~/Documents/plateng-infra/weysure-infrastructure` is not a git repository, contains a plaintext
password, and does not parse.

**Files:**
- Create: `modules/{vpc,eks,rds}/{main,variables,outputs}.tf`
- Create: `projects/weysure/terraform/{versions,variables,main,outputs}.tf`
- Create: `projects/weysure/terraform/terraform.tfvars.example`

**Interfaces:**
- Consumes: Gitleaks and pre-commit from Task 2.
- Produces: module inputs and outputs that Phase 1 extends —
  `module.vpc.{vpc_id, public_subnet_ids, private_subnet_ids}`,
  `module.eks.{cluster_name, cluster_endpoint, cluster_ca, node_role_arn}`,
  `module.rds.{db_endpoint, db_name}`.

- [ ] **Step 1: Prove the source does not parse (the failing test)**

```bash
terraform fmt -check -recursive ~/Documents/plateng-infra/weysure-infrastructure
```

Expected: `Error: Invalid single-argument block definition` at `modules/rds/variables.tf` line 9.

- [ ] **Step 2: Copy the tree, excluding secrets and state**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
SRC=~/Documents/plateng-infra/weysure-infrastructure
mkdir -p modules projects/weysure/terraform
cp -R "$SRC/modules/vpc" "$SRC/modules/eks" "$SRC/modules/rds" modules/
cp "$SRC"/versions.tf "$SRC"/variables.tf "$SRC"/main.tf "$SRC"/outputs.tf projects/weysure/terraform/
find . -name '.DS_Store' -delete
ls -R modules projects/weysure/terraform
```

`terraform.tfvars` is deliberately **not** copied — it holds the plaintext password.

- [ ] **Step 3: Fix the parse error by removing the variable entirely (ADR-010)**

In `modules/rds/variables.tf`, delete this line:

```hcl
variable "db_password"        { type = string  sensitive = true }
```

Add nothing in its place. Under ADR-010 the master password is generated and stored by RDS, so
the variable should not exist.

- [ ] **Step 4: Apply ADR-010 and ⑪ to the RDS module**

In `modules/rds/main.tf`, inside `resource "aws_db_instance" "main"`, replace:

```hcl
  username = var.db_username
  password = var.db_password
```

with:

```hcl
  username                    = var.db_username
  manage_master_user_password = true
```

- [ ] **Step 5: Remove the password plumbing from the root module**

In `projects/weysure/terraform/variables.tf`, delete:

```hcl
variable "db_password" {
  type      = string
  sensitive = true
}
```

In `projects/weysure/terraform/main.tf`, delete this line from the `module "rds"` block:

```hcl
  db_password        = var.db_password
```

- [ ] **Step 6: Set ECR to immutable (Finding ⑪)**

In `projects/weysure/terraform/main.tf`, change:

```hcl
  image_tag_mutability = "MUTABLE"
```

to:

```hcl
  image_tag_mutability = "IMMUTABLE"
```

- [ ] **Step 7: Repoint module sources**

In `projects/weysure/terraform/main.tf`, change all three `source` values:

```hcl
  source = "../../../modules/vpc"
  source = "../../../modules/eks"
  source = "../../../modules/rds"
```

- [ ] **Step 8: Add default tags to the provider**

Cost Explorer can only group by a tag that exists on the resource. `default_tags` applies them
to everything the provider creates, so no individual resource has to remember.

In `projects/weysure/terraform/versions.tf`, replace the `provider "aws"` block with:

```hcl
provider "aws" {
  region  = var.region
  profile = "personal"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "Beyric/plateng-infrastructure-tools"
    }
  }
}
```

The `profile` value changes to `weysure-sso` in Task 7; leave it as `personal` for now so the
configuration stays usable between the two tasks.

- [ ] **Step 9: Write the example tfvars**

Create `projects/weysure/terraform/terraform.tfvars.example`:

```hcl
# Copy to terraform.tfvars and edit. terraform.tfvars is gitignored.
# There is no db_password: RDS generates the master password into AWS
# Secrets Manager (ADR-010), so it never exists in this file or in state.

environment            = "prod"
project                = "weysure"
region                 = "us-east-1"
eks_node_instance_type = "m6i.large"
eks_node_desired       = 1
eks_node_min           = 1
eks_node_max           = 2
db_instance_class      = "db.t4g.micro"
```

- [ ] **Step 10: Verify it now parses and is formatted**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
terraform fmt -recursive .
terraform fmt -check -recursive . && echo "fmt clean"
```

Expected: `fmt clean`, no errors.

- [ ] **Step 11: Verify it validates**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`
`-backend=false` means no S3 access and **no possibility of touching real state**.

- [ ] **Step 12: Verify no secret survived the migration**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
grep -rn 'db_password' . --include='*.tf' --include='*.tfvars*' || echo "no db_password references ✓"
gitleaks detect --no-git --source . --config .gitleaks.toml --redact ; echo "exit=$?"
```

Expected: `no db_password references ✓` and `exit=0`.

- [ ] **Step 13: Run TFLint**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
tflint --recursive --config="$(pwd)/.tflint.hcl"
```

`checkov` is deliberately not run yet: these modules are rewritten wholesale in Phase 1 for
add-ons, IRSA, access entries and Karpenter, so a policy baseline taken now would be discarded.
Phase 1 introduces it against the modules that will actually be applied.

Record every warning. Warnings do not block this task — Phase 1 rewrites these modules for
add-ons, IRSA, access entries and Karpenter — but each must be triaged then.

- [ ] **Step 14: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add modules projects/weysure/terraform
git commit -m "feat(terraform): migrate weysure infrastructure under version control

Moves the previously untracked configuration into this repository with
shared modules in modules/ and the root module in projects/weysure/.

- Fixes the HCL parse error in modules/rds/variables.tf (finding 15): a
  single-line block cannot declare two arguments.
- Removes db_password entirely (findings 1 and 15). RDS now generates the
  master password into AWS Secrets Manager via manage_master_user_password,
  so it never enters tfvars, state or git (ADR-010).
- Sets ECR image_tag_mutability to IMMUTABLE (finding 11).
- Adds terraform.tfvars.example; real tfvars stay gitignored.

terraform validate passes with -backend=false. No state was touched and
nothing was applied."
```

---

## Task 5: Scaffold the GitOps repository

`Beyric/plateng-gitops` is empty. Phase 2 installs Argo CD pointing at it, so the directory
structure must exist first.

**Files (in `~/Documents/plateng-infra/plateng-gitops`):**
- Create: `README.md`, `.gitignore`, `.gitleaks.toml`
- Create: `bootstrap/.gitkeep`, `platform/.gitkeep`
- Create: `projects/weysure/apps/.gitkeep`
- Create: `projects/weysure/environments/{stage,prod}/.gitkeep`

**Interfaces:**
- Produces: the repository paths Phase 2's Argo CD app-of-apps root points at.

- [ ] **Step 1: Confirm the repository is empty**

```bash
cd ~/Documents/plateng-infra/plateng-gitops && git log --oneline 2>&1 | head -2
```

Expected: `fatal: your current branch 'main' does not have any commits yet` or similar.

- [ ] **Step 2: Create the directory skeleton**

```bash
cd ~/Documents/plateng-infra/plateng-gitops
mkdir -p bootstrap platform projects/weysure/apps projects/weysure/environments/stage projects/weysure/environments/prod
for d in bootstrap platform projects/weysure/apps projects/weysure/environments/stage projects/weysure/environments/prod; do touch "$d/.gitkeep"; done
find . -type d -not -path './.git*' | sort
```

- [ ] **Step 3: Write the README**

Create `README.md`:

```markdown
# plateng-gitops

Kubernetes desired state. **Argo CD watches this repository and nothing else.**

## Rules

1. **Never run `kubectl apply` against a managed cluster.** Every change is a commit here.
   `kubectl` is a read-only instrument: `get`, `describe`, `logs`, `k9s`.
2. **This repository is production.** Branch protection and review are not optional.
3. **No secrets, ever.** Secrets live in Vault and reach pods through External Secrets
   Operator. A `kind: Secret` with literal `data` is a defect.
4. **Terraform does not belong here.** Cloud resources live in `plateng-infrastructure-tools`
   behind a human-gated `apply`. Whoever creates a resource must be the only thing that
   changes it — otherwise Terraform and Argo CD reconcile each other's changes forever.

## Layout

```text
bootstrap/                        Argo CD app-of-apps root
platform/                         Shared platform components
projects/
  weysure/
    apps/                         Application definitions
    environments/
      stage/                      Overlays and image tags — stage
      prod/                       Overlays and image tags — prod
```

## Who writes here

| Author | Writes | Why |
|---|---|---|
| Engineers | everything, via pull request | Desired state is reviewed like code |
| Jenkins (CI) | **only** an image tag under `environments/*/` | Its sole handoff; it holds no cluster credentials |

## Rollback

`git revert` the offending commit. Argo CD reconciles to the previous state. There is no
separate rollback tool.
```

- [ ] **Step 4: Add ignore and scanning configuration**

Create `.gitignore`:

```gitignore
.DS_Store
*.swp
.idea/
.vscode/

# Never commit rendered manifests or secrets
*-secret.yaml
*.dec.yaml
kubeconfig
*.kubeconfig
```

Create `.gitleaks.toml`:

```toml
[extend]
useDefault = true

[[rules]]
id = "k8s-literal-secret-data"
description = "A Kubernetes Secret carrying literal data — secrets must come from Vault via ESO"
regex = '''(?s)kind:\s*Secret.{0,400}?^\s*(data|stringData):'''
path = '''\.ya?ml$'''
```

- [ ] **Step 5: Verify the guard rule works**

```bash
cd ~/Documents/plateng-infra/plateng-gitops
cat > /tmp/bad-secret.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: should-be-rejected
stringData:
  token: hunter2hunter2hunter2
YAML
cp /tmp/bad-secret.yaml ./bad-secret.yaml
gitleaks detect --no-git --source . --config .gitleaks.toml --redact -v ; echo "exit=$?"
```

Expected: a `k8s-literal-secret-data` finding and `exit=1`.

- [ ] **Step 6: Remove the canary and confirm clean**

```bash
rm ./bad-secret.yaml /tmp/bad-secret.yaml
gitleaks detect --no-git --source . --config .gitleaks.toml --redact ; echo "exit=$?"
```

Expected: `exit=0`.

- [ ] **Step 7: Commit and push on a branch**

```bash
cd ~/Documents/plateng-infra/plateng-gitops
git checkout -b feature/repository-scaffold
git add -A
git commit -m "chore: scaffold gitops repository structure

Creates the directory layout Argo CD's app-of-apps root will point at in
Phase 2, plus a gitleaks rule rejecting any Kubernetes Secret with literal
data. Secrets reach pods from Vault through External Secrets Operator, so a
literal Secret in this repository is a defect by definition."
git push -u origin feature/repository-scaffold
gh pr create --base main --head feature/repository-scaffold \
  --title "chore: scaffold gitops repository structure" \
  --body "Directory skeleton for Argo CD (Phase 2), README stating the operating rules, and a gitleaks rule that rejects Kubernetes Secrets carrying literal data."
```

> The remote has no `main` branch yet. If the push creates the branch as default, create `main`
> from the first commit and reset the default before opening the pull request:
> ```bash
> SHA=$(git rev-parse feature/repository-scaffold)
> gh api repos/Beyric/plateng-gitops/git/refs -f ref=refs/heads/main -f sha="$SHA"
> gh repo edit Beyric/plateng-gitops --default-branch main
> ```

---

## Task 6: Apply branch protection and ownership to all four repositories

Resolves Finding ⑫. In a GitOps model `plateng-gitops` *is* production; an unprotected default
branch there means anyone who can push can deploy, unreviewed.

**Files:**
- Create: `CODEOWNERS` in `plateng-infrastructure-tools` and `plateng-gitops`
- Create: `docs/conventions/REPOSITORY_STANDARDS.md`

**Interfaces:**
- Produces: the review gate every later phase's pull requests pass through.

- [ ] **Step 1: Confirm no protection exists (the failing test)**

```bash
for R in Beyric/plateng-infrastructure-tools Beyric/plateng-gitops innocent98/Weysure-API innocent98/Weysure; do
  printf '%-42s ' "$R"
  gh api "repos/$R/branches/main" --jq '.protected' 2>/dev/null || echo "no main branch"
done
```

Expected: `false` for each repository that has a `main` branch.

- [ ] **Step 2: Add CODEOWNERS to both platform repositories**

```bash
for R in ~/Documents/plateng-infra/plateng-infrastructure-tools ~/Documents/plateng-infra/plateng-gitops; do
cat > "$R/CODEOWNERS" <<'OWNERS'
# Default owner for everything in this repository.
*                       @innocent98

# Infrastructure and cluster state carry production risk.
/modules/               @innocent98
/projects/              @innocent98
/bootstrap/             @innocent98
/platform/              @innocent98

# Security-relevant configuration.
/.gitleaks.toml         @innocent98
/.pre-commit-config.yaml @innocent98
/CODEOWNERS             @innocent98
OWNERS
done
echo "CODEOWNERS written"
```

- [ ] **Step 3: Apply protection to `plateng-gitops`**

```bash
gh api -X PUT repos/Beyric/plateng-gitops/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
```

> `enforce_admins` is `false` deliberately. As the sole engineer you must be able to merge your
> own pull requests; with it `true` and `required_approving_review_count: 1`, you would lock
> yourself out of your own production repository. Set it to `true` the day a second reviewer
> exists, and record that as a decision.

- [ ] **Step 4: Apply the same protection to the other three**

```bash
for R in Beyric/plateng-infrastructure-tools innocent98/Weysure-API innocent98/Weysure; do
  echo "═══ $R ═══"
  gh api -X PUT "repos/$R/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
done
```

- [ ] **Step 5: Verify protection is active**

```bash
for R in Beyric/plateng-infrastructure-tools Beyric/plateng-gitops innocent98/Weysure-API innocent98/Weysure; do
  printf '%-42s ' "$R"
  gh api "repos/$R/branches/main/protection" \
    --jq '"protected reviews=" + (.required_pull_request_reviews.required_approving_review_count|tostring) + " force_push=" + (.allow_force_pushes.enabled|tostring)' 2>&1
done
```

Expected for each: `protected reviews=1 force_push=false`.

- [ ] **Step 6: Prove a direct push to `main` is now rejected**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git checkout main && git pull --quiet
echo "canary $(date +%s)" >> /tmp/protection-canary.txt
cp /tmp/protection-canary.txt ./protection-canary.txt
git add protection-canary.txt && git commit -q -m "test: verify branch protection rejects direct push"
git push origin main 2>&1 | tail -3
```

Expected: rejected with `protected branch hook declined` or `Changes must be made through a pull request`.

- [ ] **Step 7: Clean up the canary**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git reset --hard origin/main
rm -f ./protection-canary.txt /tmp/protection-canary.txt
git checkout feature/phase-0-foundations
git status --short
```

Expected: clean working tree, back on the feature branch.

- [ ] **Step 8: Document the standard**

Create `docs/conventions/REPOSITORY_STANDARDS.md`:

```markdown
# Repository standards

Applies to every repository under platform engineering governance.

## Branch protection

| Setting | Value | Why |
|---|---|---|
| Required approving reviews | 1 | Nothing reaches a default branch unreviewed |
| Dismiss stale reviews | on | An approval must apply to the code being merged |
| Require code-owner review | on for `plateng-gitops` | That repository is production |
| Allow force pushes | off | History on a default branch is an audit record |
| Allow deletions | off | — |
| Require conversation resolution | on | Review comments cannot be merged past |
| Enforce for admins | **off, for now** | A single engineer must be able to merge their own pull requests. Turn on the day a second reviewer exists. |

## Branch naming

`feature/<description>` · `bugfix/<description>` · `hotfix/<description>`

## Commits

Conventional Commits: `type(scope): subject`. Types: `feat` `fix` `chore` `docs` `refactor`
`test` `perf` `ci`. **No AI co-author trailers.**

## Required files

| File | Repositories |
|---|---|
| `.gitignore` | all |
| `.gitleaks.toml` | all |
| `CODEOWNERS` | platform repositories |
| `.pre-commit-config.yaml` | repositories containing Terraform |
```

- [ ] **Step 9: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add CODEOWNERS docs/conventions/REPOSITORY_STANDARDS.md
git commit -m "chore(governance): add CODEOWNERS and document repository standards

Branch protection applied to all four repositories: one required review,
stale reviews dismissed, force pushes and deletions blocked, conversation
resolution required. Code-owner review additionally required on
plateng-gitops, which is production under GitOps.

enforce_admins is deliberately off while there is a single engineer;
turning it on with a one-review requirement would lock the only maintainer
out of their own production repository. Documented as a revisit trigger.

Resolves finding 12."
```

---

## Task 7: Replace static AWS access keys with IAM Identity Center

Resolves Finding ⑭ and implements ADR-009. Verified prerequisites: the account is **not** in an
AWS Organization (`AWSOrganizationsNotInUseException`), IAM Identity Center has **no instances**,
and `s_user` has **one active access key**, `AKIA<redacted>`, created 2026-06-24.

**Files:**
- Modify: `projects/weysure/terraform/versions.tf` — backend and provider profile

**Interfaces:**
- Produces: an AWS CLI profile named `weysure-sso` that every later phase uses.

> **Steps 2 and 3 are console operations that cannot be scripted**, and Step 2 changes the
> account's organizational structure. Get explicit approval before running it.

- [ ] **Step 1: Confirm the starting state (the failing test)**

```bash
aws sts get-caller-identity --profile personal --query Arn --output text
aws organizations describe-organization --profile personal 2>&1 | tail -1
aws sso-admin list-instances --profile personal --region us-east-1 --query 'Instances' --output text
aws iam list-access-keys --user-name s_user --profile personal \
  --query 'AccessKeyMetadata[].[AccessKeyId,Status]' --output text
```

Expected: an `arn:aws:iam::767397877316:user/s_user` ARN; `AWSOrganizationsNotInUseException`;
empty instance list; `AKIA<redacted>  Active`.

- [ ] **Step 2: Create an AWS Organization** *(state change — requires approval)*

IAM Identity Center requires AWS Organizations. This account is standalone, so the organization
must be created first. It is free, and with a single account it adds no operational overhead.

```bash
aws organizations create-organization --feature-set ALL --profile personal
```

Verify:

```bash
aws organizations describe-organization --profile personal \
  --query 'Organization.{Id:Id,MasterAccount:MasterAccountId,FeatureSet:FeatureSet}'
```

Expected: an organization id, `MasterAccount` `767397877316`, `FeatureSet` `ALL`.

- [ ] **Step 3: Enable IAM Identity Center** *(console only)*

1. Open the AWS console → **IAM Identity Center** → **Enable**.
2. Choose region **`us-east-1`** — it must match ADR-002; the Identity Center instance region
   cannot be changed afterwards.
3. **Users** → **Add user**: username `adebayo`, your email, then **Add user**.
4. **Permission sets** → **Create permission set** → **Predefined** → **AdministratorAccess**.
   Name it `PlatformAdmin`. Set **Session duration to 1 hour** — this is the control that makes
   a leaked credential a 60-minute problem instead of a permanent one.
5. **AWS accounts** → select account `767397877316` → **Assign users or groups** → user
   `adebayo`, permission set `PlatformAdmin` → **Submit**.
6. Copy the **AWS access portal URL** from the dashboard — the next step needs it.

- [ ] **Step 4: Verify Identity Center is live**

```bash
aws sso-admin list-instances --profile personal --region us-east-1 \
  --query 'Instances[].{Arn:InstanceArn,Store:IdentityStoreId}'
```

Expected: one instance. If still empty, enablement did not complete — do not continue.

- [ ] **Step 5: Configure the SSO profile**

```bash
aws configure sso --profile weysure-sso
```

Answer:

| Prompt | Answer |
|---|---|
| SSO session name | `weysure` |
| SSO start URL | the access portal URL from Step 3.6 |
| SSO region | `us-east-1` |
| SSO registration scopes | accept the default (`sso:account:access`) |
| Account / role | account `767397877316`, role `PlatformAdmin` |
| CLI default client Region | `us-east-1` |
| CLI default output format | `json` |

- [ ] **Step 6: Verify the SSO profile authenticates as a role, not a user**

```bash
aws sso login --profile weysure-sso
aws sts get-caller-identity --profile weysure-sso --query Arn --output text
```

Expected: an ARN of the form
`arn:aws:sts::767397877316:assumed-role/AWSReservedSSO_PlatformAdmin_*/adebayo`.
It must contain `assumed-role`, not `user/`.

- [ ] **Step 7: Verify the profile can reach the Terraform state bucket**

```bash
aws s3api head-bucket --bucket victor-terraform-state-2026 --profile weysure-sso && echo "state bucket reachable ✓"
```

Expected: `state bucket reachable ✓`. If this fails, do **not** delete the access key — you would
lose access to your own state.

- [ ] **Step 8: Point Terraform at the SSO profile**

In `projects/weysure/terraform/versions.tf`, change both occurrences of
`profile = "personal"` to `profile = "weysure-sso"` — one in the `backend "s3"` block, one in
the `provider "aws"` block.

Verify:

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform
grep -n 'profile' versions.tf
terraform init -backend=false && terraform validate
```

Expected: both lines read `profile = "weysure-sso"`, and `Success! The configuration is valid.`

- [ ] **Step 9: Deactivate the access key before deleting it**

Deactivate first. If something breaks, reactivation is instant; deletion is irreversible.

```bash
aws iam update-access-key --user-name s_user --access-key-id AKIA<redacted> \
  --status Inactive --profile weysure-sso
aws iam list-access-keys --user-name s_user --profile weysure-sso \
  --query 'AccessKeyMetadata[].[AccessKeyId,Status]' --output text
```

Expected: `AKIA<redacted>  Inactive`.

- [ ] **Step 10: Work normally for at least one full session**

Use `--profile weysure-sso` for every AWS command for the rest of Phase 0. If nothing breaks,
proceed. If something does, reactivate with `--status Active` and investigate.

- [ ] **Step 11: Delete the access key** *(irreversible — requires approval)*

```bash
aws iam delete-access-key --user-name s_user --access-key-id AKIA<redacted> --profile weysure-sso
aws iam list-access-keys --user-name s_user --profile weysure-sso --query 'AccessKeyMetadata' --output text
```

Expected: empty output — no access keys remain.

- [ ] **Step 12: Remove the stale local profile**

```bash
aws configure list-profiles
```

Leave `personal` in place if other projects use it; its key is now deleted, so it is inert.
Note in the commit message which choice you made.

- [ ] **Step 13: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add projects/weysure/terraform/versions.tf
git commit -m "chore(iam): switch terraform to the IAM Identity Center SSO profile

Replaces the static IAM user access key with a 1-hour SSO session assumed
through the PlatformAdmin permission set (ADR-009, finding 14).

AWS Organizations was enabled first, as Identity Center requires it. The
access key AKIA<redacted> was deactivated, verified over a full
working session, then deleted. A leaked credential is now a 60-minute
problem rather than a permanent one."
```

---

## Task 8: Cost guardrails and state-backend hardening

The last thing to exist before Phase 1 spends money.

**Files:**
- Create: `projects/weysure/docs/runbooks/COST_CONTROLS.md`

**Interfaces:**
- Produces: budget alarms that stay in place for the life of the platform.

- [ ] **Step 1: Confirm no budget exists (the failing test)**

```bash
aws budgets describe-budgets --account-id 767397877316 --profile weysure-sso \
  --query 'Budgets[].BudgetName' --output text 2>&1
```

Expected: empty output, or a `NotFound` error.

- [ ] **Step 2: Create the monthly budget with three alert thresholds**

Replace `you@example.com` with your real address in both places.

```bash
cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "weysure-platform-monthly",
  "BudgetLimit": { "Amount": "250", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

cat > /tmp/notifications.json <<'JSON'
[
  {
    "Notification": { "NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 50, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "you@example.com" } ]
  },
  {
    "Notification": { "NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 80, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "you@example.com" } ]
  },
  {
    "Notification": { "NotificationType": "FORECASTED", "ComparisonOperator": "GREATER_THAN", "Threshold": 100, "ThresholdType": "PERCENTAGE" },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "you@example.com" } ]
  }
]
JSON

aws budgets create-budget --account-id 767397877316 \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notifications.json \
  --profile weysure-sso
```

The third alert is **FORECASTED**, not ACTUAL — it fires when AWS projects you will exceed the
limit, which is what gives you time to act rather than a post-mortem.

- [ ] **Step 3: Verify the budget and its alerts**

```bash
aws budgets describe-budgets --account-id 767397877316 --profile weysure-sso \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount}' --output table
aws budgets describe-notifications-for-budget --account-id 767397877316 \
  --budget-name weysure-platform-monthly --profile weysure-sso \
  --query 'Notifications[].{Type:NotificationType,Threshold:Threshold}' --output table
```

Expected: one budget at `250`, and three notifications — ACTUAL 50, ACTUAL 80, FORECASTED 100.

- [ ] **Step 4: Confirm the state bucket is still correctly hardened**

```bash
aws s3api get-bucket-versioning --bucket victor-terraform-state-2026 --profile weysure-sso --query Status --output text
aws s3api get-public-access-block --bucket victor-terraform-state-2026 --profile weysure-sso \
  --query 'PublicAccessBlockConfiguration' --output json
aws s3api get-bucket-encryption --bucket victor-terraform-state-2026 --profile weysure-sso \
  --query 'ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text
```

Expected: `Enabled`; all four public-access settings `true`; an encryption algorithm
(`AES256` or `aws:kms`).

- [ ] **Step 5: Confirm S3 native state locking is available**

Terraform 1.10 introduced `use_lockfile`, which holds the lock as an S3 object and replaces the
old DynamoDB lock table. `versions.tf` already declares it. Confirm the toolchain supports it:

```bash
terraform version | head -1
grep -n 'use_lockfile' ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform/versions.tf
```

Expected: `Terraform v1.15.8` (>= 1.10) and `use_lockfile = true`.

- [ ] **Step 6: Restrict the state bucket to the PlatformAdmin role**

State contains resource identifiers, and — for resources that do not support managed
passwords — occasionally sensitive values. Only the platform role should read it.

```bash
ROLE_ARN=$(aws sts get-caller-identity --profile weysure-sso --query Arn --output text \
  | sed -E 's#assumed-role/([^/]+)/.*#role/\1#; s#sts::#iam::#')
echo "restricting to: $ROLE_ARN"

cat > /tmp/state-bucket-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::victor-terraform-state-2026",
        "arn:aws:s3:::victor-terraform-state-2026/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
JSON

aws s3api put-bucket-policy --bucket victor-terraform-state-2026 \
  --policy file:///tmp/state-bucket-policy.json --profile weysure-sso
aws s3api get-bucket-policy --bucket victor-terraform-state-2026 --profile weysure-sso \
  --query Policy --output text | python3 -m json.tool
```

Expected: the policy echoed back with the `DenyInsecureTransport` statement.

> This policy denies unencrypted transport only. A principal allowlist is **deliberately not**
> added while a single identity exists — an over-tight bucket policy is one of the easiest ways
> to lock yourself out of your own Terraform state, and unlike an IAM policy it cannot be fixed
> from anywhere except the bucket owner. Revisit when a CI principal needs state access.

- [ ] **Step 7: Dry-run the entire chain end to end**

This is the highest-value verification in Phase 0. `terraform plan` creates nothing and costs
nothing, but it exercises the whole path: SSO credentials → S3 backend → state locking → AWS
provider → module resolution. If this works, Phase 1 will not fail on plumbing.

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out=/tmp/phase0-dryrun.tfplan
```

Expected: `Terraform has been successfully initialized`, then a plan summary of the form
`Plan: N to add, 0 to change, 0 to destroy.` — every resource is an *add*, because nothing
exists yet.

- [ ] **Step 8: Confirm the lock was acquired and released**

```bash
aws s3 ls s3://victor-terraform-state-2026/weysure/infrastructure/ --profile weysure-sso
```

Expected: **no `.tflock` object.** A leftover lock file means a previous run was interrupted;
clear it with `terraform force-unlock <LOCK_ID>` before continuing.

- [ ] **Step 9: Discard the plan — nothing is applied in Phase 0**

```bash
rm -f /tmp/phase0-dryrun.tfplan
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git status --short
```

Expected: `terraform.tfvars` does **not** appear — `.gitignore` covers `*.tfvars`. If it does
appear, stop and fix `.gitignore` before committing anything.

- [ ] **Step 10: Document the controls**

Create `projects/weysure/docs/runbooks/COST_CONTROLS.md`:

```markdown
# Runbook — Cost controls

## Budget

| Setting | Value |
|---|---|
| Name | `weysure-platform-monthly` |
| Limit | **$250 USD / month** |
| Alerts | ACTUAL > 50%, ACTUAL > 80%, **FORECASTED > 100%** |

The forecast alert is the important one: it fires when AWS projects an overrun, which leaves
time to act. An actual-spend alert at 100% is a post-mortem.

## Expected steady state

| Item | $/mo |
|---|---|
| EKS control plane | 73 |
| `system` node group — 1 × m6i.large on-demand | 70 |
| Karpenter-provisioned spot | 22–48 |
| NAT Gateway | 33 |
| Network Load Balancer | 18 |
| RDS db.t4g.micro + 20 GB | 14 |
| EBS volumes ~60 GB | 6 |
| ECR + data transfer | 8 |
| Cloudflare | **0** (free plan) |
| **Total** | **240–270** |

## If a budget alert fires

1. **Cost Explorer → Group by Service** — find which service moved.
2. Common causes, in order of likelihood:
   - **NAT Gateway data processing** — a workload pulling large images repeatedly, or egress
     that should be going through the S3 gateway endpoint.
   - **Karpenter provisioned more than expected** — check `kubectl get nodeclaims` and the
     NodePool limits. A pod with an unsatisfiable request can drive continuous provisioning.
   - **EBS volumes orphaned by deleted PVCs** — check for `available` volumes.
   - **A load balancer left behind** by a deleted Service of type LoadBalancer.
3. Check for anything unexpected in another region: `aws ec2 describe-regions` then iterate.

## Levers, cheapest first

| Lever | Saves | Cost of pulling it |
|---|---|---|
| Reduce Karpenter NodePool max | varies | Less burst headroom |
| NAT instance instead of NAT Gateway | ~$29/mo | Self-managed SPOF — see ADR-004 |
| Graviton (`m7g`) instances | ~20% of compute | Requires multi-arch image builds |
| Scale the `system` node group to 0 overnight | ~$35/mo | Cluster is unusable while scaled down |

## Emergency stop

Phase 0–1 only, and only when nothing stateful exists yet:

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform
terraform destroy
```

**Never run this once RDS holds real data.** From Phase 5 onward, take a final snapshot first
and follow `DATABASE_RECOVERY.md`.
```

- [ ] **Step 11: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add projects/weysure/docs/runbooks/COST_CONTROLS.md
git commit -m "chore(cost): add monthly budget with forecast alerting and document controls

Creates the weysure-platform-monthly budget at \$250 with alerts at 50% and
80% actual spend and 100% forecast. The forecast alert is the one that
leaves time to act; an actual-spend alert at 100% is a post-mortem.

Documents expected steady-state cost, a triage order for budget alerts, and
cost levers ranked by what pulling each one actually costs operationally.

Verified the Terraform state bucket retains versioning, full public-access
blocking and default encryption."
```

---

## Task 9: Record the SOP, reconcile the checklist, and open the pull request

Closes the phase. The SOP is the durable record of what shipped — a teammate or a future
session should understand Phase 0 from it alone, without reading the diff.

**Files:**
- Create: `projects/weysure/docs/sop/2026-08-26-phase-0-foundations.md`
- Modify: `projects/weysure/docs/checklist/BUILD_CHECKLIST.md`

**Interfaces:**
- Consumes: the verified outcome of Tasks 1–8.
- Produces: the merged `main` that Phase 1 branches from.

- [ ] **Step 1: Re-run every exit check in one pass**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
echo "── terraform ──";  terraform fmt -check -recursive . && echo "fmt clean"
( cd projects/weysure/terraform && terraform validate )
echo "── secrets ──";    gitleaks detect --no-git --source . --config .gitleaks.toml --redact; echo "gitleaks exit=$?"
grep -rn 'db_password' . --include='*.tf' --include='*.tfvars*' || echo "no db_password ✓"
echo "── ecr ──";        grep -n 'image_tag_mutability' projects/weysure/terraform/main.tf
echo "── identity ──";   aws sts get-caller-identity --profile weysure-sso --query Arn --output text
aws iam list-access-keys --user-name s_user --profile weysure-sso --query 'AccessKeyMetadata' --output text
echo "── budget ──";     aws budgets describe-budgets --account-id 767397877316 --profile weysure-sso --query 'Budgets[].BudgetName' --output text
echo "── protection ──"
for R2 in Beyric/plateng-infrastructure-tools Beyric/plateng-gitops innocent98/Weysure-API innocent98/Weysure; do
  printf '%-42s ' "$R2"; gh api "repos/$R2/branches/main/protection" --jq '.required_pull_request_reviews.required_approving_review_count' 2>&1
done
```

Expected: `fmt clean`; `Success! The configuration is valid.`; `gitleaks exit=0`;
`no db_password ✓`; `IMMUTABLE`; an ARN containing `assumed-role`; **empty** access-key output;
`weysure-platform-monthly`; and `1` for all four repositories.

- [ ] **Step 2: Write the SOP**

Create `projects/weysure/docs/sop/2026-08-26-phase-0-foundations.md`:

```markdown
# SOP — Phase 0: Foundations & Guardrails

**Shipped:** 2026-08-26 · **Spend:** $0 · **Plan:** [`../plans/2026-08-26-phase-0-foundations.md`](../plans/2026-08-26-phase-0-foundations.md)

## What shipped

Every repository, credential and piece of infrastructure code placed under governance before
any AWS resource exists.

## Why

Read-only investigation found a plaintext database password in untracked Terraform, that
Terraform failing to parse at all, live secrets in application git history, no branch
protection anywhere, and AWS accessed through a permanent IAM user access key. Building on
that foundation would have compounded each problem.

## How

| Area | Change | Finding closed |
|---|---|---|
| Phase ordering | Argo CD moved to Phase 2, Vault to Phase 3, ingress to Phase 4 — matching the bootstrap diagram; manual bootstrap secrets reduced from three to one | ADR-014 |
| Secret scanning | Gitleaks + pre-commit + TFLint, with custom rules proven against canaries | prevention |
| Exposed secrets | Rotated everything in `Weysure-API` commit `52f89f2` | ⑯ |
| Terraform | Migrated under version control; parse error fixed; `db_password` deleted in favour of `manage_master_user_password`; ECR set to `IMMUTABLE`; provider `default_tags` added | ①, ②, ⑪, ⑮ |
| GitOps repo | Scaffolded, with a rule rejecting Kubernetes Secrets carrying literal data | prerequisite for Phase 2 |
| Governance | Branch protection and `CODEOWNERS` on all four repositories | ⑫ |
| AWS identity | AWS Organization created, IAM Identity Center enabled, 1-hour `PlatformAdmin` sessions, static access key deleted | ⑭ |
| Cost | $250 budget with 50% / 80% actual and 100% forecast alerts | prevention |

## Key decisions

- **`db_password` was deleted, not secured.** `random_password` would still have written the
  plaintext into Terraform state. `manage_master_user_password` means the value never exists
  anywhere Terraform can read.
- **`enforce_admins` left off.** With one engineer and a one-review requirement, enabling it
  would lock the only maintainer out of their own production repository. Recorded as a revisit
  trigger, not an oversight.
- **The state bucket policy denies insecure transport only.** A principal allowlist is the
  easiest way to lose access to your own state, and unlike an IAM policy it cannot be repaired
  from elsewhere.
- **Rotation preferred over history rewriting.** A credential that has been readable must be
  treated as disclosed. Rewriting is documented as secondary hygiene.

## Verification

`terraform validate` passes · `gitleaks detect` exits 0 · no `db_password` in any file · direct
push to `main` proven rejected · `sts get-caller-identity` returns an assumed role · zero access
keys remain · budget active with three alerts · `terraform plan` dry-run completed and discarded
· all 10 Mermaid diagrams render.

## Roll back

Nothing was applied, so there is nothing to destroy. To reverse individual controls: branch
protection via `gh api -X DELETE repos/<owner>/<repo>/branches/main/protection`; the access key
cannot be restored — issue a new one from the IAM console if SSO ever becomes unusable.

## Follow-ups

- `checkov` policy baseline — deferred to Phase 1, against the modules that will actually be applied.
- `enforce_admins` — enable when a second reviewer exists.
- State bucket principal allowlist — add when a CI principal needs state access.
- Optional history rewrite of `Weysure-API` — only after rotation, and never with a pull request open.
```

- [ ] **Step 3: Reconcile the build checklist**

In `projects/weysure/docs/checklist/BUILD_CHECKLIST.md`, tick every completed Phase 0 item,
change the Phase 0 heading marker from 🔵 to ✅, and update the snapshot table:

```markdown
| ✅ Complete | 1 / 11 phases |
| 🔵 In progress | 1 — Phase 1 (network & cluster) |
| ⚪ Planned | 9 |
| ❓ Blocking questions | 0 |
| 💰 Current AWS spend | **$0** — nothing applied |
```

Add to the deferred follow-ups table:

```markdown
| checkov policy baseline | Modules are rewritten in Phase 1 | Phase 1 | — |
| `enforce_admins` on branch protection | Single engineer would be locked out | Second reviewer joins | — |
```

- [ ] **Step 4: Verify the checklist is honest**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
python3 - <<'PY2'
import re, pathlib
p0 = pathlib.Path("projects/weysure/docs/checklist/BUILD_CHECKLIST.md").read_text().split("## Phase 0")[1].split("## Phase 1")[0]
done = len(re.findall(r'- \[x\]', p0)); todo = len(re.findall(r'- \[ \]', p0))
print(f"Phase 0: {done} complete, {todo} outstanding")
print("READY TO MERGE" if todo == 0 else "NOT READY — outstanding items above")
PY2
```

Expected: `0 outstanding` and `READY TO MERGE`. An unticked item means the phase is not done —
do not tick it to make this pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git add projects/weysure/docs/sop projects/weysure/docs/checklist
git commit -m "docs(platform): record phase 0 SOP and reconcile the build checklist

Phase 0 complete. Closes findings 1, 2, 11, 12, 14, 15 and 16. AWS spend
for the phase: \$0 — nothing was applied."
```

- [ ] **Step 6: Push and open the pull request**

The body is passed through a quoted heredoc (`<<'BODY'`), so nothing inside it needs escaping —
backticks and dollar signs are taken literally.

```bash
cd ~/Documents/plateng-infra/plateng-infrastructure-tools
git push -u origin feature/phase-0-foundations

gh pr create --base main --head feature/phase-0-foundations \
  --title "Phase 0: foundations and guardrails" \
  --body "$(cat <<'BODY'
Puts every repository, credential and piece of infrastructure code under governance before any
AWS resource is created. **AWS spend: $0 — nothing applied.**

## Closes

| Finding | Resolution |
|---|---|
| (1) Plaintext `db_password` | Variable deleted; RDS generates the master password into Secrets Manager (ADR-010) |
| (2) Terraform untracked | Migrated into `modules/` and `projects/weysure/terraform/` |
| (11) Mutable ECR tags | Set to `IMMUTABLE` |
| (12) No branch protection | Applied to all four repositories, proven by a rejected direct push |
| (14) Static access keys | Replaced by 1-hour IAM Identity Center sessions; key deleted |
| (15) Terraform does not parse | Single-line HCL block declaring two arguments, fixed by deletion |
| (16) Secrets in git history | Rotated; rotation runbook written |

## Also

- **ADR-014** reorders phases so Argo CD and Vault precede ingress, reducing hand-created
  bootstrap secrets from three to one.
- Gitleaks, pre-commit and TFLint configured, each custom rule verified against a canary.
- `plateng-gitops` scaffolded, with a rule rejecting Kubernetes Secrets carrying literal data.
- $250 monthly budget: 50% and 80% actual, 100% forecast.
- Provider `default_tags` so Cost Explorer can group by project from the first resource.

## Verification

- `terraform validate` passes
- `gitleaks detect` exits 0; no `db_password` in any file
- Direct push to `main` proven rejected
- `sts get-caller-identity` returns an assumed role, not a user
- Zero access keys remain on `s_user`
- `terraform plan` dry-run completed against the real backend, lock acquired and released, plan discarded
- 10/10 Mermaid diagrams render
BODY
)"
```

- [ ] **Step 7: Merge after review**

```bash
gh pr merge --repo Beyric/plateng-infrastructure-tools --rebase --delete-branch
```

Do not merge your own pull request without reading the diff. The review gate exists to catch
what the author cannot see.

---

## Phase 0 exit criteria

Every item verified, not assumed.

- [ ] Phase ordering consistent between spec, checklist, blueprint and diagram 7; ADR-014 recorded
- [ ] All 10 Mermaid diagrams still render (`mmdc`, 10/10)
- [ ] `gitleaks`, `pre-commit`, `tflint` installed; hooks active; canary rules proven to fire
- [ ] Full-history scan run on all four repositories, findings recorded
- [ ] Secrets from Finding ⑯ rotated; application verified healthy afterwards
- [ ] Terraform under version control, `terraform validate` passing, **no `db_password` anywhere**
- [ ] ECR set to `IMMUTABLE`
- [ ] `plateng-gitops` scaffolded with a literal-Secret guard rule
- [ ] Branch protection active on all four repositories; direct push to `main` proven rejected
- [ ] `CODEOWNERS` present on both platform repositories
- [ ] AWS Organization created; IAM Identity Center live; `weysure-sso` profile assuming a role
- [ ] Access key `AKIA<redacted>` deleted
- [ ] Budget `weysure-platform-monthly` active with three alerts
- [ ] Provider `default_tags` applied; Cost Explorer can group by `Project`
- [ ] `terraform plan` dry-run completed against the real backend, lock acquired and released, plan discarded
- [ ] State bucket denies insecure transport
- [ ] SOP written; build checklist reconciled with zero outstanding Phase 0 items
- [ ] **AWS spend for the phase: $0**

## Well-Architected delta for Phase 0

| Pillar | Improved by | Still open |
|---|---|---|
| **Operational Excellence** | Infrastructure under version control and review; conventions documented; two runbooks written | No observability until Phase 9 |
| **Security** | Static access keys replaced by 1-hour SSO sessions; leaked secrets rotated; secret scanning blocks the next occurrence; no `db_password` in code or state; branch protection everywhere | Two documented bootstrap secrets remain, by design |
| **Reliability** | Terraform now actually parses and validates — it previously could not have been applied at all | Everything else awaits Phase 1 |
| **Cost Optimization** | Budget with forecast alerting exists before the first dollar is spent | Karpenter tuning deferred to Phase 10 |
