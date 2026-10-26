// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {IInKindFacility} from "../../../interfaces/facility/IInKindFacility.sol";
import {IPositionManager} from "../../../interfaces/manager/IPositionManager.sol";
import {IWrappedAsset} from "../../../interfaces/funds/IWrappedAsset.sol";
import {LibView} from "../../manager/LibView.sol";
import {LibSaturatingMath} from "../../common/LibSaturatingMath.sol";
import {BPS} from "../../Constants.sol";

/// @title LibInKindView
/// @author 3F Protocol
/// @notice Position manager reads and share math shared by the InKindFacility flows and previews.
/// @dev Every PM view used here is accrual-aware on the Morpho borrow position (expected market
///      balances), so the ratios match what the market settles at during the flow. A borrow
///      module whose `totalBorrowed` lags the market would let entries and exits use a stale
///      ratio; only serve PMs whose modules quote accrued debt.
library LibInKindView {
  using FixedPointMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Headroom pulled on top of the mirrored exit debt, in basis points, refunded once
  ///         `PM.burn` settled. Covers a burn that pulls slightly more than the mirror (a rounding
  ///         or accounting change in the PM) without blocking exits.
  uint256 internal constant EXIT_DEBT_HEADROOM_BPS = 10;

  /// @notice Rounding units a ratio-matched mint may exceed the fair fraction by: one for the
  ///         floored debt, one per module the deposit touches (each floors its quoted collateral
  ///         on both sides of the flow). A constant rather than a queue length so the check does
  ///         not depend on the PM's module layout; 32 covers any realistic supply queue at a
  ///         cost of 32 debt-wei of equity. An entry many times the pool's size into a
  ///         multi-module PM can exceed it; split it.
  uint256 internal constant MINT_ROUNDING_UNITS = 32;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          POOL READS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts with BadDebtState when a module is underwater: pricing against a reduced
  ///      module universe is undefined.
  function checkNoBadDebt(IPositionManager pm) internal view {
    if (pm.hasBadDebt()) revert IInKindFacility.BadDebtState(address(pm));
  }

  /// @dev Returns the pool aggregates for an entry, enforcing the bad-debt and unlevered gates.
  ///      An empty pool never passes: with no rate field there is no bootstrap ratio, and the
  ///      neutrality gate would price the first entry against the virtual offset alone. A pool
  ///      with collateral but no debt has a ratio (the entry borrows nothing) and passes when
  ///      the offer allows it.
  function entryPoolState(IPositionManager pm, bool allowUnlevered)
    internal
    view
    returns (uint256 totalCollateral, uint256 totalDebt)
  {
    checkNoBadDebt(pm);
    totalCollateral = pm.collateralAmount();
    totalDebt = pm.debtAmount();
    if (totalCollateral == 0) revert IInKindFacility.EmptyPool(address(pm));
    if (totalDebt == 0 && !allowUnlevered) revert IInKindFacility.UnleveredEntryDisabled(address(pm));
  }

  /// @dev Whether the pool's quoted LTV is above the PM's target, where PM.deposit cannot place
  ///      a ratio-matched borrow. PM.deposit rounds per module, so within a few debt units of
  ///      the target the two can disagree.
  function aboveTargetLtv(IPositionManager pm, uint256 totalDebt) internal view returns (bool) {
    if (totalDebt == 0) return false;
    (uint256 ltv,) = pm.config();
    return totalDebt * FixedPointMathLib.WAD > pm.collateralAmountQuoted() * ltv;
  }

  /// @dev The underlying asset of the PM's wrapped collateral.
  function underlying(IPositionManager pm) internal view returns (address) {
    (address collateralAsset,) = pm.assets();
    return IWrappedAsset(collateralAsset).underlying();
  }

  /// @dev Returns burn's exact share denominator: the post-fee-accrual total supply (pending
  ///      management and performance fee shares included) plus the virtual share offset.
  function adjustedSupply(IPositionManager pm) internal view returns (uint256 supplyAdj) {
    (, uint256 totalSupply_, uint256 mgmtFeeShares, uint256 perfFeeShares) = pm.pendingFees();
    return totalSupply_ + mgmtFeeShares + perfFeeShares + pm.virtualShareOffset();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          SHARE MATH                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Mirror of `PM.burn`'s debt slice for `burnShares`: post-accrual supply plus virtual
  ///      offset, rounded up. Gated on bad debt.
  function exitDebt(IPositionManager pm, uint256 burnShares) internal view returns (uint256 debt) {
    checkNoBadDebt(pm);
    return pm.debtAmount().mulDivUp(burnShares, adjustedSupply(pm));
  }

  /// @dev The debt asset an exit pulls up front for a mirrored `debt`: the debt plus
  ///      EXIT_DEBT_HEADROOM_BPS and one unit, zero when the debt is zero. Whatever `PM.burn`
  ///      leaves unused is refunded to the caller.
  function exitDebtRequired(uint256 debt) internal pure returns (uint256 required) {
    if (debt == 0) return 0;
    return debt + debt.mulDivUp(EXIT_DEBT_HEADROOM_BPS, BPS) + 1;
  }

  /// @dev Mirror of `PM.burn`'s collateral slice for `burnShares`, rounded down.
  function exitCollateral(IPositionManager pm, uint256 burnShares) internal view returns (uint256 collateral) {
    return pm.collateralAmount().mulDiv(burnShares, adjustedSupply(pm));
  }

  /// @dev Splits `shares` into the part kept by the flow and the fee part, rounded up for the
  ///      recipient.
  function splitFee(uint256 shares, uint24 feeBps) internal pure returns (uint256 net, uint256 fee) {
    fee = shares.mulDivUp(feeBps, BPS);
    net = shares - fee;
  }

  /// @dev Largest gross share amount whose net after {splitFee} is at most `net`, zero for a zero
  ///      `net` (any gross would burn nothing). With a nonzero fee the net is exactly `net`.
  ///      Saturates at type(uint256).max.
  function grossForNet(uint256 net, uint24 feeBps) internal pure returns (uint256 gross) {
    if (net == 0) return 0;
    gross = LibSaturatingMath.mulDiv(net.saturatingAdd(1), BPS, BPS - feeBps);
    if (gross == type(uint256).max) return gross;
    // floor((net + 1) * BPS / (BPS - fee)) nets `net + 1` exactly when the division is exact
    (uint256 grossNet,) = splitFee(gross, feeBps);
    if (grossNet > net) gross--;
  }

  /// @dev Upper bound on the shares a ratio-matched entry of `amount` may mint. The entrant
  ///      adds `amount / C` of the pool's collateral and the same fraction of its debt, so it
  ///      adds that fraction of the pool's equity whatever the quote: its fair share is
  ///      `expected = S_adj * amount / C` (the post-accrual supply plus the virtual offset, as
  ///      burn's denominator). `PM.deposit` instead mints from the quoted equity it observes;
  ///      under one quote that is `expected * TA / (TA + 1)` plus integer rounding, so a mint
  ///      above `expected + tolerance` means the PM valued the entry above the pool average (a
  ///      divergent module quote or a bug) and would dilute holders. `tolerance` is
  ///      MINT_ROUNDING_UNITS debt-wei of equity converted to shares, plus one share.
  function fairMint(IPositionManager pm, uint256 amount, uint256 totalCollateral)
    internal
    view
    returns (uint256 expected, uint256 tolerance)
  {
    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtFeeShares, uint256 perfFeeShares) = pm.pendingFees();
    uint256 supplyAdj = totalSupply_ + mgmtFeeShares + perfFeeShares + pm.virtualShareOffset();
    expected = supplyAdj.mulDiv(amount, totalCollateral);
    tolerance = supplyAdj.mulDivUp(MINT_ROUNDING_UNITS, totalAssets_ + 1) + 1;
  }

  /// @dev Best-effort share estimate for previews: quoted equity added, converted at the
  ///      pre-flow share price (post-fee-accrual supply, as PM.deposit accrues fees first).
  function estimateShares(IPositionManager pm, uint256 amount, uint256 totalCollateral, uint256 debt)
    internal
    view
    returns (uint256 shares)
  {
    uint256 quoted = pm.collateralAmountQuoted().mulDiv(amount, totalCollateral);
    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtFeeShares, uint256 perfFeeShares) = pm.pendingFees();
    shares = LibView.convertToShares(
      quoted.zeroFloorSub(debt),
      totalSupply_ + mgmtFeeShares + perfFeeShares,
      totalAssets_,
      pm.virtualShareOffset(),
      false
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         VALIDATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Validates that `positionManager` exposes the PM surface the facility needs: assets()
  ///      must resolve to a wrapped collateral with a nonzero underlying.
  function validatePositionManager(address positionManager) internal view {
    if (positionManager.code.length == 0) revert IInKindFacility.InvalidPositionManager(positionManager);
    try IPositionManager(positionManager).assets() returns (address collateralAsset, address) {
      if (collateralAsset.code.length == 0) revert IInKindFacility.InvalidPositionManager(positionManager);
      try IWrappedAsset(collateralAsset).underlying() returns (address underlying_) {
        if (underlying_ == address(0)) revert IInKindFacility.InvalidPositionManager(positionManager);
      } catch {
        revert IInKindFacility.InvalidPositionManager(positionManager);
      }
    } catch {
      revert IInKindFacility.InvalidPositionManager(positionManager);
    }
  }
}
