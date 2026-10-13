# SOP — NLB admits only Cloudflare; old `weysure-postgres` deleted

**Shipped:** 2026-10-13 00:24:20 UTC (gitops [#69](https://github.com/Beyric/plateng-gitops/pull/69), merge `d83cabd`) and
2026-10-13 ~00:26 UTC (RDS deletion, run by Adebayo) · **Kind:** gitops values change + one-off AWS cleanup · no app,
image or migration change · **Cost delta:** old instance gone (it was stopped, so storage only: 20 GB gp, ~$2/mo);
one 20 GB manual snapshot kept

**Status: both live and verified.**

## 1. NLB security group restricted to Cloudflare

### What shipped

| | Before | After |
|---|---|---|
| Traefik Service `spec.loadBalancerSourceRanges` | unset | Cloudflare's 15 IPv4 ranges |
| NLB frontend SG `sg-050fd1bc2cea74824` (`k8s-traefik-traefik-db590c0a93`) | 80/443 from `0.0.0.0/0` | 80/443 from the 15 ranges only (30 rules) |
| Direct request to the NLB hostname | `https` 200, `http` 301 | both time out (`000`) |
| Through Cloudflare (`weysure`, `weysure-api …/api/v1/health`) | 200 | 200 |

### Why

Found 2026-10-12 ~21:00 UTC while tracing client IPs: the origin answered requests that never touched Cloudflare, so the WAF,
Cloudflare rate limiting and Access could all be skipped by calling the NLB hostname. The design (ADR-011, checklist Phase 4)
always said Cloudflare-only; it was never built, and the ClusterIssuer comment claimed it was.

### How (key decisions)

- **`loadBalancerSourceRanges` on the Service, not a hand-edited SG.** The AWS Load Balancer Controller (v3.5.0) owns the
  frontend SG and rewrites it from this field; a console edit would be reverted at the next reconcile.
- **Chart 41.4.0 has no top-level value for it** — set through the `service.spec` passthrough; confirmed with `helm template`
  (15 ranges on the `LoadBalancer` Service) before merging.
- **Same list as `forwardedHeaders.trustedIPs`** (checked by script, fetched from `cloudflare.com/ips-v4` on 2026-10-13).
  One list decides who may connect, the other whose `X-Forwarded-For` Traefik believes; the file comment says keep them in step.
- **IPv4 only**: the NLB is `ipv4`, so Cloudflare's IPv6 ranges do not apply.
- Safe because every public host is Cloudflare-proxied (checked 10-12), cert-manager uses DNS-01, and Blackbox `external`
  probes go through Cloudflare. In-cluster callers of public hostnames resolve to Cloudflare, not the NLB.
- **Order of SG changes:** the controller authorised the 30 new rules, then revoked `0.0.0.0/0` (same second, 00:24:20) — no
  window where Cloudflare was blocked.

### Files

- `plateng-gitops/bootstrap/apps/traefik.yaml` — `service.spec.loadBalancerSourceRanges`
- `plateng-gitops/platform/cert-manager/clusterissuers.yaml` — comment points at the setting

### Verification (2026-10-13 00:24–00:26 UTC)

Read-only script (session scratchpad `verify-nlb.sh`; commands below) run before and after:

```bash
aws ec2 describe-security-groups --group-ids sg-050fd1bc2cea74824 \
  --query 'SecurityGroups[0].IpPermissions[].{port:FromPort,n:length(IpRanges),open:contains(IpRanges[].CidrIp,`0.0.0.0/0`)}'
curl -sk -o /dev/null -w '%{http_code}\n' -m 8 https://k8s-traefik-traefik-1b6c471b42-26334752ea7a5cd9.elb.us-east-1.amazonaws.com/
```

Before: 1 rule per port, `open=True`, direct https 200. After: 15 per port, `open=False`, direct `000`, both sites 200,
Argo `traefik` Synced/Healthy, controller log `successfully deployed model` with no errors.

### Roll back

Revert gitops #69. The controller restores `0.0.0.0/0` at the next reconcile (~seconds after Argo syncs).

### Operate

- Cloudflare changes its ranges rarely; if it does, update **both** lists in `traefik.yaml`.
- A new public host must be Cloudflare-proxied (orange cloud). A grey-cloud host pointing at the NLB will time out by design.

## 2. Old `weysure-postgres` deleted

| | |
|---|---|
| Instance | `weysure-postgres` (db.t4g.micro, us-east-1a, 20 GB, encrypted), replaced by `-v2` on 2026-10-08 ([SOP](2026-10-08-database-recovery.md)); out of Terraform state since infra #53 |
| Final snapshot | **`weysure-postgres-final-2026-10-13`** — `available`, 100 %, created 2026-10-13 00:26:19 UTC, encrypted |
| Commands (Adebayo) | `aws rds modify-db-instance … --no-deletion-protection --apply-immediately`, then `aws rds delete-db-instance … --final-db-snapshot-identifier weysure-postgres-final-2026-10-13` |
| Verified | `describe-db-instances` → `DBInstanceNotFound`; `-v2` `available`, deletion protection on |

Its automated backups were removed with it; the final snapshot is the only copy. Restore (if ever needed):
`aws rds restore-db-instance-from-db-snapshot --db-snapshot-identifier weysure-postgres-final-2026-10-13 …`.

## Follow-ups

- Developers: read `CF-Connecting-IP` only when the peer is in `10.0.0.0/16` — reply `weysure/docs/platform-reply-2026-10-12-client-ip.md`
  can be sent now. Checklist "Traefik honours `CF-Connecting-IP`" stays open until that app change ships.
- Optional: NLB `preserve_client_ip` / proxy protocol so Traefik access logs see Cloudflare IPs instead of the NLB.
- Decide whether to keep the final snapshot long-term (~$0.10/GB-month storage beyond the free backup allowance) or delete it after launch.
