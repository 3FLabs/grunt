// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManagerAdmin, SupplyQueueEntry} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {PositionManagerBase} from "./PositionManagerBase.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibManagerErrors} from "../../libs/manager/LibManagerErrors.sol";
import {MAX_MANAGEMENT_FEE, MAX_PERFORMANCE_FEE} from "../../libs/manager/LibConstants.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

/// @title PositionManagerAdmin
/// @author 3F Protocol
/// @notice Abstract contract handling administrative functions for PositionManager.
/// @dev Manages borrow modules, supply/withdrawal queues, LTV, and max rebalance loss.
abstract contract PositionManagerAdmin is IPositionManagerAdmin, PositionManagerBase {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using LibStorage for PositionManagerStorageData;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManagerAdmin
  function addBorrowModule(address module) external override onlyOwner {
    LibStorage.positionManagerStorage().borrowModules.add(module);
    emit IPositionManagerAdmin.BorrowModuleAdded(module);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibManagerErrors.ModuleStillInQueue} if the module is still in supply or withdrawal queue.
  function removeBorrowModule(address module) external override onlyOwner {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Check module is not in supply queue
    uint256 supplyQueueLength = _storage.supplyQueue.length;
    for (uint256 i = 0; i < supplyQueueLength;) {
      if (_storage.supplyQueue[i].position == module) revert LibManagerErrors.ModuleStillInQueue();
      unchecked {
        ++i;
      }
    }

    // Check module is not in withdrawal queue
    uint256 withdrawalQueueLength = _storage.withdrawalQueue.length;
    for (uint256 i = 0; i < withdrawalQueueLength;) {
      if (_storage.withdrawalQueue[i] == module) revert LibManagerErrors.ModuleStillInQueue();
      unchecked {
        ++i;
      }
    }

    _storage.borrowModules.remove(module);
    emit IPositionManagerAdmin.BorrowModuleRemoved(module);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibManagerErrors.UnauthorizedPosition} if any position in the queue is not whitelisted.
  function setSupplyQueue(SupplyQueueEntry[] calldata queue) external override onlyRoles(CURATOR_ROLE) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    delete _storage.supplyQueue;
    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      if (!_storage.borrowModules.contains(queue[i].position)) revert LibManagerErrors.UnauthorizedPosition();
      _storage.supplyQueue.push(queue[i]);
      unchecked {
        ++i;
      }
    }
    emit IPositionManagerAdmin.SupplyQueueSet(queue);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibManagerErrors.UnauthorizedPosition} if any position in the queue is not whitelisted.
  function setWithdrawalQueue(address[] calldata queue) external override onlyRoles(CURATOR_ROLE) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      if (!_storage.borrowModules.contains(queue[i])) revert LibManagerErrors.UnauthorizedPosition();
      unchecked {
        ++i;
      }
    }
    _storage.withdrawalQueue = queue;
    emit IPositionManagerAdmin.WithdrawalQueueSet(queue);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibCommonErrors.InvalidLtv} if ltv is zero or greater than WAD.
  function setLtv(uint256 ltv_) external override onlyOwner {
    LibStorage.positionManagerStorage().setLtv(ltv_);
  }

  /// @inheritdoc IPositionManagerAdmin
  function setRebalanceConfig(uint16 maxRebalanceLoss_, uint40 rebalanceCooldown_) external override onlyOwner {
    LibStorage.positionManagerStorage().setRebalanceConfig(maxRebalanceLoss_, rebalanceCooldown_);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Setting transferGuard_ to address(0) disables transfer restrictions,
  ///      allowing all transfers without validation. This is intentional behavior.
  function setTransferGuard(address transferGuard_) external override onlyOwner {
    LibStorage.positionManagerStorage().transferGuard = transferGuard_;
    emit IPositionManagerAdmin.TransferGuardSet(transferGuard_);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibManagerErrors.FeeExceedsMax} if management or performance fee exceeds the maximum.
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external override onlyOwner {
    if (managementFee > MAX_MANAGEMENT_FEE || performanceFee > MAX_PERFORMANCE_FEE) {
      revert LibManagerErrors.FeeExceedsMax();
    }

    // Accrue fees to current recipient first
    _accrueFees();

    FeeData memory fd;
    fd.feeRecipient = feeRecipient;
    fd.managementFee = managementFee;
    fd.performanceFee = performanceFee;
    LibStorage.positionManagerStorage().feeData = fd;

    emit IPositionManagerAdmin.FeeDataSet(feeRecipient, managementFee, performanceFee);
  }
}
