# SOP — Phase 3: Secrets

**Shipped:** 2026-09-02 · **PRs:** infra #6, #7 · gitops #2, #3 · **Cost delta:** ~$1/mo (KMS key)

## What shipped

There is no standing database password anywhere in this platform, and no secret in git.

| Component | Delivered by | Verified |
|---|---|---|
| **Vault** 1.20.4, Raft, KMS auto-unseal | Argo CD | `Sealed: false` with no human input |
| **External Secrets Operator** | Argo CD | `SecretSynced` / `Ready=True` |
| **Reloader** | Argo CD | Running |
| **ClusterSecretStore** | Argo CD | End-to-end sync proven |
| KMS key, S3 snapshot bucket, pod identity | Terraform | Applied |

## Auto-unseal is the load-bearing decision

Vault boots **sealed** — its storage is encrypted with a master key Vault itself cannot read
until unsealed. Without auto-unseal, every restart requires a human entering 3-of-5 Shamir
shares, which turns any pod eviction, node replacement or spot reclaim into a manual outage.

With `seal "awskms"`, Vault asks KMS to decrypt its master key at startup and unseals itself.
Proven twice today, on two different clusters, with nobody typing anything.

The pod reaches KMS through an **EKS Pod Identity association** — namespace `vault`,
ServiceAccount `vault` — with a policy granting four KMS actions on one key and three S3
actions on one bucket. Not `kms:*`. No access keys exist.

## The one-time gate

`vault operator init` runs exactly once and prints recovery keys and a root token that are
never recoverable. The sequence used, with no gap between generating and storing:

1. `init -format=json` redirected straight to a `umask 077` file
2. Immediately written to AWS Secrets Manager at `platform/vault/recovery-keys`
3. **Verified retrievable** before the local copy was shredded with `rm -P`
4. Break-glass admin created via `userpass`, 1h TTL / 8h max
5. **Admin login proven working**, then the root token revoked

**Ordering matters and generalises to every credential rotation:** create the replacement,
prove the replacement works, only then destroy the original. Reversing the last two is how
people lock themselves out of production, and it is tempting because revoking feels like the
secure thing to do first.

Root is revocable safely because it is regenerable — `vault operator generate-root` mints a new
one from 3-of-5 recovery keys. The recovery keys, not the root token, are the real break-glass.
A token with `ttl: 0` never expires, which means a leaked copy stays valid forever.

## Multi-tenancy — one Vault, many products

Vault is **cluster-wide infrastructure**, not per-product. A second product does not get a
second Vault; isolation happens inside:

| Layer | Weysure | Luran |
|---|---|---|
| KV path | `secret/weysure/*` | `secret/luran/*` |
| Policy | `weysure-read` | `luran-read` |
| Kubernetes auth role | bound to Weysure's ServiceAccounts and namespaces | bound to Luran's |

A pod outside the bound ServiceAccount/namespace pair cannot authenticate at all; one inside it
still cannot read a path its policy omits.

**KV v2 has two path prefixes**, and a policy granting only `secret/weysure/*` silently fails.
Data lives at `secret/data/*` and metadata at `secret/metadata/*`; both need granting.

## ClusterSecretStore over SecretStore

Declared once instead of duplicated into every namespace. Not a weakening: authorisation lives
in Vault, where the Kubernetes auth role binds specific ServiceAccounts to specific policies.
Referencing the store does not grant anything.

## Verification

| Test | Result |
|---|---|
| Auto-unseal | `Sealed: false`, `Seal Type: awskms`, no human input — twice, two clusters |
| Recovery keys stored | 5 keys + root token in Secrets Manager, retrieval verified |
| **Keys belong to *this* Vault** | Stored root token authenticated live — `policies: ['root']` |
| Break-glass admin | `policies: ['admin','default']`, `ttl: 3600` |
| Root revoked | confirmed |
| Vault → ESO → Secret | `SecretSynced`, value read back correctly through the git-managed store |

Checking the stored token actually authenticated to the running Vault mattered: `keys: 5,
root: True` looks identical whether the keys belong to this Vault or a destroyed one. The
cluster had been rebuilt between init runs, so both versions existed in Secrets Manager.

## Follow-ups

| Item | Where |
|---|---|
| `ec2nodeclass.yaml` hardcodes the Karpenter node role, whose random suffix changes on every rebuild | Set a stable `node_iam_role_name` in Terraform |
| Raft snapshot CronJob to S3 not yet deployed — bucket and IAM exist | Phase 4 |
| **Snapshot restore drill never performed** | Phase 10 — a backup never restored is not a backup |
| Vault has no ingress; access is `kubectl exec` | Phase 4 |
