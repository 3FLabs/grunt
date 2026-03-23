// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IPositionManagerAdmin, SupplyQueueEntry} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {PositionManagerBase} from "./PositionManagerBase.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibManagerErrors} from "../../libs/manager/LibManagerErrors.sol";
import {MAX_MANAGEMENT_FEE, MAX_PERFORMANCE_FEE} from "../../libs/manager/LibConstants.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";

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
  /// @dev Accrues fees before adding the module to checkpoint totalAssets.
  ///      Updates lastTotalAssets after adding so the new module's assets are reflected.
  ///      Validates that the module's collateral and debt assets match the position manager's,
  ///      the module's owner is this contract, and the module's safe LTV is >= the PM LTV.
  function addBorrowModule(address module) external override onlyOwner {
    _accrueFees();
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    if (IBorrowPosition(module).collateralAsset() != _storage.metadata.collateralAsset) {
      revert LibManagerErrors.CollateralAssetMismatch();
    }
    if (IBorrowPosition(module).borrowAsset() != _storage.metadata.debtAsset) {
      revert LibManagerErrors.DebtAssetMismatch();
    }
    if (Ownable(module).owner() != address(this)) {
      revert LibManagerErrors.InvalidModuleOwner();
    }
    if (IBorrowPosition(module).safeLtv() < _storage.ltv) {
      revert LibManagerErrors.ModuleSafeLtvTooLow();
    }

    if (!_storage.borrowModules.add(module)) {
      revert LibManagerErrors.ModuleAlreadyAdded();
    }
    _storage.updateSnapshot();
    emit IPositionManagerAdmin.BorrowModuleAdded(module);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Accrues fees before removing the module to checkpoint totalAssets.
  ///      Updates lastTotalAssets after removing so the module's assets are no longer counted.
  ///      Reverts with {LibManagerErrors.ModuleStillInQueue} if the module is still in supply or withdrawal queue.
  function removeBorrowModule(address module) external override onlyOwner {
    _accrueFees();
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Check module is not in supply queue
    uint256 supplyQueueLength = _storage.supplyQueue.length;
    for (uint256 i = 0; i < supplyQueueLength; ++i) {
      if (_storage.supplyQueue[i].position == module) revert LibManagerErrors.ModuleStillInQueue();
    }

    // Check module is not in withdrawal queue
    uint256 withdrawalQueueLength = _storage.withdrawalQueue.length;
    for (uint256 i = 0; i < withdrawalQueueLength; ++i) {
      if (_storage.withdrawalQueue[i] == module) revert LibManagerErrors.ModuleStillInQueue();
    }

    if (!_storage.borrowModules.remove(module)) {
      revert LibManagerErrors.ModuleNotFound();
    }
    _storage.updateSnapshot();
    Ownable(module).transferOwnership(msg.sender);
    emit IPositionManagerAdmin.BorrowModuleRemoved(module);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibManagerErrors.UnauthorizedPosition} if any position in the queue is not whitelisted.
  ///      Reverts with {LibManagerErrors.DuplicateQueueEntry} if any position appears more than once.
  function setSupplyQueue(SupplyQueueEntry[] calldata queue) external override onlyRoles(CURATOR_ROLE) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    delete _storage.supplyQueue;
    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength; ++i) {
      if (!_storage.borrowModules.contains(queue[i].position)) revert LibManagerErrors.UnauthorizedPosition();
      for (uint256 j = 0; j < i; ++j) {
        if (queue[j].position == queue[i].position) revert LibManagerErrors.DuplicateQueueEntry();
      }
      _storage.supplyQueue.push(queue[i]);
    }
    emit IPositionManagerAdmin.SupplyQueueSet(queue);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibManagerErrors.UnauthorizedPosition} if any position in the queue is not whitelisted.
  ///      Reverts with {LibManagerErrors.DuplicateQueueEntry} if any position appears more than once.
  function setWithdrawalQueue(address[] calldata queue) external override onlyRoles(CURATOR_ROLE) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength; ++i) {
      if (!_storage.borrowModules.contains(queue[i])) revert LibManagerErrors.UnauthorizedPosition();
      for (uint256 j = 0; j < i; ++j) {
        if (queue[j] == queue[i]) revert LibManagerErrors.DuplicateQueueEntry();
      }
    }
    _storage.withdrawalQueue = queue;
    emit IPositionManagerAdmin.WithdrawalQueueSet(queue);
  }

  /// @inheritdoc IPositionManagerAdmin
  /// @dev Reverts with {LibManagerErrors.ModuleSafeLtvTooLow} if any whitelisted borrow module
  ///      has a safe LTV lower than the new PM LTV.
  ///      Reverts with {LibCommonErrors.InvalidLtv} (via setLtv) if ltv is zero or greater than WAD.
  function setLtv(uint256 ltv_) external override onlyOwner {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Check all whitelisted borrow modules have safeLtv >= new PM LTV
    uint256 len = _storage.borrowModules.length();
    for (uint256 i; i < len; ++i) {
      if (IBorrowPosition(_storage.borrowModules.at(i)).safeLtv() < ltv_) {
        revert LibManagerErrors.ModuleSafeLtvTooLow();
      }
    }

    _storage.setLtv(ltv_);
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
