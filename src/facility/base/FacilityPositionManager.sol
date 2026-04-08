// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilityPositionManager} from "src/interfaces/facility/base/IFacilityPositionManager.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {LibIntent, Intent, Asset, BalanceSnapshot} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";

/// @title FacilityPositionManager
/// @author 3F Protocol
/// @notice Abstract contract implementing position manager operations for intents.
/// @dev Allows depositing into, withdrawing from, and burning shares of position managers.
abstract contract FacilityPositionManager is IFacilityPositionManager, ReentrancyGuardTransient, FacilityRoles {
  using SafeTransferLib for address;
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;

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
    (
      Intent storage _intent,
      address _positionManager,
      address _collateralAsset,
      address _debtAsset,
      BalanceSnapshot memory collateralSnapshot,
      BalanceSnapshot memory debtSnapshot,
      BalanceSnapshot memory sharesSnapshot
    ) = _initialPmParameters(id, useTarget);

    if (depositAmount > 0) {
      // if we have non null collateral, approve the position manager to pull it
      _collateralAsset.safeApproveWithRetry(_positionManager, depositAmount);
    }

    // deposit the collateral and borrow the debt
    IPositionManager(_positionManager).deposit(depositAmount, borrowAmount);

    if (depositAmount > 0) {
      // reset approval to 0
      _collateralAsset.safeApproveWithRetry(_positionManager, 0);
    }

    // commit snapshots to record the balance changes
    _commitSnapshots(_intent, id, collateralSnapshot, debtSnapshot, sharesSnapshot, _positionManager);
  }

  /// @inheritdoc IFacilityPositionManager
  /// @dev Withdraws collateral from the position manager and repays debt.
  ///      The intent must be in resolving state and have enough debt to repay.
  function withdrawManager(
    uint256 id,
    uint256 withdrawAmount,
    uint256 repayAmount,
    bool useTarget,
    WithdrawalStrategy strategy
  ) external override nonReentrant onlyRoles(FACILITATOR_ROLE) {
    // getting the initial parameters
    (
      Intent storage _intent,
      address _positionManager,
      address _collateralAsset,
      address _debtAsset,
      BalanceSnapshot memory collateralSnapshot,
      BalanceSnapshot memory debtSnapshot,
      BalanceSnapshot memory sharesSnapshot
    ) = _initialPmParameters(id, useTarget);

    if (repayAmount > 0) {
      // if we have non null debt, approve the position manager to pull it
      _debtAsset.safeApproveWithRetry(_positionManager, repayAmount);
    }

    // repay the debt and withdraw the collateral
    IPositionManager(_positionManager).withdraw(withdrawAmount, repayAmount, strategy);

    if (repayAmount > 0) {
      // reset approval to 0
      _debtAsset.safeApproveWithRetry(_positionManager, 0);
    }

    // commit snapshots to record the balance changes
    _commitSnapshots(_intent, id, collateralSnapshot, debtSnapshot, sharesSnapshot, _positionManager);
  }

  /// @inheritdoc IFacilityPositionManager
  /// @dev Burns position manager shares by sending debt to the position manager and receiving collateral back.
  ///      The intent must be in resolving state and have enough debt to repay.
  function burnManager(uint256 id, uint256 shares, bool useTarget, WithdrawalStrategy strategy)
    external
    override
    nonReentrant
    onlyRoles(FACILITATOR_ROLE)
  {
    // getting the initial parameters
    (
      Intent storage _intent,
      address _positionManager,
      address _collateralAsset,
      address _debtAsset,
      BalanceSnapshot memory collateralSnapshot,
      BalanceSnapshot memory debtSnapshot,
      BalanceSnapshot memory sharesSnapshot
    ) = _initialPmParameters(id, useTarget);

    // give infinite approval of the debt asset to the position manager
    _debtAsset.safeApproveWithRetry(_positionManager, type(uint256).max);

    // burn the shares by sending debt to the position manager and receiving collateral back
    IPositionManager(_positionManager).burn(shares, strategy);

    // commit snapshots to record the balance changes
    _commitSnapshots(_intent, id, collateralSnapshot, debtSnapshot, sharesSnapshot, _positionManager);

    // reset approval of the debt asset to the position manager to 0
    _debtAsset.safeApproveWithRetry(_positionManager, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   INTERNALS OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Gets the initial parameters related to a position manager for a given intent.
  /// @dev Retrieves the resolving intent and reads either the targetAsset or depositAsset as the selected asset,
  ///      checks if it is a position manager, then fetches the related collateral and debt assets from the manager.
  ///      Reverts with `InvalidPositionManagerAssets()` if collateralAsset, debtAsset, or positionManager overlap,
  ///      preventing snapshot-based double-counting attacks (CS-GRUNT-062).
  /// @param id The intent id.
  /// @param useTarget If true, use the targetAsset; otherwise, use the depositAsset.
  /// @return _intent Storage pointer to the retrieved intent struct.
  /// @return positionManager Address of the position manager contract.
  /// @return collateralAsset Address of the collateral asset handled by the position manager.
  /// @return debtAsset Address of the debt asset handled by the position manager.
  /// @return collateralSnapshot Snapshot of the collateral asset balance before the operation.
  /// @return debtSnapshot Snapshot of the debt asset balance before the operation.
  /// @return sharesSnapshot Snapshot of the shares balance before the operation.
  function _initialPmParameters(uint256 id, bool useTarget)
    private
    view
    returns (
      Intent storage _intent,
      address positionManager,
      address collateralAsset,
      address debtAsset,
      BalanceSnapshot memory collateralSnapshot,
      BalanceSnapshot memory debtSnapshot,
      BalanceSnapshot memory sharesSnapshot
    )
  {
    // check if the facility is paused
    LibStorage.checkNotPaused();
    // getting the resolving intent
    _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // getting the selected asset (simple ternary since we read from storage)
    Asset storage _selected = useTarget ? _intent.properties.targetAsset : _intent.properties.depositAsset;
    // ensure the selected asset is a position manager
    if (!_selected.isPositionManager) revert LibFacilityErrors.AssetNotPositionManager(_selected.asset);

    // get the position manager address
    positionManager = _selected.asset;
    // get the position manager assets
    (collateralAsset, debtAsset) = IPositionManager(positionManager).assets();

    // if (collateralAsset == debtAsset || collateralAsset == positionManager || debtAsset == positionManager)
    //   revert LibFacilityErrors.InvalidPositionManagerAssets();
    assembly ("memory-safe") {
      if or(eq(collateralAsset, debtAsset), or(eq(collateralAsset, positionManager), eq(debtAsset, positionManager))) {
        mstore(0, 0x62e437a4) // LibFacilityErrors.InvalidPositionManagerAssets()
        revert(0x1c, 0x04)
      }
    }

    // take snapshots before the operation
    collateralSnapshot = LibIntent.takeBalanceSnapshot(collateralAsset);
    debtSnapshot = LibIntent.takeBalanceSnapshot(debtAsset);
    sharesSnapshot = LibIntent.takeBalanceSnapshot(positionManager);
  }

  /// @notice Commits all balance snapshots after a position manager operation.
  /// @dev Records balance changes for collateral, debt, and shares by comparing
  ///      pre-operation snapshots with current balances.
  /// @param _intent Storage pointer to the intent struct.
  /// @param id The intent id.
  /// @param collateralSnapshot Snapshot of the collateral asset balance before the operation.
  /// @param debtSnapshot Snapshot of the debt asset balance before the operation.
  /// @param sharesSnapshot Snapshot of the shares balance before the operation.
  /// @param positionManager Address of the position manager (counterparty for collateral/debt events).
  function _commitSnapshots(
    Intent storage _intent,
    uint256 id,
    BalanceSnapshot memory collateralSnapshot,
    BalanceSnapshot memory debtSnapshot,
    BalanceSnapshot memory sharesSnapshot,
    address positionManager
  ) private {
    _intent.commitBalanceSnapshot(id, collateralSnapshot, positionManager);
    _intent.commitBalanceSnapshot(id, debtSnapshot, positionManager);
    _intent.commitBalanceSnapshot(id, sharesSnapshot, address(0));
  }
}
