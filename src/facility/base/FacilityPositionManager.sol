// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilityPositionManager} from "src/interfaces/facility/base/IFacilityPositionManager.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {LibIntent, Intent, Asset} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";

/// @title FacilityPositionManager
/// @author 3F Protocol
/// @notice Abstract contract implementing position manager operations for intents.
/// @dev Allows depositing into, withdrawing from, and burning shares of position managers.
abstract contract FacilityPositionManager is IFacilityPositionManager, ReentrancyGuardTransient, FacilityRoles {
  using SafeTransferLib for address;
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;
  using SafeCastLib for int256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityPositionManager
  /// @dev Deposits collateral into the position manager and borrows debt.
  ///      The intent must be in resolving state and have enough collateral to deposit.
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    // getting the initial parameters
    (Intent storage _intent, address _positionManager, address _collateralAsset, address _debtAsset) =
      _intialPmParameters(id, useTarget);

    if (depositAmount > 0) {
      // if we have non null collateral, transfer it to the position manager
      _intent.transferredTokenTo(id, _collateralAsset, _positionManager, depositAmount);
      _collateralAsset.safeApproveWithRetry(_positionManager, depositAmount);
    }

    // deposit the collateral and borrow the debt
    int256 shares = IPositionManager(_positionManager).deposit(depositAmount, borrowAmount);

    if (borrowAmount > 0) {
      // if we have non null debt, mark it as received from the position manager
      _intent.receivedTokenFrom(id, _debtAsset, _positionManager, borrowAmount);
    }

    // handle the shares change
    _handleSharesChange(_intent, id, _positionManager, shares);
  }

  /// @inheritdoc IFacilityPositionManager
  /// @dev Withdraws collateral from the position manager and repays debt.
  ///      The intent must be in resolving state and have enough debt to repay.
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount, bool useTarget)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    // getting the initial parameters
    (Intent storage _intent, address _positionManager, address _collateralAsset, address _debtAsset) =
      _intialPmParameters(id, useTarget);

    if (repayAmount > 0) {
      // if we have non null debt, transfer it to the position manager
      _intent.transferredTokenTo(id, _debtAsset, _positionManager, repayAmount);
      _debtAsset.safeApproveWithRetry(_positionManager, repayAmount);
    }

    // repay the debt and withdraw the collateral
    int256 shares = IPositionManager(_positionManager).withdraw(withdrawAmount, repayAmount);

    if (withdrawAmount > 0) {
      // if we have non null collateral, mark it as received from the position manager
      _intent.receivedTokenFrom(id, _collateralAsset, _positionManager, withdrawAmount);
    }

    // handle the shares change
    _handleSharesChange(_intent, id, _positionManager, shares);
  }

  /// @inheritdoc IFacilityPositionManager
  /// @dev Burns position manager shares by sending debt to the position manager and receiving collateral back.
  ///      The intent must be in resolving state and have enough debt to repay.
  function burnManager(uint256 id, uint256 shares, bool useTarget)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    // getting the initial parameters
    (Intent storage _intent, address _positionManager, address _collateralAsset, address _debtAsset) =
      _intialPmParameters(id, useTarget);

    // give infinite approval of the debt asset to the position manager
    _debtAsset.safeApproveWithRetry(_positionManager, type(uint256).max);

    // burn the shares by sending debt to the position manager and receiving collateral back
    (uint256 collateral, uint256 debt) = IPositionManager(_positionManager).burn(shares);

    // marked the shares as burned (safe to call after burn since we are non reentrant)
    _intent.transferredTokenTo(id, _positionManager, address(0), shares);

    if (debt > 0) {
      // if we have non null debt, transfer it to the position manager (reverts if not enough debt)
      _intent.transferredTokenTo(id, _debtAsset, _positionManager, debt);
    }

    if (collateral > 0) {
      // if we have non null collateral, mark it as received from the position manager
      _intent.receivedTokenFrom(id, _collateralAsset, _positionManager, collateral);
    }

    // reset approval of the debt asset to the position manager to 0
    _debtAsset.safeApproveWithRetry(_positionManager, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   INTERNALS OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Gets the initial parameters related to a position manager for a given intent.
  /// @dev Retrieves the resolving intent and reads either the targetAsset or depositAsset as the selected asset,
  ///      checks if it is a position manager, then fetches the related collateral and debt assets from the manager.
  /// @param id The intent id.
  /// @param useTarget If true, use the targetAsset; otherwise, use the depositAsset.
  /// @return _intent Storage pointer to the retrieved intent struct.
  /// @return positionManager Address of the position manager contract.
  /// @return collateralAsset Address of the collateral asset handled by the position manager.
  /// @return debtAsset Address of the debt asset handled by the position manager.
  function _intialPmParameters(uint256 id, bool useTarget)
    private
    view
    returns (Intent storage _intent, address positionManager, address collateralAsset, address debtAsset)
  {
    _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // getting the selected asset (simple ternary since we read from storage)
    Asset storage _selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    // ensure the selected asset is a position manager
    if (!_selected.isPositionManager) revert LibErrors.AssetNotPositionManager(_selected.asset);

    // get the position manager address
    positionManager = _selected.asset;
    // get the position manager assets
    (collateralAsset, debtAsset) = IPositionManager(positionManager).assets();
  }

  /// @notice Handles an update in shares for a position manager, recording the transfer in the intent.
  /// @dev Mints shares if positive, burns shares if negative, and calls appropriate intent functions to record.
  /// @param _intent Storage pointer to the current intent struct.
  /// @param id The intent id.
  /// @param positionManager Address of the position manager.
  /// @param shares The signed change in shares (positive for mint, negative for burn).
  function _handleSharesChange(Intent storage _intent, uint256 id, address positionManager, int256 shares) private {
    if (shares > 0) {
      // if shares are positive, mark them as received from address(0) (since we are minting shares)
      _intent.receivedTokenFrom(id, positionManager, address(0), shares.toUint256());
    } else if (shares < 0) {
      // if shares are negative, mark them as transferred to address(0) (since we are burning shares)
      _intent.transferredTokenTo(id, positionManager, address(0), (-shares).toUint256());
    }
  }
}
