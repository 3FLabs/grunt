// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilityPositionManager} from "src/interfaces/facility/base/IFacilityPositionManager.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";
import {LibIntent, Intent, Asset} from "src/libs/facility/LibIntent.sol";
import {LibTokenBalances} from "src/libs/facility/LibTokenBalances.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";

/// @title FacilityPositionManager
/// @notice Abstract contract implementing position manager operations for intents.
/// @dev Allows depositing into, withdrawing from, and burning shares of position managers.
abstract contract FacilityPositionManager is IFacilityPositionManager, ReentrancyGuardTransient, FacilityRoles {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityPositionManager
  /// @dev Deposits collateral into the position manager and optionally borrows debt.
  ///      The intent must be in resolving state. Updates internal accounting for
  ///      collateral, debt, and position manager shares.
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    Asset storage selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    if (!selected.isPositionManager) revert LibErrors.AssetNotPositionManager(selected.asset);

    address positionManager = selected.asset;
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();

    if (depositAmount > 0) {
      _intent.amounts.sub(collateralAsset, depositAmount);
      collateralAsset.safeApproveWithRetry(positionManager, depositAmount);
    }

    int256 shares = IPositionManager(positionManager).deposit(depositAmount, borrowAmount);

    if (borrowAmount > 0) {
      _intent.amounts.add(debtAsset, borrowAmount);
    }

    if (shares > 0) {
      _intent.amounts.add(positionManager, uint256(shares));
    } else if (shares < 0) {
      _intent.amounts.sub(positionManager, uint256(-shares));
    }

    // TODO - emit events
  }

  /// @inheritdoc IFacilityPositionManager
  /// @dev Withdraws collateral from the position manager and optionally repays debt.
  ///      The intent must be in resolving state. Updates internal accounting for
  ///      collateral, debt, and position manager shares.
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount, bool useTarget)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    Asset storage selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    if (!selected.isPositionManager) revert LibErrors.AssetNotPositionManager(selected.asset);

    address positionManager = selected.asset;
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();

    if (repayAmount > 0) {
      _intent.amounts.sub(debtAsset, repayAmount);
      debtAsset.safeApproveWithRetry(positionManager, repayAmount);
    }

    int256 shares = IPositionManager(positionManager).withdraw(withdrawAmount, repayAmount);

    if (withdrawAmount > 0) {
      _intent.amounts.add(collateralAsset, withdrawAmount);
    }

    if (shares > 0) {
      _intent.amounts.add(positionManager, uint256(shares));
    } else if (shares < 0) {
      _intent.amounts.sub(positionManager, uint256(-shares));
    }

    // TODO - emit events
  }

  /// @inheritdoc IFacilityPositionManager
  /// @dev Burns position manager shares and receives collateral back.
  ///      The intent must be in resolving state. Calculates required debt repayment
  ///      proportional to shares being burned. Updates internal accounting.
  function burnManager(uint256 id, uint256 shares, bool useTarget)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    Asset storage selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    if (!selected.isPositionManager) revert LibErrors.AssetNotPositionManager(selected.asset);

    address positionManager = selected.asset;
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();

    uint256 debtAmount = IPositionManager(positionManager).debtAmount();
    uint256 totalSupply_ = IERC20(positionManager).totalSupply();
    uint256 debtNeeded = debtAmount.mulDivUp(shares, totalSupply_);

    _intent.amounts.sub(positionManager, shares);
    if (debtNeeded > 0) {
      _intent.amounts.sub(debtAsset, debtNeeded);
      debtAsset.safeApproveWithRetry(positionManager, debtNeeded);
    }

    (uint256 collateral, uint256 debt) = IPositionManager(positionManager).burn(shares);

    if (debt != debtNeeded) revert LibErrors.AmountMismatch(debtNeeded, debt);
    if (collateral > 0) {
      _intent.amounts.add(collateralAsset, collateral);
    }

    // TODO - emit events
  }
}
