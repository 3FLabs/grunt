// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {IInKindFacility} from "../../../interfaces/facility/IInKindFacility.sol";
import {IPositionManager} from "../../../interfaces/manager/IPositionManager.sol";
import {IWrappedAsset} from "../../../interfaces/funds/IWrappedAsset.sol";
import {LibView} from "../../manager/LibView.sol";
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
  /*                          POOL READS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts with BadDebtState when a module is underwater: pricing against a reduced
  ///      module universe is undefined.
  function checkNoBadDebt(IPositionManager pm) internal view {
    if (pm.hasBadDebt()) revert IInKindFacility.BadDebtState(address(pm));
  }

  /// @dev Returns the pool aggregates for an entry, enforcing the bad-debt and unlevered gates:
  ///      with no rate field there is no bootstrap ratio for an empty or unlevered pool.
  function leveredPoolState(IPositionManager pm) internal view returns (uint256 totalCollateral, uint256 totalDebt) {
    checkNoBadDebt(pm);
    totalCollateral = pm.collateralAmount();
    totalDebt = pm.debtAmount();
    if (totalCollateral == 0 || totalDebt == 0) revert IInKindFacility.UnleveredPool(address(pm));
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

  /// @dev Fair mint for a ratio-matched entrant of `amount` into a pool of `totalCollateral`:
  ///      the fraction `amount / C` of the post-accrual supply (virtual offset included, as
  ///      burn's denominator). Under one quote the actual mint is that times `TA / (TA + 1)`
  ///      plus rounding: one debt-wei from rounding the debt down and one per module the deposit
  ///      touches (each floors its quoted collateral on both sides of the flow). The tolerance
  ///      is that many debt-wei worth of shares plus one share.
  function fairMint(IPositionManager pm, uint256 amount, uint256 totalCollateral)
    internal
    view
    returns (uint256 expected, uint256 tolerance)
  {
    uint256 supplyAdj = adjustedSupply(pm);
    expected = supplyAdj.mulDiv(amount, totalCollateral);
    tolerance = supplyAdj.mulDivUp(2 + pm.supplyQueue().length, pm.totalAssets() + 1) + 1;
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
