# Deployment & Operations

How the contracts are deployed, wired together, and upgraded. The beacon proxy pattern itself is described in [Architecture](architecture.md#deployment-and-upgrades).

## Factories

Every factory follows the same shape: its constructor deploys one `UpgradeableBeacon` per proxied contract kind (owned by the address the constructor receives), and its `create*` function deploys a beacon proxy, initializes it, and emits a creation event. Some factories (USCCFundFactory and the request, position-manager, borrow-position, and transfer-guard factories) additionally record the deployment in an on-chain registry with an `is*()` view; the Centrifuge, Pareto, and Midas fund factories rely on the event alone. Upgrades never go through the factory: the beacon owner points the beacon at a new implementation and every proxy follows atomically. The registries are append-only monitoring aids, not on-chain provenance checks (see [Known Issues](known-issues.md#trust-model)).

The Facility itself is the one major contract not behind a factory: it is a transparent upgradeable proxy that must be deployed and initialized atomically (`upgradeAndCall`), or its `initialize()` can be front-run.

## Post-Deployment Wiring

Deploying a proxy is never the whole job; each kind has wiring that only works if done in order.

**Funds (USCC, Centrifuge, Pareto, Midas).** After `createFund`, the WrappedAsset owner must grant the new fund `ISSUER_ROLE` on the wrapper, or the fund cannot mint shares. Multiple funds for the same underlying share one WrappedAsset. The Facility gets `DEPOSITOR_ROLE` on the fund.

**MidasFund** additionally needs: the fund and its WrappedAsset greenlisted with Midas when the vault greenlist is enabled or the mToken is permissioned (plus the bond recipient, for the bond leg); operator/payment/vault-manager roles granted; the mToken/USD oracle set; and the bond config set with a greenlisted recipient.

**MorphoBorrowPosition.** On a fresh chain the `BorrowOffersRegistry` proxy must be deployed and initialized *before* the position implementation, whose constructor bakes the registry address in as an immutable. On live chains, upgrades bypass the factory entirely: a new implementation is deployed against the existing registry and the beacon is pointed at it. Every upgrade must pass the same registry address, or offer roles and configuration silently move to a different registry.

**Retargetter.** An instance is created permissionlessly and stays inert until wired:

- `REBALANCER_ROLE` on the PositionManager (`_ROLE_2`, bit value 4);
- the Retargetter's own roles, granted by the instance owner: its `REBALANCER_ROLE` (`_ROLE_0`, bit value 1) and `CONSUMER_ROLE` (`_ROLE_1`, bit value 2), distinct from the PositionManager role above;
- `maxRebalanceLoss` of at least 1 bps on the PositionManager, because Morpho share rounding produces phantom wei-level losses that a zero tolerance would revert on;
- `DEPOSITOR_ROLE` on the fund it operates;
- the `MorphoFlashLoanAdapter`, deployed once per chain against Morpho Blue and whitelisted on the instance alongside the funds;
- the yield estimates, set by the instance owner before the first operation;
- upstream venue allowlists (Superstate, Centrifuge, WrappedAsset issuer roles) for the flows it will run;
- a *dedicated* fund instance: funds hold a single global order slot, so sharing a fund between a Retargetter and the Facility (or between two Retargetters) collides.

**PositionManager.** Borrow modules are added by the owner, queues set by the curator, fees configured, and an optional TransferGuard attached. For 18-decimal debt assets, bootstrap the manager with a seed deposit before exposing it (see [Known Issues](known-issues.md#position-manager)).

## Upgrade Cautions

- Beacon ownership is the highest-impact privilege: hold it behind a multisig and timelock. There is no protection against renouncing or transferring it to the zero address.
- ERC-7201 namespaced storage coexists with Solady fixed-slot storage; verify both layouts when writing a new implementation, and do not introduce new inheriting parents lightly.
- Rotating a TransferGuard starts from a clean list state, and rotating a PM fee recipient must happen while the old recipient can still receive shares; both are checklist items in [Known Issues](known-issues.md#position-manager).
