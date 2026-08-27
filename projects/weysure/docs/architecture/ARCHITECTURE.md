# Weysure Platform — Architecture

> **Status:** Design (pre-implementation). No AWS resources exist yet.
> **Last updated:** 2026-08-26
> **Companion documents:** [Design spec](../specs/2026-08-26-weysure-platform-design.md) · [Build checklist](../checklist/BUILD_CHECKLIST.md) · [Decision records](../../memory/DECISIONS.md)

All diagrams are Mermaid, rendered natively by GitHub. They are the **source of truth for
intent**. When implementation diverges from a diagram, the diagram is updated in the same
pull request — a diagram that lies is worse than no diagram.

## Contents

| # | Diagram | Answers |
|---|---|---|
| [1](#1-target-state) | Target state | What are we building, end to end? |
| [2](#2-aws-network-topology) | AWS network topology | Where does everything physically sit? |
| [3](#3-cicd-flow) | CI/CD flow | How does code become a running pod? |
| [4](#4-repository--gitops-topology) | Repository & GitOps topology | Which repo owns what? |
| [5](#5-identity-layers) | Identity layers | Who is allowed to do what? |
| [6](#6-secrets-flow) | Secrets flow | How does a credential reach a pod? |
| [7](#7-bootstrap-ordering) | Bootstrap ordering | What must exist before what? |
| [8](#8-request-path) | Request path | How does a user's request reach the app? |
| [9](#9-database-migration-path) | Database migration | How do we get off Supabase? |
| [10](#10-failure-modes--blast-radius) | Failure modes | What breaks, and what does it take with it? |

---

## 1. Target state

The complete platform. Components in **dashed** boxes are deliberately deferred — see
[Deferred scope](#deferred-scope).

```mermaid
flowchart TB
    DEV["Developer"] -->|"git push"| GH["GitHub<br/>4 repositories"]
    GH --> JEN["Jenkins — CI only"]

    subgraph CIGATES["CI quality gates"]
        direction LR
        GL["Gitleaks<br/>secret scanning"]
        SQ["SonarQube<br/>self-hosted in-cluster"]
        TST["pytest / vitest<br/>+ coverage"]
        TRV["Trivy<br/>image CVE scan"]
    end

    JEN --> CIGATES
    CIGATES --> BLD["Docker build<br/>tag = git SHA"]
    BLD --> ECR[("Amazon ECR<br/>IMMUTABLE tags")]
    BLD -->|"commit new tag"| GOPS["plateng-gitops<br/>desired state"]

    GOPS --> ARGO["Argo CD — CD only"]

    subgraph EKS["Amazon EKS cluster — us-east-1"]
        ARGO
        subgraph PLATFORM["Platform namespaces"]
            KARP["Karpenter<br/>node autoprovisioner"]
            TRAEFIK["Traefik<br/>ingress"]
            CM["cert-manager<br/>TLS"]
            EDNS["external-dns"]
            VAULT["Vault<br/>secrets"]
            ESO["External Secrets<br/>Operator"]
            REL["Reloader"]
            KYV["Kyverno<br/>policy"]
            LNK["Linkerd — deferred"]:::deferred
        end
        subgraph OBS["Observability"]
            PROM["Prometheus"]
            GRAF["Grafana"]
            AM["Alertmanager"]
            BB["Blackbox exporter"]
        end
        subgraph APPNS["Application namespaces"]
            API["weysure-api<br/>FastAPI"]
            WEB["weysure-web<br/>Next.js"]
            REDIS["Redis"]
        end
    end

    ARGO -->|"reconciles"| PLATFORM
    ARGO -->|"reconciles"| APPNS
    ARGO -->|"reconciles"| OBS
    KARP -->|"provisions nodes<br/>on pending pods"| EKS
    ECR -.->|"image pull"| APPNS

    RDS[("Amazon RDS<br/>PostgreSQL")]
    KMS["AWS KMS"]
    ASM["AWS Secrets Manager"]
    CFDNS["Cloudflare DNS<br/>beyrictech.com"]
    CFCDN["Cloudflare CDN + WAF<br/>free tier · Lagos PoP"]

    API --> REDIS
    VAULT -->|"issues 1h creds"| API
    VAULT <-->|"creates / revokes users"| RDS
    API --> RDS
    KMS -->|"auto-unseal"| VAULT
    ASM -.->|"break-glass"| VAULT
    EDNS --> CFDNS
    CM -->|"DNS-01 challenge"| CFDNS

    USER["Users — West Africa"] --> CFCDN --> NLB["Network<br/>Load Balancer"] --> TRAEFIK
    TRAEFIK --> API
    TRAEFIK --> WEB

    BB --> PROM
    API -->|"/metrics"| PROM
    PROM --> GRAF
    PROM --> AM

    classDef deferred stroke-dasharray: 5 5,opacity:0.55
```

### Deferred scope

| Component | Why deferred | Revisit trigger |
|---|---|---|
| **Linkerd** | ~50m CPU / ~50 MiB sidecar on *every* pod ≈ 40% of the on-demand node | Node capacity increase, or first service-to-service traffic worth encrypting |
| **CloudFront** | Superseded — Cloudflare's free plan gives an equal or better edge at zero cost | Only if leaving Cloudflare |
| **Multi-AZ NAT** | +$33/mo | Budget increase, or first AZ-related incident |
| **Multi-AZ RDS** | Doubles instance cost | First paying-customer SLA |
| **Second cluster** | +$73/mo control plane + nodes | First time stage causes a prod incident |

---

## 2. AWS network topology

```mermaid
flowchart TB
    IGW["Internet Gateway"]

    subgraph VPC["VPC · 10.0.0.0/16 · us-east-1"]
        subgraph AZA["Availability Zone us-east-1a"]
            PUBA["Public subnet<br/>10.0.1.0/24<br/>kubernetes.io/role/elb"]
            PRIA["Private subnet<br/>10.0.3.0/24<br/>role/internal-elb"]
            NAT["NAT Gateway<br/>single point of failure"]
            NODE1["system node group<br/>1-2x m6i.large ON-DEMAND<br/>Karpenter · CoreDNS · Vault<br/>Argo CD · Traefik"]
        end
        subgraph AZB["Availability Zone us-east-1b"]
            PUBB["Public subnet<br/>10.0.2.0/24"]
            PRIB["Private subnet<br/>10.0.4.0/24"]
            NODE2["Karpenter-provisioned nodes<br/>spot-first · consolidating<br/>apps · SonarQube · Prometheus<br/>Jenkins agents"]
        end
        NLB["Network Load Balancer<br/>public subnets"]
        RDS[("RDS PostgreSQL<br/>db.t4g.micro · single-AZ<br/>publicly_accessible = false")]
        S3EP["S3 Gateway Endpoint<br/>free — bypasses NAT<br/>for ECR layer pulls"]
    end

    IGW --> PUBA
    IGW --> PUBB
    PUBA --> NLB
    PUBB --> NLB
    NLB --> NODE1
    NLB --> NODE2
    PUBA --> NAT
    PRIA -->|"0.0.0.0/0"| NAT
    PRIB -->|"0.0.0.0/0"| NAT
    NAT --> IGW
    NODE1 -.->|"resides in"| PRIA
    NODE2 -.->|"resides in"| PRIB
    NODE1 --> RDS
    NODE2 --> RDS
    NODE1 --> S3EP
    NODE2 --> S3EP
```

**Design notes**

- Worker nodes live **only in private subnets**. Nothing in the cluster is directly
  internet-reachable; ingress is exclusively via the NLB in public subnets.
- The RDS security group permits `5432` **only from the VPC CIDR**, and
  `publicly_accessible = false`.
- The **S3 Gateway Endpoint is free** and removes NAT data-processing charges for ECR layer
  pulls, which are the dominant NAT traffic in a Kubernetes cluster.
- **Both private subnets route through one NAT Gateway in `us-east-1a`.** An AZ-a failure
  removes egress for AZ-b nodes too. Accepted, documented, and on the revisit list.

---

## 3. CI/CD flow

The single most important property: **Jenkins holds no cluster credentials.** Its entire
relationship with the cluster is one git commit.

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant GH as GitHub (app repo)
    participant J as Jenkins (CI)
    participant ECR as Amazon ECR
    participant G as plateng-gitops
    participant A as Argo CD
    participant K as EKS cluster

    Dev->>GH: push to feature branch, open PR
    GH->>J: webhook
    J->>J: Gitleaks — secret scan
    J->>J: SonarQube — quality gate
    J->>J: pytest / vitest + coverage
    J->>J: docker build (tag = git SHA)
    J->>J: Trivy — image CVE scan
    J->>ECR: push image:git-sha (IRSA, no static keys)
    J->>G: commit image tag to environments/env/
    Note over J,G: This commit is the ONLY handoff.<br/>Jenkins has no kubeconfig.
    A->>G: poll / webhook — detects new commit
    A->>K: apply manifests
    K->>ECR: image pull
    A-->>Dev: sync status and health
```

**Rollback is `git revert` on `plateng-gitops`.** Argo CD reconciles back to the previous
image tag. There is no separate rollback tool and no judgement call.

---

## 4. Repository & GitOps topology

```mermaid
flowchart TB
    subgraph SRC["Source repositories — developers push here"]
        API["innocent98/Weysure-API<br/>FastAPI · Dockerfile · Jenkinsfile<br/>default: main"]
        WEB["innocent98/Weysure<br/>Next.js · Dockerfile · Jenkinsfile<br/>default: main"]
    end

    subgraph IAC["Infrastructure repository — Terraform"]
        INFRA["Beyric/plateng-infrastructure-tools<br/>projects/weysure/<br/>VPC · EKS · RDS · ECR · IAM · KMS · Route53"]
    end

    subgraph GOPS["GitOps repository — desired cluster state"]
        BOOT["bootstrap/ — app-of-apps root"]
        PLAT["platform/ — Traefik · Vault · ESO<br/>cert-manager · Kyverno · Prometheus"]
        APPS["apps/ — weysure-api · weysure-web"]
        ENVS["environments/stage/ · environments/prod/<br/>image tags live here"]
    end

    JEN["Jenkins — CI only"]
    ECRR[("ECR")]
    ARGO["Argo CD — CD only"]
    EKS["EKS cluster"]

    API --> JEN
    WEB --> JEN
    JEN -->|"image:git-sha"| ECRR
    JEN -->|"tag commit — GitHub App, scoped"| ENVS
    INFRA -->|"terraform apply — human-gated"| EKS
    BOOT --> PLAT
    BOOT --> APPS
    APPS --> ENVS
    GOPS -->|"watches + reconciles"| ARGO
    ARGO -->|"applies"| EKS
    ECRR -.->|"image pull"| EKS
```

### Why four repositories

The rule everything follows from: **the repository Argo CD watches must not be the
repository developers push application code to.** If they are the same repo:

1. CI commits an image tag, which triggers CI, which commits again. Infinite loop.
2. Every application commit becomes a potential production deploy.
3. You lose the audit distinction between *built* and *deployed* — the exact question asked
   during an incident.

**Terraform is deliberately not watched by Argo CD.** Argo CD reconciles Kubernetes objects;
cloud resources stay in Terraform behind a human-gated `apply`. Blurring that line invites
"Argo CD deleted our RDS instance."

### Multi-project layout

Both platform repos are named `plateng-*` rather than `weysure-*`, so `weysure` is a scoped
subtree and a second product drops in without restructuring:

```text
plateng-infrastructure-tools/          plateng-gitops/
├── modules/            (shared)       ├── bootstrap/
│   ├── vpc/                           ├── platform/         (shared)
│   ├── eks/                           └── projects/
│   └── rds/                               └── weysure/
└── projects/                                  ├── apps/
    └── weysure/                               └── environments/
        ├── main.tf                                ├── stage/
        └── terraform.tfvars                       └── prod/
```

---

## 5. Identity layers

Secrets management without identity is just a nicer place to keep the same static
credential. Identity is designed first.

```mermaid
flowchart TB
    subgraph L1["Layer 1 · Human to AWS"]
        YOU["Engineer"] -->|"IAM Identity Center SSO<br/>MFA · 1-hour session"| ROLE["IAM role<br/>PlatformAdmin"]
    end

    subgraph L2["Layer 2 · Human to Cluster"]
        ROLE -->|"aws_eks_access_entry<br/>declared in Terraform"| KADM["Kubernetes cluster-admin"]
    end

    subgraph L3["Layer 3 · Pod to AWS — IRSA"]
        OIDC["EKS OIDC provider"]
        OIDC --> SA1["vault SA<br/>KMS decrypt · S3 snapshots"]
        OIDC --> SA2["external-dns SA<br/>Route53 record writes"]
        OIDC --> SA3["cert-manager SA<br/>Route53 DNS-01"]
        OIDC --> SA4["ebs-csi SA<br/>EC2 volume ops"]
        OIDC --> SA5["jenkins SA<br/>ECR push"]
        OIDC --> SA6["cluster-autoscaler SA<br/>ASG scaling"]
    end

    subgraph L4["Layer 4 · Pod to Vault"]
        ESOSA["external-secrets SA"] -->|"Kubernetes auth method<br/>token reviewer"| VPOL["Vault policy eso-read<br/>least privilege"]
    end
```

**Application pods hold no AWS identity.** They receive database credentials from Vault, not
from AWS, so there is nothing for them to assume and nothing to leak.

**Jenkins pushes to ECR via IRSA** — no AWS access keys exist anywhere in the pipeline.

---

## 6. Secrets flow

```mermaid
flowchart LR
    KMS["AWS KMS key"] -->|"auto-unseal via IRSA"| VAULT
    VAULT["Vault<br/>Raft storage, in-cluster"]
    VAULT -->|"KV v2 — static secrets"| ESO
    VAULT -->|"database engine<br/>1-hour Postgres user"| ESO
    ESO["External Secrets Operator"] -->|"creates + refreshes"| KSEC["Kubernetes Secret"]
    KSEC -->|"envFrom"| POD["weysure-api pod"]
    KSEC -.->|"change detected"| RELOAD["Reloader"]
    RELOAD -->|"rolling restart"| POD
    ASM["AWS Secrets Manager"] -.->|"break-glass:<br/>Vault recovery keys<br/>RDS master password"| VAULT
    VAULT <-->|"CREATE USER VALID UNTIL, then REVOKE"| RDS[("RDS PostgreSQL")]
    POD --> RDS
```

### Secrets inventory

| Class | Keys | Home | Lifetime |
|---|---|---|---|
| **Dynamic** | Postgres username + password | Vault database engine | **1 hour**, auto-revoked |
| **Static app** | `SECRET_KEY`, `PAYSTACK_*`, `CLOUDINARY_*`, `SMTP_*`, webhook secrets | Vault KV v2 | scheduled rotation |
| **Platform** | GitHub App private key, Argo CD admin, Grafana admin | Vault KV v2 | scheduled rotation |
| **Break-glass** | Vault recovery keys, RDS master password | AWS Secrets Manager | never stored in Vault |
| **Not secret** | `PROJECT_NAME`, `API_V1_STR`, `ENVIRONMENT`, `BACKEND_CORS_ORIGINS`, `WEB_CONCURRENCY`, reconciliation intervals | ConfigMap, in git | reviewable in PRs |

Roughly a third of the current `.env` is **not secret**. Moving it to a ConfigMap makes it
diffable in pull requests and removes it from the blast radius. Treating an entire `.env` as
one opaque secret is the most common secrets-management mistake.

### Why External Secrets Operator rather than Vault Secrets Operator

`ExternalSecret` manifests describe *what secret is wanted*, not *where it lives*. Swapping
Vault for AWS Secrets Manager later changes **one** `SecretStore` resource; every application
manifest is untouched. VSO couples every manifest to Vault.

### Why Vault rather than AWS Secrets Manager alone

The deciding factor is **dynamic database credentials**, which Secrets Manager cannot
provide. Vault's database engine means there is **no standing database password** for the
application — not in git, not in Terraform state, not in a Kubernetes Secret, not in an
environment variable that outlives an hour.

---

## 7. Bootstrap ordering

Every secrets system has a bootstrap secret. The question is never *"can we eliminate it?"*
but *"how few are there, who knows they exist, and are they written down?"*

```mermaid
flowchart TB
    T["1. Terraform<br/>VPC · EKS · add-ons · IRSA · KMS<br/>ECR · RDS · Route53 · IAM"]
    B["2. Manual bootstrap — once, documented<br/>helm install argo-cd<br/>+ 1 hand-created GitHub credential"]
    A["3. Argo CD adopts itself<br/>and installs all platform components"]
    V["4. Vault deployed, initialised once by a human<br/>recovery keys to AWS Secrets Manager<br/>root token revoked immediately"]
    C["5. Vault configured<br/>policies · k8s auth · database engine"]
    E["6. ESO deployed<br/>reads Vault, writes Kubernetes Secrets"]
    APP["7. Applications deployed"]
    T --> B --> A --> V --> C --> E --> APP

    style B stroke-dasharray: 5 5
    style V stroke-dasharray: 5 5
```

**Two manual gates, both deliberate:**

| Gate | Why it cannot be automated | Mitigation |
|---|---|---|
| 2 — Argo CD's git credential | Vault is installed *by* Argo CD | Documented runbook; **rotated immediately** once Vault is live |
| 4 — Vault initialisation | Vault cannot store its own recovery keys | Recovery keys to AWS Secrets Manager; root token revoked after break-glass admin exists |

---

## 8. Request path

```mermaid
flowchart LR
    U["User — Lagos"] -->|"HTTPS"| CFE["Cloudflare edge<br/>Lagos PoP · TLS terminates here<br/>CDN · WAF · DDoS"]
    CFE -->|"Full (strict) TLS<br/>to origin"| NLB["Network Load Balancer<br/>us-east-1"]
    NLB --> TR["Traefik IngressRoute"]
    TR -->|"weysure.beyrictech.com"| WEB["weysure-web<br/>Next.js"]
    TR -->|"weysure-api.beyrictech.com"| API["weysure-api<br/>FastAPI"]
    API --> REDIS[("Redis<br/>rate limit + cache")]
    API --> RDS[("RDS PostgreSQL")]
    CM["cert-manager"] -.->|"Let's Encrypt cert<br/>via Cloudflare DNS-01"| TR
    EDNS["external-dns"] -.->|"creates + updates records"| CFDNS["Cloudflare DNS"]
    CFDNS -.->|"resolves, proxied"| CFE
```

### DNS and domain

| Item | Value |
|---|---|
| Apex domain | `beyrictech.com` |
| Registrar | Namecheap |
| Authoritative DNS | **Cloudflare** (nameservers delegated from Namecheap) |
| Production frontend | `weysure.beyrictech.com` |
| Production API | `weysure-api.beyrictech.com` |
| Staging frontend | `weysure-stage.beyrictech.com` |
| Staging API | `weysure-api-stage.beyrictech.com` |

**Route 53 is not used.** Because DNS is delegated to Cloudflare, both `external-dns` and
`cert-manager` use the Cloudflare provider with a scoped API token (stored in Vault), rather
than Route 53 with IRSA. This removes one IRSA role and the hosted-zone charge.

### Latency mitigation for `us-east-1`

`us-east-1` is roughly 140–180 ms from Lagos versus roughly 95 ms from Frankfurt
([ADR-002](../../memory/DECISIONS.md)). Cloudflare's free plan mitigates this **better than
CloudFront would, at zero cost** ([ADR-011](../../memory/DECISIONS.md)):

- **TLS terminates at Cloudflare's Lagos PoP**, so the expensive handshake never crosses the
  Atlantic. The remaining hop travels Cloudflare's backbone rather than the public internet.
- **Static assets cached at the edge** — most of a Next.js page load never reaches AWS.
- **The NLB is never exposed publicly**; its security group admits only Cloudflare's published
  IP ranges. This is a security gain, not only a performance one.
- **Redis for hot reads** keeps escrow and wallet flows off unnecessary round trips.

Origin TLS uses Cloudflare **Full (strict)** mode against a real Let's Encrypt certificate
issued by cert-manager — not Flexible, which would leave the AWS-side leg unencrypted.

---

## 9. Database migration path

The application currently runs on Supabase Postgres in `eu-central-1`. Investigation
confirmed this is a **pure data migration** — authentication is already self-hosted
(`passlib` bcrypt in `app/core/security.py`, `hashed_password` on the local `users` table).

```mermaid
flowchart TB
    subgraph NOW["Current state"]
        APP1["weysure-api"] -->|"DATABASE_URL"| SUPA[("Supabase Postgres<br/>aws-0-eu-central-1.pooler")]
    end

    subgraph STEPS["Migration — rehearsed before executed"]
        S1["1. Schema parity check<br/>alembic heads vs live DB"]
        S2["2. pg_dump from Supabase<br/>schema + data, --no-owner"]
        S3["3. pg_restore into RDS<br/>rehearsal run, non-prod"]
        S4["4. Row-count + checksum verification per table"]
        S5["5. Application smoke test against RDS"]
        S6["6. Maintenance window<br/>freeze writes, final dump, restore, verify"]
        S7["7. Flip DATABASE_URL to Vault-issued creds"]
        S8["8. Observe; keep Supabase read-only for rollback"]
        S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7 --> S8
    end

    subgraph TARGET["Target state"]
        APP2["weysure-api"] -->|"1-hour creds from Vault"| RDS[("RDS PostgreSQL<br/>us-east-1, private subnet")]
    end

    NOW --> STEPS --> TARGET
```

**Why a maintenance window rather than logical replication:** source and target are in
different regions (`eu-central-1` to `us-east-1`), so cross-region logical replication would
run over the public internet — fragile, and hard to reason about under load.

**Rollback:** Supabase is left intact and read-only until the new database has been observed
healthy through a full business cycle. Reverting is a `DATABASE_URL` change.

### Residual Supabase coupling to remove

| Location | Issue | Status |
|---|---|---|
| `app/core/supabase.py` | Entire module — never imported anywhere (`grep 'from app.core.supabase'` returns 0 files) | Dead; delete |
| `app/services/user_service.py:45` | Filters on `User.supabase_id`, a column dropped by migration `9090aa00a81c` | Broken; delete |
| `app/services/user_service.py:96` | Calls `supabase_client`, which is not imported in that file | Broken; delete |
| `app/api/v1/endpoints/admin.py:176` | `_get_supabase().auth.admin.delete_user(...)` — **1 residual live call site**, passing a local ID to an API that no longer knows these users | Broken; delete |
| `pyproject.toml` / `requirements.txt` | `supabase==2.15.2` dependency | Remove after the above |

---

## 10. Failure modes & blast radius

Accepted weaknesses, stated plainly. A Well-Architected review that finds nothing is a review
that was not done.

```mermaid
flowchart TB
    F1["us-east-1a fails"] --> I1["NAT Gateway lost.<br/>All private-subnet egress dies,<br/>including healthy AZ-b nodes.<br/>Image pulls and outbound API calls fail."]
    F2["Spot reclaim — 2-minute notice"] --> I2["Karpenter drains via SQS interruption queue<br/>and provisions a replacement.<br/>Prometheus loses in-flight scrapes."]
    F8["system node group lost"] --> I8["Karpenter itself is down, so no new<br/>nodes are provisioned until the managed<br/>node group replaces the node (~3-5 min).<br/>Existing nodes keep running."]
    F3["Bad Kyverno policy"] --> I3["Both namespaces affected —<br/>stage and prod share one cluster."]
    F4["RDS instance failure"] --> I4["Single-AZ: restore from PITR.<br/>RPO approx 5 min · RTO approx 20 min."]
    F5["Vault sealed or down"] --> I5["No new secrets issued.<br/>Running pods keep current creds<br/>until the 1-hour TTL expires."]
    F6["Argo CD down"] --> I6["No new deployments.<br/>Running workloads unaffected."]
    F7["Jenkins compromised"] --> I7["Attacker can push images and commit tags,<br/>but has no cluster credentials.<br/>Branch protection and review gate the blast."]
```

| Failure | Mitigation in place | Accepted gap | Revisit trigger |
|---|---|---|---|
| AZ-a outage | Nodes span 2 AZs | **Single NAT = shared egress SPOF** | Budget increase, or first AZ incident |
| Spot reclaim | Karpenter SQS interruption handling, PDBs, on-demand system node group | Prometheus scrape gaps | Node capacity increase |
| **Karpenter unavailable** | Managed node group replaces the system node automatically; running nodes unaffected | ~3–5 min with no new node provisioning | Second system node (min_size = 2) |
| Cluster-wide policy error | Separate Argo CD projects, ResourceQuota, NetworkPolicy | **stage and prod share a cluster** | First stage-caused prod incident |
| RDS failure | Automated backups + PITR, **restore rehearsed** | Single-AZ | First paying-customer SLA |
| Vault outage | KMS auto-unseal removes the manual-unseal outage class | Single replica | Node capacity increase to 3-replica Raft HA |
| Argo CD outage | Stateless; workloads keep running | — | — |
| CI compromise | **Zero cluster credentials**, IRSA-scoped ECR push, branch protection | — | — |
