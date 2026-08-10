// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IPositionManagerLP} from "../../interfaces/manager/base/IPositionManagerLP.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {SECONDS_PER_YEAR} from "../../libs/manager/LibConstants.sol";
import {BPS} from "../../libs/Constants.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManagerBase
/// @author 3F Protocol
/// @notice Abstract base contract for PositionManager providing roles, fee accrual, and snapshot management.
/// @dev Inherits OwnableRoles for role-based access control, ERC20 for share token functionality,
///      and ReentrancyGuardTransient for reentrancy protection.
abstract contract PositionManagerBase is OwnableRoles, ERC20, ReentrancyGuardTransient {
  using FixedPointMathLib for uint256;
  using LibStorage for PositionManagerStorageData;
  using LibView for PositionManagerStorageData;
  using LibView for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to mint/burn shares via deposit/withdraw/burn.
  uint256 internal constant MINTER_ROLE = _ROLE_0;

  /// @notice Role for addresses authorized to set supply/withdrawal queues.
  uint256 internal constant CURATOR_ROLE = _ROLE_1;

  /// @notice Role for addresses authorized to execute rebalancing operations.
  uint256 internal constant REBALANCER_ROLE = _ROLE_2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FEE ACCRUAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Computes pending fee shares without mutating state.
  ///
  ///      Management fees are charged on the aggregate collateral of non-bad-debt positions
  ///      (`currentCollat`), not on the NAV. For a leveraged vault this is materially larger
  ///      than the NAV. The fee assets are still capped at `totalAssets_` so the fee-adjusted
  ///      base used for share conversion remains non-negative.
  ///
  ///      The performance fee basis is the levered-slice performance only:
  ///      `LTV_ref * Δcollat - Δdebt`, where `LTV_ref = lastDebt / lastCollat` is the LTV at the
  ///      performance reference. Algebraically the basis simplifies to
  ///      `mulDivUp(lastDebt, currentCollat, lastCollat) - currentDebt`. Anchoring on `LTV_ref` rather
  ///      than `LTV_cur` (a) defines the unlevered baseline at the start of the period (the natural
  ///      comparison for "extra return from leverage"), (b) fixes the multiplier at reference time so
  ///      the basis depends on reference state plus current debt/collat rather than live LTV, and
  ///      (c) biases the basis larger when collateral appreciates faster than debt accrues — the
  ///      common case — keeping the rounding direction consistent with the rest of the contract.
  ///      The management fee assets are then deducted from this basis before applying the
  ///      performance fee rate.
  ///
  ///      The levered basis is capped at the NAV gain since the reference, zero-floored
  ///      (`totalAssets_ - lastTotalAssets`): an external deleveraging event (a liquidation, a
  ///      direct repay on the market) can leave the levered read positive while NAV fell, and
  ///      the cap keeps such events from minting a fee on a loss. A flow rebase converts such a
  ///      seizure drawdown into the reference carry (see `LibStorage.rebaseSnapshot`), so the
  ///      suspension survives flows until NAV recovers past the carried mark, even when the
  ///      deficit exceeds the remaining debt (the oversized-carry encoding in `rebaseSnapshot`
  ///      keeps the mark out of the bootstrap sentinel).
  ///
  ///      Reference-advance rule (high-water mark): the performance reference (`lastTotalAssets`,
  ///      `lastDebt`) advances to the current state only when the capped basis is positive
  ///      (crystallization, at the configured rate which may be zero), when `lastDebt` is zero
  ///      (bootstrap sentinel), or when the vault has no shares. When the basis is non-positive
  ///      the reference is held; it is also held when a positive basis carries a performance
  ///      entitlement that rounds to zero at either stage (the BPS multiplication to fee
  ///      assets, or the conversion to fee shares), so the gain accumulates instead of being
  ///      consumed by the advance (see the two holds in this function). Flows preserve a held
  ///      entitlement too (see `LibStorage.rebaseSnapshot`), so checkpoint splitting cannot
  ///      erase it through either the accrual or the flow path. Holding it keeps
  ///      the debt interest accrued while the collateral quote is flat (the collateral oracle
  ///      may only reprice periodically) inside the basis, so the next collateral repricing is
  ///      charged net of the full inter-repricing debt carry rather than only the last accrual
  ///      interval's. It also prevents re-charging a recovery
  ///      after a drawdown: the reference stays at the old peak instead of resetting down.
  ///      Crystallizing on a positive basis even when the configured rate is zero (or no recipient
  ///      is set) mirrors the pre-existing behavior that gains realised before fees are enabled
  ///      are never retroactively charged. For a permanent loss (a drawdown or liquidation that
  ///      will never recover past the old mark) the owner can force-advance the reference to the
  ///      current state via `resetPerformanceReference` in `PositionManagerAdmin`.
  ///
  ///      The performance fee is net of management fees over the whole period the reference
  ///      covers: the basis is reduced by the management fees charged while the reference was
  ///      held (`heldManagementFeeAssets`, accumulated each held accrual) plus the current
  ///      interval's management fee. Without the accumulator, management fees minted on a
  ///      non-positive basis would be forgotten and the next crystallization would overcharge by
  ///      exactly those amounts. The accumulator clears whenever the reference advances (any
  ///      excess above the basis is forgiven, not carried past the new mark) and on
  ///      `resetPerformanceReference`; flows scale it with the share supply so the per-share
  ///      deduction is preserved (see `LibStorage.rebaseSnapshot`).
  ///
  ///      Capital flows (deposit/withdraw/burn/rebalance/module changes) do not advance the
  ///      reference either; they rebase it so the pending per-share basis is preserved — see
  ///      `LibStorage.rebaseSnapshot`.
  ///
  ///      Debt rounding: `lastDebt` and `currentDebt` both originate from
  ///      `IBorrowPosition.totalBorrowed()`, which uses Morpho's `toAssetsDown` (see
  ///      `LibView.totalAssets` for the rationale). The basis therefore inherits Morpho's
  ///      rounding direction: debt is treated here exactly as the underlying market treats
  ///      it, with no additional bias on top of that accounting. As a consequence, the
  ///      performance fee is inherently rounded down.
  ///
  ///      Bootstrap: when `lastDebt == 0` (sentinel, e.g. immediately after upgrade), the
  ///      performance fee for this period is zero and only the management fee accrues. The
  ///      `lastDebt` slot is seeded in `_accrueFees` from the current debt.
  ///
  ///      Bad-debt episode: when every borrow module is underwater (`debt > collateral`),
  ///      `LibView.totalAssets()` excludes them all and the aggregates are zero. The basis is then
  ///      zero (not positive), so accruals hold the pre-episode reference, and flows that leave
  ///      the good-debt universe empty hold it too, including the flow that empties it, e.g.
  ///      removing or draining the last healthy module (see `LibStorage.rebaseSnapshot`); a
  ///      recovery is therefore measured against the pre-episode high-water mark, not forgiven.
  ///      Only a flow that brings the pool back above water re-anchors the reference at its
  ///      post-flow state, and gains recovered beyond that point are charged. `lastDebt == 0`
  ///      still doubles as the
  ///      bootstrap sentinel (reached via full repayment or the carry clamp in `rebaseSnapshot`):
  ///      the first accrual after it skips the performance fee and reseeds the reference.
  ///
  ///      Partial bad-debt episode: when only some modules are underwater, the survivors' NAV
  ///      keeps the aggregates non-zero, but the excluded modules' debt is missing from
  ///      `currentDebt` while the reference (set on the full universe) still counts it. Whenever
  ///      the exclusion leaves the survivors' visible LTV below the reference LTV, the visible
  ///      aggregate looks deleveraged and the basis reads positive at the trough of a drawdown;
  ///      charging it would mint a phantom fee and re-anchor the reference at the trough,
  ///      re-charging the recovery. Accruals therefore never crystallize, advance, or seed the
  ///      reference while `hasBadDebt` is set; the first accrual after the last module re-enters
  ///      resumes against the frozen (pre-episode) reference. Flows during the window still
  ///      rebase against the reduced universe; see `LibStorage.rebaseSnapshot` for the
  ///      mis-anchoring a window flow can leave on the reference and the operational remedies
  ///      (a temporary zero performance rate for an over-read, an owner reset for an
  ///      under-read).
  /// @return totalAssets_ The current total assets across all borrow modules (`collateralQuoted - debt`)
  /// @return totalSupply_ The current total supply of shares (before fee minting)
  /// @return currentDebt The current aggregate debt across non-bad-debt positions
  /// @return managementFeeShares The shares that would be minted for management fees
  /// @return performanceFeeShares The shares that would be minted for performance fees
  /// @return advanceReference True when `_accrueFees` must advance the performance reference to
  ///         the current state (positive capped basis, bootstrap, or empty vault); false to hold
  ///         it. Always false while any module is excluded as bad debt (see the partial bad-debt
  ///         episode rule above) and while a performance entitlement would round to zero fee
  ///         assets or shares (see the reference-advance rule above)
  /// @return heldManagementFees_ The value `_accrueFees` must persist as the held management fee
  ///         accumulator: zero when the reference advances (deduction consumed or forgiven),
  ///         otherwise the stored accumulator plus the management fee charged this interval
  function _pendingFees()
    internal
    view
    returns (
      uint256 totalAssets_,
      uint256 totalSupply_,
      uint256 currentDebt,
      uint256 managementFeeShares,
      uint256 performanceFeeShares,
      bool advanceReference,
      uint256 heldManagementFees_
    )
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Use ERC20.totalSupply() to bypass the nonReadReentrant override on the public totalSupply(),
    // since _pendingFees() is reachable from _accrueFees() during a guarded deposit/withdraw/burn.
    totalSupply_ = ERC20.totalSupply();

    uint256 managementFeeAssets;
    uint256 totalFeeAssets;
    {
      // Single iteration over borrow modules returns the NAV, the aggregate debt, the aggregate
      // quoted collateral, and the bad-debt exclusion flag of non-bad-debt positions in one pass.
      uint256 currentCollat;
      bool hasBadDebt;
      (totalAssets_, currentDebt, currentCollat, hasBadDebt) = _storage.totalAssets();

      // Levered-slice basis against the held reference. Computed regardless of the fee
      // configuration because it also drives the reference-advance decision (see the
      // reference-advance rule above).
      //
      // While any module is excluded as bad debt (`hasBadDebt`), the basis is not measurable:
      // the excluded module's debt is missing from `currentDebt` while the reference still
      // counts it, which deleverages the visible aggregate and can flip the basis positive in
      // the middle of a drawdown (the healthy modules' LTV sits below the reference LTV). The
      // reference is therefore frozen for the whole exclusion window: no crystallization, no
      // advance, and no bootstrap seed against the reduced universe (a seed there would anchor
      // the mark on aggregates that misrepresent the pool, mis-measuring the basis once the
      // excluded module re-enters). The management fee is unaffected; it keeps accruing on the
      // good-debt collateral and joins the held accumulator below.
      uint256 basis;
      {
        uint256 _lastDebt = _storage.lastDebt;
        if (_lastDebt == 0 || totalSupply_ == 0) {
          // Bootstrap sentinel or empty vault: no reference to measure against (lastCollat would
          // be zero or meaningless); skip the performance fee and (re)seed the reference.
          advanceReference = !hasBadDebt;
        } else if (!hasBadDebt) {
          uint256 lastCollat = _storage.lastTotalAssets + _lastDebt;
          // basis = mulDiv(lastDebt, currentCollat, lastCollat) - currentDebt
          //       = LTV_ref * currentCollat - currentDebt
          // Round up on the minuend (mulDivUp) so the basis is biased larger — favors the
          // protocol, consistent with conservative-to-protocol rounding elsewhere.
          uint256 scaledLastDebt = _lastDebt.mulDivUp(currentCollat, lastCollat);
          if (scaledLastDebt > currentDebt) {
            basis = scaledLastDebt - currentDebt;
            advanceReference = true;
          }
        }
      }

      // Cap the levered basis at the NAV gain since the reference (zero-floored): a seizure
      // (liquidation) leaves the levered read positive while NAV fell, and an uncapped basis
      // would mint a fee on the loss. Capped to zero the reference is held, so a recovery is
      // only charged past the pre-loss mark (see the cap notes in the header). On internal
      // paths the cap is slack. Outside the block above for stack depth.
      if (basis > 0) {
        basis = basis.min(FixedPointMathLib.zeroFloorSub(totalAssets_, _storage.lastTotalAssets));
        advanceReference = basis > 0;
      }

      // Loaded after the basis block to keep the peak stack depth flat (the block above is at
      // the non-via-ir stack limit).
      FeeData memory fd = _storage.feeData;
      if (fd.feeRecipient == address(0) || totalSupply_ == 0) {
        // No fee is charged, so the accumulator carries over unchanged unless the reference
        // advances (a positive basis still consumes the pending deduction, see the rule above).
        heldManagementFees_ = advanceReference ? 0 : _storage.heldManagementFeeAssets;
        return (totalAssets_, totalSupply_, currentDebt, 0, 0, advanceReference, heldManagementFees_);
      }

      // Management fee: charged on the aggregate good-debt collateral, time-weighted, then capped
      // at totalAssets_ so the post-fee asset base stays non-negative for share conversion.
      if (fd.managementFee > 0) {
        uint256 elapsed = block.timestamp - _storage.lastFeeAccrualTimestamp;
        managementFeeAssets = currentCollat.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
        managementFeeAssets = managementFeeAssets.min(totalAssets_);
      }

      // Performance fee on the levered-slice basis, net of the management fees charged since the
      // reference last advanced: the held accumulator plus the current interval's charge.
      heldManagementFees_ = _storage.heldManagementFeeAssets;
      totalFeeAssets = managementFeeAssets;
      if (fd.performanceFee > 0 && basis > managementFeeAssets + heldManagementFees_) {
        uint256 performanceFeeAssets =
          (basis - managementFeeAssets - heldManagementFees_).mulDiv(fd.performanceFee, BPS);
        // Hold the reference when the BPS multiplication rounds a nonzero net entitlement to
        // zero fee assets (the first of the two rounding stages of checkpoint splitting; the
        // share-conversion stage is held at the end of this function): advancing here would
        // consume the sub-BPS basis without paying it, so splitting one gain across many
        // checkpoints could erase the fee.
        if (performanceFeeAssets == 0) advanceReference = false;
        totalFeeAssets += performanceFeeAssets;
      }
      // While the reference is held, the current interval's management fee joins the accumulator
      // so the next crystallization deducts it; on advance the pending deduction is consumed (or,
      // for any excess above the basis, forgiven) and the accumulator restarts.
      heldManagementFees_ = advanceReference ? 0 : heldManagementFees_ + managementFeeAssets;
    }

    // Combined no-mint guard. Folds together three cases that all imply a zero share mint:
    //   - `totalFeeAssets == 0`: nothing to mint.
    //   - `totalFeeAssets == totalAssets_`: mgmt fee cap binds exactly; `feeAdjustedAssets` would be
    //     zero, and `convertToShares` against a zero base would mint an inflated share count to the
    //     fee recipient, confiscating the pool.
    //   - `totalFeeAssets > totalAssets_`: should not occur under current invariants
    //     (`managementFeeAssets` is capped at `totalAssets_`, and the perf basis is capped at
    //     `totalAssets_ - lastTotalAssets` by the NAV-gain clamp, with `performanceFee <= BPS`).
    //     Folding it in here makes the subsequent subtraction safe without depending on that
    //     invariant chain.
    // `_accrueFees` still refreshes `lastFeeAccrualTimestamp` (and the reference, per
    // `advanceReference`) so normal accrual resumes next call. Nothing is minted, so this
    // interval's management fee does not join the held accumulator either.
    if (totalFeeAssets >= totalAssets_) {
      return (
        totalAssets_,
        totalSupply_,
        currentDebt,
        0,
        0,
        advanceReference,
        advanceReference ? 0 : _storage.heldManagementFeeAssets
      );
    }

    // Convert the combined fee assets first so both components share the same fee-adjusted base
    // (`totalAssets_ - totalFeeAssets`), then split off the management component; the remainder is
    // the performance component.
    performanceFeeShares =
      totalFeeAssets.convertToShares(totalSupply_, totalAssets_ - totalFeeAssets, _storage.virtualShareOffset, false);
    if (managementFeeAssets > 0) {
      managementFeeShares = managementFeeAssets.convertToShares(
        totalSupply_, totalAssets_ - totalFeeAssets, _storage.virtualShareOffset, false
      );
      performanceFeeShares -= managementFeeShares;
    }

    // Hold the reference when a nonzero performance entitlement (`totalFeeAssets` above the
    // management component) converts to zero fee shares: advancing would consume the gain
    // without paying it, so checkpoint splitting could erase the fee. Held, the basis keeps
    // accumulating until it mints at least one share, and this interval's management fee joins
    // the held accumulator like any held accrual (see the reference-advance rule in the
    // header; an entitlement that already rounds to zero fee assets is held at the BPS stage
    // above).
    if (advanceReference && performanceFeeShares == 0 && totalFeeAssets > managementFeeAssets) {
      advanceReference = false;
      heldManagementFees_ = _storage.heldManagementFeeAssets + managementFeeAssets;
    }
  }

  /// @dev Accrues fees (management + performance) and mints shares to the fee recipient.
  ///      Uses `_pendingFees()` to compute the shares, then mints, advances the performance
  ///      reference (lastTotalAssets, lastDebt) when crystallizing, and writes the timestamp.
  ///
  ///      Bootstrap semantics: when `lastDebt` was zero on entry, the performance fee is zero
  ///      for this period and `lastDebt` is seeded here with the current debt. From the next
  ///      accrual onward the new basis applies normally.
  /// @return currentTotalAssets The total assets after fee accrual
  /// @return currentDebt The aggregate debt of non-bad-debt positions, returned so flow callers
  ///         can pass the pre-flow state to `LibStorage.rebaseSnapshot` after moving assets
  function _accrueFees() internal returns (uint256 currentTotalAssets, uint256 currentDebt) {
    uint256 managementFeeShares;
    uint256 performanceFeeShares;
    bool advanceReference;
    uint256 heldManagementFees_;
    (
      currentTotalAssets,, currentDebt, managementFeeShares, performanceFeeShares, advanceReference, heldManagementFees_
    ) = _pendingFees();

    uint256 feeShares = managementFeeShares + performanceFeeShares;

    // Mint fee shares
    if (feeShares > 0) {
      address feeRecipient = LibStorage.positionManagerStorage().feeData.feeRecipient;
      _mint(feeRecipient, feeShares);
      emit IPositionManagerLP.FeesAccrued(feeRecipient, feeShares);
    }

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    // Advance the reference only on crystallization (positive basis), bootstrap, or empty vault.
    // Holding it on a non-positive basis keeps accrued debt carry and drawdowns inside the basis
    // (high-water mark) instead of writing them off every accrual.
    if (advanceReference) {
      _storage.lastTotalAssets = currentTotalAssets;
      _storage.lastDebt = currentDebt;
    }
    // Persist the held management fee accumulator computed by _pendingFees: cleared on advance,
    // grown by this interval's management fee while the reference is held.
    _storage.heldManagementFeeAssets = heldManagementFees_;
    // The management fee is time-based and independent of the performance reference, so the
    // timestamp advances on every accrual even when the reference is held.
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);
  }

  /// @dev Rebases the performance reference across a flow, reading the post-flow state live.
  ///      Thin wrapper around `LibStorage.rebaseSnapshot` for callers that do not already have
  ///      the post-flow aggregates on hand (burn, rebalance, module add/remove).
  /// @param totalAssetsBefore The total assets before the flow (from `_accrueFees`)
  /// @param debtBefore The aggregate good-debt debt before the flow (from `_accrueFees`)
  /// @param prevSupply The share supply before the flow (including freshly minted fee shares)
  /// @return totalAssetsAfter The total assets after the flow
  function _rebaseReference(uint256 totalAssetsBefore, uint256 debtBefore, uint256 prevSupply)
    internal
    returns (uint256 totalAssetsAfter)
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    uint256 debtAfter;
    uint256 collatAfter;
    (totalAssetsAfter, debtAfter, collatAfter,) = _storage.totalAssets();
    _storage.rebaseSnapshot(
      totalAssetsBefore + debtBefore, debtBefore, prevSupply, collatAfter, debtAfter, ERC20.totalSupply()
    );
  }
}
