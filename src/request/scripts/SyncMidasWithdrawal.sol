// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IFacilityFunds} from "../../interfaces/facility/base/IFacilityFunds.sol";
import {IFacilityIntents} from "../../interfaces/facility/base/IFacilityIntents.sol";
import {IFacilityPositionManager} from "../../interfaces/facility/base/IFacilityPositionManager.sol";
import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {Asset, IntentProperties} from "../../libs/facility/LibIntent.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title SyncMidasWithdrawal
/// @notice Stateless script designed to be delegatecalled from MorphoFlashLoanRequest after a
///         bonded Midas redeem has been unlocked for instant settlement.
/// @dev Must NOT have any storage variables. The redeem order must already exist and its first
///      commit must already have paid the bond. Repays enough live debt to restore the target LTV,
///      withdraws the remaining redemption collateral, then executes second commit -> unlock;
///      MorphoFlashLoanRequest supplies and repays the debt asset around this call.
/// @author 3F Protocol
contract SyncMidasWithdrawal {
  using FixedPointMathLib for uint256;

  uint256 private constant _WAD = 1e18;

  error InvalidPositionManager();
  error InvalidTargetLtv();
  error InvalidWithdrawAmount();
  error TargetLtvExceeded();

  /// @notice Restores the target LTV, settles the remaining Midas redeem, and unlocks its proceeds.
  /// @param facility The facility contract address.
  /// @param intentId The intent ID on the facility.
  /// @param withdrawAmount The remaining collateral required by the Midas redemption.
  /// @param targetLtv The maximum LTV after the withdrawal, in WAD precision.
  /// @param useTarget Whether the intent's target asset is the position manager.
  function run(address facility, uint256 intentId, uint256 withdrawAmount, uint256 targetLtv, bool useTarget) external {
    if (targetLtv >= _WAD) revert InvalidTargetLtv();

    (IntentProperties memory properties,,,) = IFacilityIntents(facility).getIntent(intentId);
    Asset memory managerAsset = useTarget ? properties.targetAsset : properties.depositAsset;
    if (!managerAsset.isPositionManager) revert InvalidPositionManager();

    IPositionManager manager = IPositionManager(managerAsset.asset);
    uint256 collateral = manager.collateralAmount();
    if (withdrawAmount == 0 || withdrawAmount > collateral) revert InvalidWithdrawAmount();

    uint256 quotedCollateral = manager.collateralAmountQuoted();
    uint256 quotedWithdrawal = quotedCollateral.mulDivUp(withdrawAmount, collateral);
    uint256 targetDebt = (quotedCollateral - quotedWithdrawal).mulDiv(targetLtv, _WAD);
    uint256 liveDebt = manager.debtAmount();
    uint256 repayAmount = liveDebt > targetDebt ? liveDebt - targetDebt : 0;

    IFacilityPositionManager(facility)
      .withdrawManager(intentId, withdrawAmount, repayAmount, useTarget, WithdrawalStrategy.PROPORTIONAL);
    // A partial withdrawal queue can remove more quoted value than the aggregate estimate.
    if (manager.debtAmount() > manager.collateralAmountQuoted().mulDiv(targetLtv, _WAD)) revert TargetLtvExceeded();

    IFacilityFunds(facility).commit(intentId);
    IFacilityFunds(facility).unlock(intentId);
  }
}
