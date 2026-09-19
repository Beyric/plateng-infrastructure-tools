# SOP — Phase 8: Policy, cost and edge

**Shipped:** 2026-09-16 → 2026-09-19 · **PRs:** infra #25 (spec), #26, #27 · gitops #28–#33 ·
**Cost delta:** −$28/mo (Graviton) −$16/mo (legacy NLB); run-rate **≈ $12.5–13.8/day ≈ $385/mo**
(was $24.9/day before the EKS upgrade) · Spec:
[2026-09-16-phase-8-policy-cost-edge](../specs/2026-09-16-phase-8-policy-cost-edge.md)

**Open:** Kyverno `Enforce` for `weysure-prod` — scheduled 2026-09-23 after the audit window.

## What shipped

| Area | Change | Where | Proof |
|---|---|---|---|
| Edge | **AWS Load Balancer Controller 3.5.0** owns the Traefik NLB: pod-IP targets, `/ping:8080` health check, 30 s deregistration, pod readiness gates | infra `lbc.tf` (IAM + pod identity) · gitops `bootstrap/apps/aws-load-balancer-controller.yaml`, `traefik.yaml` | full system-node drain (Vault, Argo controller, CoreDNS, Kyverno moved): **0 non-200** at 1 req/s — was 5–9 failures per node roll |
| Edge | Legacy in-tree NLB, its 2 target groups and its two `0.0.0.0/0` NodePort SG rules deleted after 72 h clean | CLI (Adebayo, 2026-09-19) | one NLB left, targets healthy, 40/40 probe |
| Cost | System nodes **2× m7g.large (Graviton, arm64)**, blue/green: new group → cordon/drain x86 → remove x86 group | infra `main.tf` `system_arm` | every platform image verified multi-arch first; 33 platform pods on arm64 |
| Cost | `upgradePolicy` stays `EXTENDED`; alert 60 days before 2027-08-02 → Phase 9 | decision D3 | — |
| Resilience | Redis `karpenter.sh/do-not-disrupt` (a PDB would block drains at one replica) | gitops `redis.yaml` | — |
| Policy | **Kyverno 3.9.1**, 8 baseline ClusterPolicies in **Audit**; exceptions enabled and honoured only in `weysure-prod` | gitops `bootstrap/apps/kyverno*.yaml`, `platform/kyverno/` | `weysure-prod`: **183 pass · 6 skip · 0 fail** |
| Policy | Redis hardened to the chart baseline (seccomp, no escalation, read-only rootfs, drop ALL); `PolicyException` for the completed `db-grants-v2` Job | gitops `redis.yaml`, `kyverno-exception-db-grants-v2.yaml` | proven locally on `redis:8.2-alpine`; AOF survives restart |
| Network | VPC CNI network-policy mode; six allow policies then `default-deny` (ingress+egress) in `weysure-prod` | infra `main.tf` addon config · gitops `network/` | from an api pod: RDS, Redis, Vault, Paystack, Cloudinary, DNS ok; api→web:3000 blocked; 125 probe pairs, 0 failures through the sync |
| Quotas | `ResourceQuota` (4 CPU / 8 Gi requests) + `LimitRange` defaults | gitops `quota.yaml` | — |

Platform namespaces stay in Audit by design: `kube-system` alone has 164 audit fails from AWS's own
add-ons, which legitimately need host access.

## Findings

**㊵ — DNS must not follow a new load balancer before its targets are healthy.** The LBC attached
the new NLB to the Service; external-dns repointed Cloudflare the same second; NLB targets sit in
`initial` for ~2–3 min → **2 min 20 s of HTTP 530** on every host. The legacy NLB was healthy the
whole time. Rule (runbook `LOAD_BALANCER_CUTOVER.md`): freeze the DNS record on the old LB
(`external-dns.alpha.kubernetes.io/hostname` on a holding Service, or `--policy=upsert-only` plus a
manual flip) until `describe-target-health` shows `healthy`.

**㊶ — Five expired database leases Vault cannot revoke.** Issued 4–11 Sept by Phase 5 proofs and
the re-running `db-bootstrap` (Finding ㉝) under the old revocation SQL (`REASSIGN OWNED … TO vault`),
which most likely hits the PostgreSQL 16 membership rule (Finding ㉜) — unconfirmed, Vault's recent
log shows no attempt. Passwords are past `VALID UNTIL`; risk is low. Fix queued: one-shot Job drops
the orphan `v-…` roles as master, then `vault lease revoke -force` for the five lease ids.

**Also learned**
- An LBC health-check port is a *Service* port name or a number; Traefik's `/ping` is on container
  port 8080, which the Service does not expose → numeric port.
- Readiness gates are injected at pod creation; existing pods need one rolling restart.
- Kyverno rejected a `foreach`+`deny` policy silently at install (7 of 8 policies appeared) — check
  `kubectl get clusterpolicy` count after every policy change. `PolicyException` is **off by default**;
  the API server only warns.
- Kyverno's CRDs show `OutOfSync` in Argo CD without `ServerSideDiff=true,IncludeMutationWebhook=true`.
- The eks module follows the newest AMI release: any `terraform apply` can roll the system nodes.
  Pin `ami_release_version` (Phase 10).
- 24-hour Vault credential rotation verified on `api-scheduler` (renders 16, 17, 18 Sept ≈ every
  24 h, container restarts cleanly). API pods rarely reach 24 h on spot; each replacement mints a
  fresh credential. One unexplained extra render 18 min after the 18 Sept rotation — Phase 9.
- `kubectl delete pod` is not covered by a PDB; only the Eviction API is (`drain`, Karpenter, EKS).

## Deferred

- Kyverno **Enforce** in `weysure-prod` (2026-09-23). · Stale-lease cleanup (Finding ㊶).
- Savings Plan — after Phase 9 shows steady state. · `ami_release_version` pin.
- `aws-load-balancer-controller` and `root` Argo apps show cosmetic `OutOfSync` (webhook cert
  secret regenerated by the chart on every render) — `ignoreDifferences`, Phase 10 hygiene.
- Traefik and other platform charts lack requests/limits (visible in Kyverno audit).
- Developer **PR A — private uploads** not yet pushed (public Cloudinary URLs, `overwrite=True`,
  KYC on local disk). Blocks real KYC traffic, not the platform.

## Verification

`aws elbv2 describe-load-balancers` → only `k8s-traefik-…` · `describe-target-health` → pod IPs
healthy · `kubectl get nodes -L kubernetes.io/arch` → system nodes `arm64` · `kubectl get
networkpolicy -n weysure-prod` → 7 · `kubectl get policyreport -n weysure-prod` → 0 fail ·
`kubectl get pods -n traefik -o jsonpath='{..readinessGates}'` → `target-health.elbv2.k8s.aws/…` ·
all four hosts 200.

## Rollback

LBC: revert gitops #29/#30 → the in-tree controller recreates an NLB (the legacy one is deleted;
expect a DNS move — apply Finding ㊵). Graviton: re-add the `system` group from git history, drain
arm64. NetworkPolicy: revert #32 (deny) first; allows are harmless. Kyverno: policies are Audit;
delete the `kyverno-policies` app to remove them. Redis: revert #33.

## Well-Architected delta

Reliability ↑ (readiness-gated pod targets, zero-blip drains) · Security ↑ (default-deny, admission
baseline, no open NodePorts) · Cost ↓ ($44/mo) · Sustainability ↑ (arm64) · Operational excellence ↑
(policy reports as a standing audit) · Performance ↔ (one network hop fewer at the edge).
