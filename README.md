# plateng-infrastructure-tools

Platform engineering infrastructure — Terraform, architecture documentation, decision
records, runbooks, and the master build checklist.

Scoped for multiple products. Shared Terraform modules live in `modules/`; per-product
configuration lives under `projects/<product>/`.

## Status

**Design phase.** No AWS resources have been created. Current spend: **$0**.
Projected steady state: **$240–270/mo**.

Each product gets its own subtree under `projects/`, carrying its own spec, architecture
diagrams, decision records, runbooks and build checklist. Terraform modules in `modules/` are
shared; product-specific configuration lives in `projects/<product>/`.

## Layout

```text
.
├── modules/                 # Reusable Terraform modules (vpc, eks, rds, …)
├── docs/
│   └── conventions/         # Cross-project platform conventions
└── projects/
    └── weysure/             # Everything scoped to one product
        ├── docs/
        │   ├── architecture/  # Mermaid diagrams — source of truth for intent
        │   ├── specs/         # Design specs (pre-work)
        │   ├── sop/           # Standard operating procedures (post-ship record)
        │   ├── runbooks/      # Incident and operational procedures
        │   └── checklist/     # Master build checklist
        └── memory/
            └── DECISIONS.md   # Architecture decision records
```

## Start here

| Document | Purpose |
|---|---|
| [Architecture](projects/weysure/docs/architecture/ARCHITECTURE.md) | 10 diagrams — target state, network, CI/CD, identity, secrets, failure modes |
| [Design spec](projects/weysure/docs/specs/2026-08-26-weysure-platform-design.md) | Full design, findings, phase plan, Well-Architected review |
| [Build checklist](projects/weysure/docs/checklist/BUILD_CHECKLIST.md) | What is done, in progress, and ahead |
| [Decision records](projects/weysure/memory/DECISIONS.md) | Why each choice was made, and when to revisit it |

## Working agreement

- Every phase runs `brainstorm → plan → spec → implement`.
- No `terraform apply`, cluster mutation, or production deploy without explicit approval.
- Read-only investigation first; evidence before assertions.
- Diagrams are updated in the same pull request as the change they describe.
- Every phase produces an SOP, a diagram update, and a rehearsed rollback.
