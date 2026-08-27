# Human-gated commands

**Standing rule: Adebayo runs every `aws`, `terraform`, `kubectl`, `helm` and `argocd`
command that changes state — plus anything else that mutates a running system.**

An assistant or agent prepares the command — exact text, working directory, expected output,
and what to check afterwards — and then stops. It does not run it.

The line is drawn by **what builds fluency**, not only by what is dangerous. Adebayo is already
fluent in git and ordinary shell work, so an agent runs those directly rather than narrating
them. The cloud and cluster toolchains are the ones being learned, and you do not learn a
command by watching someone else type it.

| Toolchain | Who runs it | Why |
|---|---|---|
| `git`, shell (`ls`, `grep`, `sed`, `find`, `mv`) | **Agent** | Already fluent; narrating these is friction, not teaching |
| `aws`, `terraform`, `kubectl`, `helm`, `argocd` — **mutating** | **Adebayo** | Being learned, and mistakes cost real money or real uptime |
| `aws`, `terraform`, `kubectl`, `helm` — **read-only** | Agent | Investigation should be fast; nothing is at risk |

An agent still never force-pushes, never rewrites shared history, and never deletes a branch
it did not create.

## Always human-run

| Command | Why |
|---|---|
| `terraform apply` · `terraform destroy` | Creates, changes or deletes real infrastructure and real money |
| `terraform state mv` · `rm` · `push` · `force-unlock` | Direct state surgery; a mistake orphans or destroys resources |
| `kubectl apply` · `delete` · `patch` · `scale` · `drain` | Mutates a live cluster |
| `helm install` · `upgrade` · `uninstall` | Same, via a chart |
| `argocd app sync` · `rollback` | Triggers a deployment |
| `aws` commands that create, modify or delete | Anything not a `describe`/`list`/`get` |
| `psql` DDL or DML against a real database | `DROP`, `TRUNCATE`, `UPDATE`, `DELETE`, migrations |
| `git push --force` · branch deletion on a shared branch | Rewrites shared history |
| `docker push` to a shared registry | Publishes an artifact others consume |

## An agent may run

Read-only investigation, and local work that cannot affect a running system:

`terraform plan` · `terraform validate` · `terraform fmt` · `tflint` · `gitleaks detect` ·
`kubectl get` / `describe` / `logs` / `top` · `helm template` / `diff` · `aws describe-*` /
`list-*` / `get-*` · local file edits · local commits on a feature branch · `git push` to a
feature branch.

> `terraform plan` is read-only in effect but does acquire a state lock. If a plan is
> interrupted, the lock can persist — clearing it with `force-unlock` is human-run.

## How a command is handed over

Every handover states four things. A command without them is not ready to run.

1. **Where** — the exact working directory
2. **What** — the command, in its own fenced block, one command per block
3. **Expect** — what success looks like, specifically enough to recognise failure
4. **If it goes wrong** — the rollback or the next diagnostic step

### Example

**Where:** `~/Documents/plateng-infra/plateng-infrastructure-tools/projects/weysure/terraform`

```bash
terraform apply tfplan
```

**Expect:** `Apply complete! Resources: 24 added, 0 changed, 0 destroyed.` The count must match
the plan you reviewed. A different number means the plan went stale — re-plan, do not proceed.

**If it goes wrong:** the error names the failing resource. Terraform is transactional per
resource, not per run: resources created before the failure still exist and are in state. Fix
the cause and re-apply — do not destroy and start over unless the failure is in the first few
resources.
