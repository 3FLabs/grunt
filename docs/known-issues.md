# Known Issues & Assumptions

The registry of accepted risks, unsupported cases, and operating assumptions. Most entries originate from an audit finding whose resolution was to document the behavior rather than change the code; removing an entry here (or the behavior it describes) means re-opening the underlying finding.

References: **CS** = [ChainSecurity Grunt](../audits/ChainSecurity_3F_Grunt_Audit_2026-04.pdf), **CSF** = [ChainSecurity Grunt Funds](../audits/ChainSecurity_3F_GruntFunds_Audit_2026-04.pdf), **C** = [Cantina Grunt](../audits/Cantina_3F_Grunt_Audit_2026-05.pdf), **CFR** = [Cantina Fee Review](../audits/Cantina_3F_Grunt_FeeReview_2026-05-27.pdf). Midas entries come from design review; MidasFund postdates these audits.

## Trust Model

Roles fall into three levels (CS trust model):

- **Fully trusted**: contract owners and admins, the Request owner, and above all the **beacon owners**; a beacon owner upgrades every deployed proxy of that kind at once, so beacon (and Facility proxy) ownership is the highest-impact privilege in the system.
- **Semi-trusted bots** (hot wallets): Facilitator, Rebalancer, Curator, Consumer. Compromise should cause at most partial loss or liveness failure, never total loss. Two caveats sharpen this: `EXECUTOR_ROLE` on `MorphoFlashLoanRequest` can run facilitator-level operations on any intent's pooled capital and must be held to facilitator-equivalent trust (C 3.3.25); and with the rebalance cooldown at or near zero, the Rebalancer can compound losses past `maxRebalanceLoss` and must be considered fully trusted (CS-GRUNT-008).
- **Untrusted**: everyone else, including LPs and liquidators.

System-wide assumptions:

- **No exotic ERC-20s.** Fee-on-transfer, rebasing, reverting-transfer, and similarly non-standard tokens are unsupported. No allowlist enforces this on-chain; a trusted role wiring in a malicious token could permanently block an intent's claims (CS-GRUNT-065).
- **`pauseFor()` is not a system-wide stop.** It pauses Facility LP operations only; Request, WrappedAsset, and the fund adapters keep operating while the Facility is paused. Incident-response runbooks must not treat it as a global halt (C 3.3.19).
- **Factory registries are deployment logs, not provenance checks.** Nothing on-chain verifies that a fund, request, or position manager wired into an intent came from a Grunt factory, and registry entries can never be retired. The `is*()` views exist for off-chain monitoring (C 3.3.5, 3.4.3).
- **Upgrade storage care.** ERC-7201 namespaced storage coexists with Solady base contracts and fixed-slot libraries; upgrades must track both layouts, and introducing a new Solady parent can collide (CS Note 10.5). Beacons have no zero-address or renounce protection; losing beacon ownership permanently freezes upgrades (C 3.3.28).
- **The Facility proxy must be deployed and initialized atomically** (`upgradeAndCall`), or anyone can front-run `initialize()` and take ownership (CS Note 10.3).
- **Oracle outages are assumed short-lived.** A reverting oracle on any borrow module bricks every PositionManager entry point including `removeBorrowModule` (all paths accrue fees, which reads every module). The accepted recovery is a PM upgrade (C 3.3.13).

## Guardian Signatures

- **Signed digests are live authorizations.** `setFund`, `setRequest`, and `swap` digests carry no nonce; every signed parameter set stays executable until its deadline, even after guardians have agreed on new terms. Guardians must use short deadlines and treat signing as irrevocable (C 3.3.9).
- **The signer address is not part of the digest.** A smart-contract-wallet guardian must ensure its EIP-1271 validation binds its own address (Safe >= 1.3.0 does); wallets sharing an EOA signer can otherwise replay each other's approvals. Wallets with faulty fallbacks must not be quorum signers (CS Note 10.14).
- **Guardian diligence substitutes for on-chain validation.** Before signing, guardians verify: swaps are fairly priced against fresh oracles and involve no malicious tokens (CS Note 10.20); a new fund or request is a canonical factory deployment with correctly assigned trusted roles; a new request is still live, since `setRequest` never checks that the incoming request is unexpired or unrepaid (C 3.3.4). These checks are extremely important for intents with quorum 0, where they fall entirely on the facilitator (CS Note 10.16).

## Facility

- **ETH sent with ERC-6909 transfers is lost.** The inherited transfer functions are payable and the Facility has no ETH recovery path (CS-GRUNT-016).
- **Per-intent `approve()` does not delegate.** `withdraw` and `claim` only honor the global `setOperator` flag, which grants access to every intent, present and future; the per-id allowance is never read (C 3.3.8).
- **One blocked payout token bricks a claim.** `claim()` transfers every token the intent holds in one loop; if the receiver is blocked from receiving any one of them (TransferGuard, Superstate allowlist on wUSCC), the whole claim reverts (C 3.2.2). The token set is kept operationally small (CS-GRUNT-055).
- **`revertDeposit` ordering.** Reverting a deposit burns LP shares through the guard checks, so it fails on an already-blocklisted address: compliance must revert first, then block. Acceptable because deposits are typically already disabled in that phase (CS-GRUNT-086, C 3.3.3).
- **Deposit-cap griefing.** An attacker can fill the cap and withdraw just before resolution, or sandwich genuine deposits. Mitigations are operational: large caps, monitoring, and preemptively locking intents (C 3.3.26).
- **Fund order rates are only checked at `create()`.** `commit()` never re-validates `order.output` against current rates; the facilitator owns rate drift between create and commit (C 3.3.10). Orders whose expected output rounds to zero pass the slippage check as a no-op (C 3.3.18).
- **Funds are rolling adapters.** A fund tracks no per-order value; `unlock()`/`recover()` sweep the relevant token balance into the *current* order, so late or residual balances from earlier orders are carried forward into whichever order is active. This is why each fund must serve a single intent (C 3.3.1).
- **Request maturity is an operational constraint.** Once `repaymentDeadline` passes, the request auto-flips to repaid and the intent can resolve with the pulled principal paid out to LPs while PT holders hold an empty request. Deadlines must be set far enough out that principal always returns first (C 3.2.1).
- **Same-block cancel + create reuses an orderId.** The order salt is per-block; the facilitator avoids the pattern because it confuses off-chain order tracking (CS Note 10.9).
- **`updateTarget` does not re-validate attached components.** Funds and requests validated against the previous target/guard key may become incompatible; the owner performs those checks manually (CS Note 10.12). When an intent connects two PositionManagers they must share the same TransferGuard, which is managed operationally (CS-GRUNT-033).
- **`setFund`/`setRequest` are callable in any phase** by design; the specification was aligned to the code (CS-GRUNT-024).
- **Realized leverage deviates from target.** The flow spans days between deposit, bridge loan, and settlement; prices and rates move in that window, and the bridge loan size chosen by privileged roles also shifts the outcome between depositors and existing PM shareholders (CS Notes 10.1, 10.11).

## Request (PT/YT)

- **The lifecycle is intentionally non-strict.** `mint()` and `consume()` remain callable after funds are pulled; there is no on-chain funding/utilization boundary, allowing the borrow to be increased on errors (CS-GRUNT-059).
- **Unbacked YT minting is bounded, not eliminated.** A compromised consumer can authorize and mint YT-heavy positions to skim yield. `setRepaid` enforces a cooling-off delay after the last mint, but the `repaymentDeadline` auto-flip bypasses it, so the deadline must sit far in the future and minting must be monitored off-chain (CS-GRUNT-038).
- **`setRepaid(minBalance, maxBalance)` protects both directions**: `minBalance` against a facilitator draining before repayment is declared, `maxBalance` against a facilitator over-repaying to inflate YT redemptions from intent funds. Passing `type(uint256).max` as `maxBalance` disables the second protection and re-opens that attack (CS-GRUNT-081).
- **`authorizeMinting` overwrites like ERC-20 approve.** To change an authorization safely: revoke to zero, wait for confirmation, then set the new amounts; otherwise the holder can front-run and consume both (CS-GRUNT-068).
- **Repayments after partial PT redemptions can shift value to YT.** PT redemptions in an underfunded state shrink `ptSupply`, so later inflows are classified as yield above the reduced principal ceiling (C 3.3.2).
- **ERC-4626 views are non-standard.** `previewDeposit` is always 0 (deposits disabled); YT `convertToAssets` is 0 while underfunded then jumps discontinuously, and `convertToShares` can return `uint256.max`; quotes deflate while principal is pulled, since pricing reads the live balance. YT is generally not recommended as a DeFi integration primitive, and intent shares are not recommended where pricing is required (C 3.2.4, CS Note 10.13).
- **Approve amounts in `[2^128, 2^256-2]` become infinite.** PT/YT allowances are stored as uint128 with `uint256.max` as the infinite sentinel; values in between are rejected or normalized rather than tracked exactly (CS Note 10.2).
- **`MorphoFlashLoanRequest.isRepaid()` means "no outstanding debt"**, not "a loan happened and was repaid" (CSF 8.13). Script payloads passed to `execute()` are deliberately not validated against the request's facility or intent; the executor is trusted to wire them correctly (CSF 9.1).

## Position Manager

**Bad debt.** `totalAssets()` floors each underwater module at zero, so NAV stops tracking reality the moment a module goes bad: deposits, withdrawals, and burns all misprice against the hidden loss (withdrawers overburn shares, depositors underreceive, burns absorb the bad debt). There is no in-contract fix; the strategy is to *abandon* a PositionManager that reaches this state: pause, pull the module from the queues, stop user interactions. The Facilitator must not deposit, withdraw, or burn while any module has bad debt or liquidatable positions (CS-GRUNT-084, C 3.2.6, CS Notes 10.7, 10.16).

Fee accounting around bad debt has documented edges: the management-fee basis drops a module's entire collateral the wei it crosses into bad debt (CFR 3.1.3); if *all* modules are in bad debt at an accrual, the snapshot writes the `lastDebt == 0` bootstrap sentinel and the first recovery accrual skips the performance fee (CFR 3.1.2); and `totalDebt`/`lastDebt` are rounded-down accounting values sourced from `totalBorrowed()`, never to be reused for solvency or liquidation logic (CFR 3.1.4).

**Share-price manipulation.** Anyone can donate collateral or repay debt directly on Morpho on behalf of a module:

- Donation inflation is mitigated by the decimal-dependent virtual offset but remains profitable for 18-decimal debt tokens with multiple victims; new PMs are bootstrapped with a seed deposit, and integrators pricing PM shares must tolerate sudden upward jumps (CS-GRUNT-032, C 3.2.3, CS Note 10.18).
- Donated debt relief is indistinguishable from performance, so the fee recipient takes a cut of it (C 3.3.21).
- After a full pre-liquidation, totalAssets hits zero while supply persists; the next deposit mints an enormous share count (CS Note 10.17).

**Fees and the guard.** Fee shares are minted through the transfer guard, so a blocked (or Superstate-dropped, with `checkCollateralAllowed`) fee recipient deadlocks every entry point including `setFeeData` itself. Rotate the recipient *before* blocking it, and keep it allowlisted until pending fees clear (C 3.3.16, 3.4.6). The management fee applies the annual rate to the live basis over the full elapsed period, a deliberate simplification that over- or under-charges when AUM moves between accruals (CS-GRUNT-022).

**Exits.** Debt accrues continuously while `withdraw` takes exact amounts, and per-position repayments round down, so full exits can revert or leave dust; the last shareholder may need to repay an extra wei directly, or request slightly less than the reported totals (CS-GRUNT-064, 3.3.20/CS-GRUNT-104). A proportional `withdraw` reverts when any position has drifted above the target LTV; `burn()` is the supported proportional exit (CS-GRUNT-100). All rounding is conservative to the protocol and bounded at a wei per module per operation (CS-GRUNT-103).

**Queues and rebalancing.** Deposit collateral routes entirely to `supplyQueue[0]`, relying on Morpho collateral supply being uncapped; a future capped `IBorrowPosition` would need different routing, and curators rebalance after deposits when distribution matters (C 3.3.7). `maxRebalanceLoss` must be nonzero in production (Morpho share rounding produces phantom wei losses), compares oracle-dependent NAV so a mid-rebalance price move can mask real loss (CS-GRUNT-102), and adding or removing a non-flat module steps NAV in one transaction, which is sandwichable (C 3.3.17). A dominant Morpho lender can manipulate deposit routing by moving liquidity around Grunt transactions (CS Note 10.19).

**Transfer guard.** The guard sees only `from`/`to`, never the delegated caller, so blocking a spender/operator address does not stop it from moving others' shares (C 3.3.12). Rotating to a new guard starts from a clean state, silently unblocking every previously blocked address until the new lists are populated (C 3.4.4). With `checkCollateralAllowed`, the amount forwarded to `isAllowed()` is the share amount, not the collateral amount; today's only override ignores it (C 3.4.11).

## Borrow & Liquidations

- **Exact-input pre-liquidations can be griefed.** Small front-running repayments shrink live shares/collateral and make exact `repaidShares`/`seizedAssets` inputs revert. Liquidators should use private mempools or re-quote and retry, read fresh position data from a contract, and enforce their own profitability; rounding is adverse to the liquidator (repay up, seize down) (C 3.3.6, CS Note 10.15).
- **The proportional bonus is capped above the market LLTV.** Beyond it, repaid shares are adjusted up (or seized assets down), so partial pre-liquidations can become unprofitable before full ones (CS Note 10.10).
- **A large oracle jump can skip the pre-liquidation band entirely**, landing positions straight in standard Morpho liquidation. The safe LTV must be chosen so one realistic jump cannot take a safe position past the band (CS Note 10.8).
- **An empty Morpho market can be bricked** by exponential borrow-share deflation before Grunt borrows in it. The accepted recovery is recreating the market and migrating, initializing directly by wrapping receipt tokens instead of the full async flow (CS-GRUNT-063).
- **wUSCC flows depend on the Superstate allowlist end to end.** The PM, borrow modules, Morpho, order receivers, the fee recipient, and critically liquidators must all be and remain allowlisted; only allowlisted actors can liquidate, so allowlisted liquidators are onboarded before opening wUSCC-backed markets (C 3.2.7, CS Note 10.4). Morpho suppliers are unrestricted and can withdraw liquidity an intent needed to repay its bridge loan, stalling it (CS Note 10.6).

## Retargetter

- **A Request past its 90-day deadline auto-expires** and bypasses the retargetter's repayment gates: `repay()` reverts with `AlreadyRepaid` and late remediation is arranged off-chain, deliverable only through the beacon upgrade path (multisig + timelock). Operations are expected to settle far inside the horizon.
- **Donations to the retargetter or its modules are absorbed, not blocked**: dust below the residual tolerance folds into the next operation; larger amounts are folded back via full-balance rebalance legs; a debt-asset donation exceeding module debt requires the owner to raise the tolerance exponent to settle.
- **The consumption window prices all bridge capital from the loan origin**, so entry closes at the first tick threshold or first pull; late capital would be overpaid and dilute recovery on a default. This binds the owner too.

## Funds

Applies to all integrations:

- **`totalAssets()` is wrapper-wide.** Funds sharing one WrappedAsset all report the aggregate AUM of the wrapper, not per-fund holdings; per-fund AUM is an off-chain concern. Facility accounting is unaffected because it snapshots balances (C 3.4.2, CS-GRUNT-036).
- **`order.output` is a create-time sanity check.** Nothing validates the amount actually received at `unlock()` against it; for async settlement it functions as a stuck-order guard, not slippage protection. The exception is synchronous flash-loan-wrapped Pareto deposits, where a shortfall keeps the state machine short of ENDED and the whole operation can revert (CSF Note 10.4).

**USCC (Superstate)**

- `resolve()` lets the owner/operator overwrite an order's amounts, bypassing state-transition thresholds; a zeroed order can unlock/recover without funds having arrived. The operator is a multisig and the flexibility is intentional (CS-GRUNT-026).
- The oracle read has no staleness check; the price bounds order outputs with a configurable margin and is deliberately imprecise (CS-GRUNT-037).
- A receiver that loses Superstate eligibility mid-order blocks unlock/recover; the intended recovery is re-allowlisting the receiver, not a rescue path (C 3.3.14).

**Centrifuge (ERC-7540)**

- Someone must regularly call `notifyDeposit()`/`notifyRedeem()` on Centrifuge's BatchRequestManager to flush fulfilled orders; the responsibility is assigned operationally (CSF Note 10.1). Centrifuge epoch approvals can also be delayed by a known cancellation front-running DoS upstream (CSF Note 10.2).
- An unpriced vault silently disables the create-time slippage check (`convertToShares` returns 0) (CSF Note 10.3).
- Recovery deviates from the IFund state machine: fulfilled fills remain claimable during recovery, so `state()` can report UNLOCKING while recovering and `unlock()` can transition back to RECOVERING (CSF Note 10.5).
- Partial fills across many epochs can leave residual dust in perpetual PROCESSING; operators monitor and cancel such orders (CSF Note 10.8). Centrifuge roles are trusted not to de-whitelist the fund mid-order, which would corrupt the cancel guard (CSF Note 10.9).
- `forceEnd()` is a trusted-operator escape hatch: called at the wrong time it abandons committed or pending-cancel assets from the intent's perspective (CSF Note 10.10, 9.2).
- The share-token approval before `requestRedeem` is intentionally kept for vault versions without `authTransferFrom` (ACRDX) (CSF 8.19).

**Pareto (Idle CDO)**

- **Vaults with instant withdrawals are unsupported by specification.** `commit()` detects the instant path and reverts with `InstantWithdrawDetected`; if Pareto routes a withdrawal instantly (a significant APR change can trigger this), the redeem is blocked until conditions change (CSF 8.4).
- Direct donations to the CDO temporarily inflate `virtualPrice` until skimmed, enabling collateral-valuation attacks when Pareto tranches back leveraged positions. Mitigation is parameter policy (significant safe-LTV to pre-liquidation spread, moderate leverage) plus monitoring of PM concentration in the tranche and of the vault's feeReceiver (CSF 8.3).
- `virtualPrice` is stale between epoch settlements (about monthly) and moves as a step function, which distorts performance-fee accrual, lets position health drift, and can unfairly liquidate an economically healthy position when the step lands (CSF Note 10.7).
- `create()`'s expected-output check is a sanity bound on facilitator input, not a pricing oracle: `depositDuringEpoch` mints fewer tranche tokens than the `virtualPrice` estimate, and redemption proceeds are reduced by buffer-period interest; both gaps are absorbed by the deviation margin (CSF 8.7, 9.3).
- A Pareto vault is only integrated after its first lending cycle (epoch counters start at 0 and break withdrawal detection), and the first deposit into a fresh tranche loses `MIN_LIQUIDITY` (1000 units) to a one-time burn, requiring an operator `resolve()` (CSF 8.12, C 3.4.7, 3.3.23).
- A Pareto borrower default has no in-fund handling path; recovery would likely require an upgrade. Revoking the fund's Keyring permission likewise locks assets, with no emergency bypass (CSF Note 10.6, trust model).

**Midas (mToken)**

- Rejected deposit requests are not refunded on-chain; recovery waits for a Midas admin to return the payment token off-band, and the order reads PROCESSING until the refund covers the committed input.
- Once a redeem's bond leg is paid, `cancel()` is refused: the order completes forward or is aborted via recovery with the bond forfeited unless Midas returns it off-band (in mTokens, which recovery re-wraps into shares).
- The per-redemption redemption vault is pointed at mid-order and is not blindly trusted: the fund re-checks received amounts against the order's on-chain minimum.
- Fund-side pricing assumes the payment asset is worth exactly $1 and uses a single rotatable mToken/USD oracle; redeem outputs are not oracle-validated at create (the vault does not exist yet).
- With a greenlisted vault or permissioned mToken, the fund, the WrappedAsset, and the bond recipient must all be greenlisted for orders to proceed.
