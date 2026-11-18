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

  /// @dev Resolved parameters and pre-operation balance snapshots of a position manager
  ///      operation, bundled so the three operations share one prologue and one epilogue.
  struct PmContext {
    address positionManager;
    address collateralAsset;
    address debtAsset;
    BalanceSnapshot collateralSnapshot;
    BalanceSnapshot debtSnapshot;
    BalanceSnapshot sharesSnapshot;
  }

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
    (Intent storage _intent, PmContext memory ctx) = _initialPmParameters(id, useTarget);

    if (depositAmount > 0) {
      // if we have non null collateral, approve the position manager to pull it
      ctx.collateralAsset.safeApproveWithRetry(ctx.positionManager, depositAmount);
    }

    // deposit the collateral and borrow the debt
    IPositionManager(ctx.positionManager).deposit(depositAmount, borrowAmount);

    if (depositAmount > 0) {
      // reset approval to 0
      ctx.collateralAsset.safeApproveWithRetry(ctx.positionManager, 0);
    }

    // commit snapshots to record the balance changes
    _commitSnapshots(_intent, id, ctx);
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
    (Intent storage _intent, PmContext memory ctx) = _initialPmParameters(id, useTarget);

    if (repayAmount > 0) {
      // if we have non null debt, approve the position manager to pull it
      ctx.debtAsset.safeApproveWithRetry(ctx.positionManager, repayAmount);
    }

    // repay the debt and withdraw the collateral
    IPositionManager(ctx.positionManager).withdraw(withdrawAmount, repayAmount, strategy);

    if (repayAmount > 0) {
      // reset approval to 0
      ctx.debtAsset.safeApproveWithRetry(ctx.positionManager, 0);
    }

    // commit snapshots to record the balance changes
    _commitSnapshots(_intent, id, ctx);
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
    (Intent storage _intent, PmContext memory ctx) = _initialPmParameters(id, useTarget);

    // give infinite approval of the debt asset to the position manager
    ctx.debtAsset.safeApproveWithRetry(ctx.positionManager, type(uint256).max);

    // burn the shares by sending debt to the position manager and receiving collateral back
    IPositionManager(ctx.positionManager).burn(shares, strategy);

    // commit snapshots to record the balance changes
    _commitSnapshots(_intent, id, ctx);

    // reset approval of the debt asset to the position manager to 0
    ctx.debtAsset.safeApproveWithRetry(ctx.positionManager, 0);
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
  /// @return ctx The resolved position manager, its assets and the pre-operation balance snapshots.
  function _initialPmParameters(uint256 id, bool useTarget)
    private
    view
    returns (Intent storage _intent, PmContext memory ctx)
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
    address positionManager = _selected.asset;
    // get the position manager assets
    (address collateralAsset, address debtAsset) = IPositionManager(positionManager).assets();

    // if (collateralAsset == debtAsset || collateralAsset == positionManager || debtAsset == positionManager)
    //   revert LibFacilityErrors.InvalidPositionManagerAssets();
    assembly ("memory-safe") {
      if or(eq(collateralAsset, debtAsset), or(eq(collateralAsset, positionManager), eq(debtAsset, positionManager))) {
        mstore(0, 0x62e437a4) // LibFacilityErrors.InvalidPositionManagerAssets()
        revert(0x1c, 0x04)
      }
    }

    // take snapshots before the operation
    ctx.positionManager = positionManager;
    ctx.collateralAsset = collateralAsset;
    ctx.debtAsset = debtAsset;
    ctx.collateralSnapshot = LibIntent.takeBalanceSnapshot(collateralAsset);
    ctx.debtSnapshot = LibIntent.takeBalanceSnapshot(debtAsset);
    ctx.sharesSnapshot = LibIntent.takeBalanceSnapshot(positionManager);
  }

  /// @notice Commits all balance snapshots after a position manager operation.
  /// @dev Records balance changes for collateral, debt, and shares by comparing
  ///      pre-operation snapshots with current balances. The share delta includes any fee shares
  ///      minted to this Facility during the operation, so a managed PositionManager's
  ///      `feeRecipient` must never be this Facility.
  /// @param _intent Storage pointer to the intent struct.
  /// @param id The intent id.
  /// @param ctx The position manager context with the pre-operation snapshots.
  function _commitSnapshots(Intent storage _intent, uint256 id, PmContext memory ctx) private {
    _intent.commitBalanceSnapshot(id, ctx.collateralSnapshot, ctx.positionManager);
    _intent.commitBalanceSnapshot(id, ctx.debtSnapshot, ctx.positionManager);
    _intent.commitBalanceSnapshot(id, ctx.sharesSnapshot, address(0));
  }
}
