// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {Order, State} from "../funds/Order.sol";
import {LibTokenBalances} from "./LibTokenBalances.sol";
import {LibFacilityErrors} from "./LibFacilityErrors.sol";
import {IFacility} from "../../interfaces/facility/IFacility.sol";
import {IFacilityIntents} from "../../interfaces/facility/base/IFacilityIntents.sol";
import {IPositionManager} from "../../interfaces/manager/IPositionManager.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibAddress} from "./LibAddress.sol";
import {LibChecks} from "../common/LibChecks.sol";
import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {IRequest} from "../../interfaces/request/IRequest.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {LibStorage, FacilityStorageData} from "./LibStorage.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";

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
/// @param resolveStart Timestamp at which the deposit phase ends and the resolving phase begins.
/// @param quorum Quorum threshold required for guard approvals.
/// @param transferableIntent If false, intent token transfers are disabled (mint/burn unaffected).
struct IntentProperties {
  Asset depositAsset;
  Asset targetAsset;
  uint256 depositCap;
  address guardKey;
  uint40 resolveStart;
  uint8 quorum;
  bool transferableIntent;
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

/// @dev Struct to capture a token balance snapshot for non-transfer balance changes.
/// @param token The token address.
/// @param balance The ERC20 balanceOf(facility) at the time of the snapshot.
struct BalanceSnapshot {
  address token;
  uint256 balance;
}

/// @title LibIntent
/// @author 3F Protocol
/// @notice Library for Intent storage operations.
/// @dev Provides functions for intent state checks, validation, initialization,
///      updates, and token transfer accounting.
library LibIntent {
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;
  using LibIntent for Intent;
  using FixedPointMathLib for bool;
  using LibChecks for address;
  using LibAddress for address;
  using SafeTransferLib for address;
  using LibStorage for FacilityStorageData;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        STATE CHECKS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Checks if the intent is in the depositing phase.
  /// @dev The intent is depositing if it is not resolved and the resolve start time has not passed.
  /// @param _self The intent storage reference.
  /// @return True if the intent is in the depositing phase, false otherwise.
  function isDepositing(Intent storage _self) internal view returns (bool) {
    return !_self.resolved && _self.properties.resolveStart > block.timestamp;
  }

  /// @notice Checks if the intent is in the resolving phase.
  /// @dev The intent is resolving if the resolve start time has passed and it is not yet resolved.
  /// @param _self The intent storage reference.
  /// @return True if the intent is in the resolving phase, false otherwise.
  function isResolving(Intent storage _self) internal view returns (bool) {
    return _self.properties.resolveStart <= block.timestamp && !_self.resolved;
  }

  /// @notice Checks if the intent has been resolved.
  /// @dev Once resolved, claims are enabled for depositors.
  /// @param _self The intent storage reference.
  /// @return True if the intent has been resolved, false otherwise.
  function isResolved(Intent storage _self) internal view returns (bool) {
    return _self.resolved;
  }

  /// @notice Checks if the intent has an active fund order.
  /// @dev An order is considered active if its owner address is not zero.
  /// @param _self The intent storage reference.
  /// @return True if the intent has an active order, false otherwise.
  function hasActiveOrder(Intent storage _self) internal view returns (bool) {
    return _self.order.owner != address(0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         VALIDATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Validates that a deposit amount does not exceed the intent's deposit cap.
  /// @dev Reverts with DepositCapExceeded if the total supply after deposit would exceed the cap.
  /// @param _self The intent storage reference.
  /// @param id The intent ID (used for error reporting).
  /// @param amount The amount being deposited.
  function checkCap(Intent storage _self, uint256 id, uint256 amount) internal view {
    uint256 attemptedTotal = _self.totalSupply + amount;
    if (attemptedTotal > _self.properties.depositCap) {
      revert LibFacilityErrors.DepositCapExceeded(id, _self.properties.depositCap, attemptedTotal);
    }
  }

  /// @notice Validates that the intent's associated request has been repaid.
  /// @dev Reverts with RequestNotRepaid if a request exists and is not repaid.
  ///      Calls syncRepaidStatus() to trigger automatic repayment if the deadline has passed.
  ///      Does nothing if no request is associated with the intent.
  /// @param _self The intent storage reference.
  function checkRequestRepaid(Intent storage _self) internal {
    address _request = _self.request;
    if (_request != address(0) && !IRequest(_request).syncRepaidStatus()) {
      revert LibFacilityErrors.RequestNotRepaid(_request);
    }
  }

  /// @notice Syncs the intent's order state with the fund when the fund reports ENDED.
  /// @dev Queries IFund.state(order) and clears the stale order+fund binding when the fund
  ///      has independently ended the order (e.g. via forceEnd). Does nothing if there is
  ///      no active order or no fund.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  function syncEndedOrder(Intent storage _self, uint256 id) internal {
    if (!_self.hasActiveOrder()) return;

    address _fund = _self.fund;
    if (_fund == address(0)) return;

    if (IFund(_fund).state(_self.order) == State.ENDED) {
      _self.removeOrderAndFund(id);
    }
  }

  /// @notice Validates that the intent has no pending fund orders.
  /// @dev Reverts with ActiveOrder if the intent has an active order.
  /// @param _self The intent storage reference.
  /// @param id The intent ID (used for error reporting).
  function checkNoPendingOrder(Intent storage _self, uint256 id) internal view {
    if (_self.hasActiveOrder()) revert LibFacilityErrors.ActiveOrder(id);
  }

  /// @notice Validates that the intent has an active fund order.
  /// @dev Reverts with NoActiveOrder if the intent does not have an active order.
  /// @param _self The intent storage reference.
  /// @param id The intent ID (used for error reporting).
  function checkActiveOrder(Intent storage _self, uint256 id) internal view {
    if (!_self.hasActiveOrder()) revert LibFacilityErrors.NoActiveOrder(id);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes an intent with the deposit asset and quorum.
  /// @dev Sets the deposit asset and quorum, then emits IntentCreated.
  ///      The deposit asset must be a deployed contract.
  ///      Does not check if the intent already exists - caller must ensure this.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param depositAsset The deposit asset configuration.
  /// @param quorum The quorum threshold required for guardian approvals.
  /// @param transferableIntent Whether intent token transfers are allowed.
  function init(Intent storage _self, uint256 id, Asset calldata depositAsset, uint8 quorum, bool transferableIntent)
    internal
  {
    depositAsset.asset.checkContract();

    _self.properties.depositAsset = depositAsset;
    _self.properties.quorum = quorum;
    _self.properties.transferableIntent = transferableIntent;
    emit IFacilityIntents.IntentCreated(id, depositAsset, quorum, transferableIntent);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UPDATES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Updates the target asset and guard key for an intent.
  /// @dev Validates that the new configuration is compatible with the deposit asset.
  ///      The new target asset must be a deployed contract.
  ///      Emits IntentTargetUpdated on success.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param newTargetAsset The new target asset configuration.
  /// @param newGuardKey The new guard key address.
  function updateTargetAsset(Intent storage _self, uint256 id, Asset memory newTargetAsset, address newGuardKey)
    internal
  {
    // we don't need to check the guard key, since it is either the deposit asset or the target asset
    // and both are checked to be contracts
    newTargetAsset.asset.checkContract();
    _checkAssetsAndGuardKey(_self.properties.depositAsset, newTargetAsset, newGuardKey);

    _self.properties.targetAsset = newTargetAsset;
    _self.properties.guardKey = newGuardKey;
    emit IFacilityIntents.IntentTargetUpdated(id, newTargetAsset, newGuardKey);
  }

  /// @notice Updates the deposit cap for an intent.
  /// @dev Emits DepositCapUpdated on success.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param newDepositCap The new maximum deposit amount.
  function updateDepositCap(Intent storage _self, uint256 id, uint256 newDepositCap) internal {
    _self.properties.depositCap = newDepositCap;
    emit IFacilityIntents.DepositCapUpdated(id, newDepositCap);
  }

  /// @notice Updates the resolve start timestamp for an intent.
  /// @dev Emits ResolveStartUpdated on success.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param newResolveStart The new resolve start timestamp.
  function updateResolveStart(Intent storage _self, uint256 id, uint40 newResolveStart) internal {
    _self.properties.resolveStart = newResolveStart;
    emit IFacilityIntents.ResolveStartUpdated(id, newResolveStart);
  }

  /// @notice Removes the order and fund from the intent.
  /// @dev Emits FundUpdated on success.
  ///      Before calling, we must ensure the order is not active.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  function removeOrderAndFund(Intent storage _self, uint256 id) internal {
    delete _self.order;
    LibStorage.facilityStorage().abandonFund(_self.fund);
    _self.fund = address(0);
    emit IFacilityIntents.FundUpdated(id, address(0));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     TOKEN TRANSFERS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Records that tokens were sent from the intent without performing the transfer.
  /// @dev Updates the intent's token accounting and emits TokenSent.
  ///      Use this when the transfer has already been performed externally.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param token The token address that was transferred.
  /// @param to The recipient address.
  /// @param amount The amount that was transferred.
  function _transferredTokenTo(Intent storage _self, uint256 id, address token, address to, uint256 amount) private {
    _self.amounts.sub(token, amount);
    emit IFacility.TokenSent(id, token, to, amount);
  }

  /// @notice Transfers tokens from the intent to a recipient and updates accounting.
  /// @dev Updates intent accounting before performing the transfer (checks-effects-interactions)
  ///      to prevent read-only reentrancy via token callbacks observing inconsistent state.
  ///      Emits TokenSent on success.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param token The token address to transfer.
  /// @param to The recipient address.
  /// @param amount The amount to transfer.
  function transferTokenTo(Intent storage _self, uint256 id, address token, address to, uint256 amount) internal {
    _transferredTokenTo(_self, id, token, to, amount);
    token.safeTransfer(to, amount);
  }

  /// @notice Records that tokens were received by the intent without performing the transfer.
  /// @dev Updates the intent's token accounting and emits TokenReceived.
  ///      Use this when the transfer has already been performed externally.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param token The token address that was received.
  /// @param from The sender address.
  /// @param amount The amount that was received.
  function _receivedTokenFrom(Intent storage _self, uint256 id, address token, address from, uint256 amount) private {
    _self.amounts.add(token, amount);
    emit IFacility.TokenReceived(id, token, from, amount);
  }

  /// @notice Transfers tokens from a sender to the intent and updates accounting.
  /// @dev Performs a safe transferFrom and then records the transfer in intent accounting.
  ///      Emits TokenReceived on success.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param token The token address to transfer.
  /// @param from The sender address (must have approved this contract).
  /// @param amount The amount to transfer.
  function receiveTokenFrom(Intent storage _self, uint256 id, address token, address from, uint256 amount) internal {
    token.safeTransferFrom(from, address(this), amount);
    _receivedTokenFrom(_self, id, token, from, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    BALANCE SNAPSHOTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Takes a snapshot of the facility's ERC20 balance for a token.
  /// @dev Creates a BalanceSnapshot struct capturing the token address and current balanceOf.
  ///      The snapshot can later be committed to record the balance difference.
  /// @param token The token address to snapshot.
  /// @return snapshot The balance snapshot struct.
  function takeBalanceSnapshot(address token) internal view returns (BalanceSnapshot memory snapshot) {
    snapshot = BalanceSnapshot({token: token, balance: IERC20(token).balanceOf(address(this))});
  }

  /// @notice Commits a balance snapshot by calculating the difference and updating accounting.
  /// @dev Compares the snapshot balance with the current ERC20 balance and updates internal accounting.
  ///      Emits TokenReceived if balance increased, TokenSent if balance decreased.
  /// @param _self The intent storage reference.
  /// @param id The intent ID.
  /// @param snapshot The snapshot to commit.
  /// @param counterparty The address to use as from/to in the emitted event.
  function commitBalanceSnapshot(
    Intent storage _self,
    uint256 id,
    BalanceSnapshot memory snapshot,
    address counterparty
  ) internal {
    unchecked {
      uint256 currentBalance = IERC20(snapshot.token).balanceOf(address(this));

      if (currentBalance > snapshot.balance) {
        // Balance increased - record as received
        uint256 amount = currentBalance - snapshot.balance;
        _receivedTokenFrom(_self, id, snapshot.token, counterparty, amount);
      } else if (currentBalance < snapshot.balance) {
        // Balance decreased - record as sent
        uint256 amount = snapshot.balance - currentBalance;
        _transferredTokenTo(_self, id, snapshot.token, counterparty, amount);
      }
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PRIVATE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Validates that the deposit asset, target asset, and guard key are compatible.
  /// @dev At least one asset must be a position manager.
  ///      When only the deposit is a PM, the guard key must match it.
  ///      When only the target is a PM, the guard key must match it and the deposit must be its collateral or debt.
  ///      When both are PMs, they must share the same collateral and debt assets.
  /// @param depositAsset The deposit asset configuration.
  /// @param targetAsset The target asset configuration.
  /// @param guardKey The guard key address (must be one of the position managers).
  function _checkAssetsAndGuardKey(Asset memory depositAsset, Asset memory targetAsset, address guardKey) private view {
    bool depositIsPm = depositAsset.isPositionManager;
    bool targetIsPm = targetAsset.isPositionManager;

    // At least one asset must be a position manager.
    if (!depositIsPm && !targetIsPm) revert LibFacilityErrors.MissingPositionManager();

    if (depositIsPm && !targetIsPm) {
      // If the deposit asset is the only position manager, the guard key must match the deposit asset,
      // and the target asset can be anything.
      if (guardKey != depositAsset.asset) revert LibFacilityErrors.InvalidGuardKey(guardKey);
      return;
    }

    // Get the collateral and debt assets of the position manager.
    (address _pmCollateral, address _pmDebt) = IPositionManager(guardKey).assets();

    if (!depositIsPm && targetIsPm) {
      // If the target asset is the only Position Manager, the guard key must match the target asset,
      if (guardKey != targetAsset.asset) revert LibFacilityErrors.InvalidGuardKey(guardKey);

      // and the deposit asset must be either the collateral or debt asset of the position manager.
      if (_pmCollateral != depositAsset.asset && _pmDebt != depositAsset.asset) {
        revert LibFacilityErrors.AssetMismatch(_pmCollateral, depositAsset.asset);
      }
    } else if (depositIsPm && targetIsPm) {
      // If both assets are position managers, the guard key must match one of the assets,
      if (guardKey != depositAsset.asset && guardKey != targetAsset.asset) {
        revert LibFacilityErrors.InvalidGuardKey(guardKey);
      }

      // and both position managers must have the same collateral and debt assets.
      (address _otherCollateral, address _otherDebt) =
        IPositionManager((guardKey == depositAsset.asset).ternary(targetAsset.asset, depositAsset.asset)).assets();
      _otherCollateral.checkAssetsMatch(_pmCollateral);
      _otherDebt.checkAssetsMatch(_pmDebt);
    }
  }
}
