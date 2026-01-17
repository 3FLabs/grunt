// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {Order} from "../Order.sol";
import {LibTokenBalances} from "./LibTokenBalances.sol";
import {LibErrors} from "./LibErrors.sol";
import {IFacilityIntents} from "../../interfaces/facility/base/IFacilityIntents.sol";
import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibAddress} from "./LibAddress.sol";
import {IRequestInteractions} from "../../interfaces/request/IRequestInteractions.sol";

/// @dev Asset configuration for intents and swaps.
/// @param asset Address of the asset.
/// @param isPositionManager Whether the asset represents a position manager.
struct Asset {
  address asset;
  bool isPositionManager;
}

/// @dev Configuration values that define an intent's behavior.
/// @param depositAsset Asset deposited into the intent.
/// @param targetAsset Target asset or position manager for the intent.
/// @param depositCap Maximum amount that can be deposited into the intent.
/// @param guardKey Guard key address associated with intent authorization.
/// @param resolveStart Earliest timestamp when the intent can be resolved.
/// @param quorum Quorum threshold required for guard approvals.
struct IntentProperties {
  Asset depositAsset;
  Asset targetAsset;
  uint256 depositCap;
  address guardKey;
  uint40 resolveStart;
  uint8 quorum;
}

/// @dev Intent state for a facility request, including configuration and accounting.
/// @param properties Static configuration for the intent.
/// @param fund Fund address associated with the intent.
/// @param request Request contract address associated with the intent.
/// @param resolved Whether the intent has been resolved and claims are enabled.
/// @param amounts Per-address accounting balances for the intent.
/// @param order Current fund order associated with the intent.
/// @param totalSupply Total supply tracked for the intent.
struct Intent {
  IntentProperties properties;
  address fund;
  address request;
  bool resolved;
  EnumerableMapLib.AddressToUint256Map amounts;
  Order order;
  uint256 totalSupply;
}

/// @title LibIntent
/// @notice Library for Intent storage operations.
library LibIntent {
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;
  using LibIntent for Intent;
  using FixedPointMathLib for bool;
  using LibAddress for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        STATE CHECKS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns true if the intent is in the depositing phase.
  /// @param _intent The intent to check.
  /// @return True if depositing, false otherwise.
  function isDepositing(Intent storage _intent) internal view returns (bool) {
    return !_intent.resolved && _intent.properties.resolveStart > block.timestamp;
  }

  /// @dev Returns true if the intent is in the resolving phase.
  /// @param _intent The intent to check.
  /// @return True if resolving, false otherwise.
  function isResolving(Intent storage _intent) internal view returns (bool) {
    return _intent.properties.resolveStart <= block.timestamp && !_intent.resolved;
  }

  /// @dev Returns true if the intent has been resolved.
  /// @param _intent The intent to check.
  /// @return True if resolved, false otherwise.
  function isResolved(Intent storage _intent) internal view returns (bool) {
    return _intent.resolved;
  }

  /// @dev Returns true if the intent has an active order.
  /// @param _intent The intent to check.
  /// @return True if active order, false otherwise.
  function hasActiveOrder(Intent storage _intent) internal view returns (bool) {
    return _intent.order.owner != address(0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         VALIDATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Checks if the deposit amount would exceed the intent's deposit cap.
  ///      Reverts with DepositCapExceeded if the cap would be exceeded.
  /// @param _intent The intent to check.
  /// @param id The intent ID (for error reporting).
  /// @param amount The amount to deposit.
  function checkCap(Intent storage _intent, uint256 id, uint256 amount) internal view {
    uint256 attemptedTotal = _intent.totalSupply + amount;
    if (attemptedTotal > _intent.properties.depositCap) {
      revert LibErrors.DepositCapExceeded(id, _intent.properties.depositCap, attemptedTotal);
    }
  }

  /// @dev Checks if the request is repaid.
  ///      Reverts if the request is not repaid.
  /// @param _intent The intent to check.
  function checkRequestRepaid(Intent storage _intent) internal view {
    address _request = _intent.request;
    if (_request != address(0) && !IRequestInteractions(_request).isRepaid()) {
      revert LibErrors.RequestNotRepaid(_request);
    }
  }

  /// @dev Checks if the intent has no pending orders.
  ///      Reverts if the intent has an active order.
  /// @param _intent The intent to check.
  /// @param id The intent ID.
  function checkNoPendingOrder(Intent storage _intent, uint256 id) internal view {
    if (_intent.hasActiveOrder()) revert LibErrors.ActiveOrder(id);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Initializes an intent with the deposit asset and quorum.
  ///      Emits the IntentCreated event.
  ///      This does not revert if the intent already exists, so make sure the intent does not already exist.
  ///      The deposit asset must be a contract.
  /// @param _intent The intent to initialize.
  /// @param id The intent ID.
  /// @param depositAsset The deposit asset configuration.
  /// @param quorum The quorum threshold for guard approvals.
  function init(Intent storage _intent, uint256 id, Asset calldata depositAsset, uint8 quorum) internal {
    depositAsset.asset.checkContract();

    _intent.properties.depositAsset = depositAsset;
    _intent.properties.quorum = quorum;
    emit IFacilityIntents.IntentCreated(id, depositAsset, quorum);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UPDATES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Validates and updates the target asset and guard key for an intent.
  ///      The new target asset must be a contract.
  /// @param _intent The intent storage reference.
  /// @param id The intent ID.
  /// @param newTargetAsset The new target asset configuration.
  /// @param newGuardKey The new guard key address.
  function updateTargetAsset(Intent storage _intent, uint256 id, Asset memory newTargetAsset, address newGuardKey)
    internal
  {
    // we don't need to check the guard key, since it is either the deposit asset or the target asset
    // and both are checked to be contracts
    newTargetAsset.asset.checkContract();
    _checkAssetsAndGuardKey(_intent.properties.depositAsset, newTargetAsset, newGuardKey);

    _intent.properties.targetAsset = newTargetAsset;
    _intent.properties.guardKey = newGuardKey;
    emit IFacilityIntents.IntentTargetUpdated(id, newTargetAsset, newGuardKey);
  }

  /// @dev Updates the deposit cap for an intent.
  /// @param _intent The intent storage reference.
  /// @param id The intent ID.
  /// @param newDepositCap The new deposit cap.
  function updateDepositCap(Intent storage _intent, uint256 id, uint256 newDepositCap) internal {
    _intent.properties.depositCap = newDepositCap;
    emit IFacilityIntents.DepositCapUpdated(id, newDepositCap);
  }

  /// @dev Updates the resolve start timestamp for an intent.
  /// @param _intent The intent storage reference.
  /// @param id The intent ID.
  /// @param newResolveStart The new resolve start timestamp.
  function updateResolveStart(Intent storage _intent, uint256 id, uint40 newResolveStart) internal {
    _intent.properties.resolveStart = newResolveStart;
    emit IFacilityIntents.ResolveStartUpdated(id, newResolveStart);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PRIVATE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Validates that the deposit asset, target asset, and guard key are compatible.
  ///      At least one asset must be a position manager.
  ///      The guard key must match one of the position manager assets.
  /// @param depositAsset The deposit asset configuration.
  /// @param targetAsset The target asset configuration.
  /// @param guardKey The guard key address.
  function _checkAssetsAndGuardKey(Asset memory depositAsset, Asset memory targetAsset, address guardKey) private view {
    bool depositIsPm = depositAsset.isPositionManager;
    bool targetIsPm = targetAsset.isPositionManager;

    // At least one asset must be a position manager.
    if (!depositIsPm && !targetIsPm) revert LibErrors.MissingPositionManager();

    if (depositIsPm && !targetIsPm) {
      // If the deposit asset is the only position manager, the guard key must match the deposit asset,
      // and the target asset can be anything.
      if (guardKey != depositAsset.asset) revert LibErrors.InvalidGuardKey(guardKey);
      return;
    }

    // Get the collateral and debt assets of the position manager.
    (address _pmCollateral, address _pmDebt) = IPositionManager(guardKey).assets();

    if (!depositIsPm && targetIsPm) {
      // If the target asset is the only Position Manager, the guard key must match the target asset,
      if (guardKey != targetAsset.asset) revert LibErrors.InvalidGuardKey(guardKey);

      // and the deposit asset must be either the collateral or debt asset of the position manager.
      (address _pmCollateral, address _pmDebt) = IPositionManager(guardKey).assets();
      if (_pmCollateral != depositAsset.asset && _pmDebt != depositAsset.asset) {
        revert LibErrors.AssetMismatch(_pmCollateral, depositAsset.asset);
      }
    } else if (depositIsPm && targetIsPm) {
      // If both assets are position managers, the guard key must match one of the assets,
      if (guardKey != depositAsset.asset && guardKey != targetAsset.asset) revert LibErrors.InvalidGuardKey(guardKey);

      // and both position managers must have the same collateral and debt assets.
      (address _otherCollateral, address _otherDebt) =
        IPositionManager((guardKey == depositAsset.asset).ternary(targetAsset.asset, depositAsset.asset)).assets();
      _otherCollateral.checkAssetsMatch(_pmCollateral);
      _otherDebt.checkAssetsMatch(_pmDebt);
    }
  }
}
