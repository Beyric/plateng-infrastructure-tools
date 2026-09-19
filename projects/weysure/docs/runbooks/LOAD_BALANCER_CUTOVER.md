# Runbook — moving traffic to a new load balancer

**Rule (Finding ㊵): DNS never follows a load balancer whose targets are not `healthy`.**

1. Create the new LB beside the old one (new Service, or a controller change that leaves the old LB
   in place). Do **not** let external-dns see the new hostname yet: set
   `external-dns.alpha.kubernetes.io/exclude: "true"` … or run external-dns with `--policy=upsert-only`
   and keep the record pinned by annotation on the old Service.
2. Wait for targets:
   ```bash
   aws elbv2 describe-target-health --target-group-arn <new-tg> --query 'TargetHealthDescriptions[].TargetHealth.State'
   ```
   All `healthy` (NLB: ~2–3 min after registration).
3. Test the new LB directly, bypassing DNS:
   ```bash
   curl -sk --resolve weysure-api.beyrictech.com:443:<new-lb-ip> https://weysure-api.beyrictech.com/api/v1/health
   ```
4. Flip DNS (remove the exclusion). With Cloudflare proxied records the edge switches at once.
5. Probe for 10 min (1 req/s, `curl` user-agent — Cloudflare 403s the Python UA).
6. Keep the old LB ≥ 24 h. Before deleting, confirm its `NewFlowCount` is scanner-level noise and no
   Service/Ingress references its hostname. Delete LB → target groups → leftover SG rules
   (`kubernetes.io/rule/nlb/client=<old-lb>`).
