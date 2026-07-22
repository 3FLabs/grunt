# grunt documentation

In-repo wiki for the grunt contract suite. The top-level [README](../README.md) covers the repository structure and a high-level architecture view; these pages go deeper, one page per module.

## Pages

| Page | Contents |
|------|----------|
| [Architecture](architecture.md) | Roles across contracts, deployment wiring, intent state transitions, access-control reference, factory pattern, security mechanisms |
| [Facility](facility.md) | Intent structure and lifecycle, LP operations, facilitator operations |
| [Request](request.md) | PT/YT dual-token model, redemption formula, funding methods, nonce management |
| [Funds](funds.md) | Order state machine and the USCC, Centrifuge, Pareto, and Midas integrations |
| [Position Manager](position-manager.md) | Share accounting, deposit/withdraw/burn flows, rebalancing, fee mechanism |
| [Borrow](borrow.md) | MorphoBorrowPosition, custom LLTV, proportional pre-liquidation, liquidation offers |
| [Retargetter](retargetter.md) | LTV retargetting orchestration and the quoter math derivations |
| [Transfer Guard](transfer-guard.md) | Token modes, address statuses, collateral allowlist delegation |
| [Deployment & Operations](deployment.md) | Factory pattern, post-deployment wiring checklists, upgrade cautions |
| [Known Issues & Assumptions](known-issues.md) | Accepted risks, unsupported cases, and operating assumptions from the audits |

## Conventions

- NatSpec in the contracts stays short and states the local constraint; when a behavior traces back to an accepted audit finding or a documented limitation, the code points here (for example `See docs/known-issues.md`).
- [Known Issues & Assumptions](known-issues.md) is the registry of every accepted risk and unsupported case, organized by module, each entry referencing the audit report that raised it.
- Formula derivations (quoter sizing, fee accrual) live on the module pages so the code keeps only the resulting formula and rounding rationale.
