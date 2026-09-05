# External Secrets — the shape every ExternalSecret takes

**Default: `dataFrom.extract`.** Every key at the Vault path lands in the Kubernetes
Secret under its Vault name. Consumers — chart values, JCasC `${…}` references,
`secretKeyRef` — use those names directly. The secret store never learns a chart's naming.

```yaml
spec:
  secretStoreRef: { name: vault, kind: ClusterSecretStore }
  target: { name: jenkins-platform, creationPolicy: Owner }
  dataFrom:
    - extract: { key: platform/jenkins }   # comment the keys the consumer relies on
```

## Two guardrails — these are what make it safe, not merely convenient

**1. One Vault path serves one consumer.** `extract` is allow-by-default: a key added to a
path reaches every Secret extracted from it. Two ExternalSecrets reading the same path is a
smell — collapse them, or split the path. Never share a path between unrelated workloads.

**2. `envFrom` only on app-owned paths.** `envFrom` turns every key into an environment
variable. That is exactly right for an application's own path (`secret/weysure/app` is
that app's env contract) and exactly wrong for anything shared.

## When `data[]` is still correct

- The consumer must see a **subset** of a path that legitimately has more keys.
- A key must be **renamed** and the consumer cannot be told the Vault name.

Both should be rare. If you reach for `data[]`, ask whether the Vault path is scoped wrong.

## The failure mode to know

With `data[]`, deleting a Vault key makes the ExternalSecret report `SecretSyncedError` —
loud. With `extract`, the key silently disappears from the Secret and the pod fails on its
*next restart*. Reloader closes most of the gap by restarting on change so it fails now, not
later; Phase 9 alerts on `ExternalSecret` `Ready=False`. Still: **deleting a key from Vault
is a change to a running workload.** Treat it like one.

## Naming

Vault path → Secret name, kept legible: `platform/jenkins` → `jenkins-platform`,
`platform/github-app` → `jenkins-github-app` (prefixed by the consumer when the path name
alone is ambiguous in-cluster).
