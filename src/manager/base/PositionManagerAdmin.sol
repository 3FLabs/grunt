// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManager, SupplyQueueEntry} from "../../interfaces/manager/IPositionManager.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {MAX_MANAGEMENT_FEE, MAX_PERFORMANCE_FEE} from "../../libs/manager/LibConstants.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

/// @title PositionManagerAdmin
/// @notice Abstract contract handling administrative functions for PositionManager.
/// @dev Manages borrow modules, supply/withdrawal queues, LLTV, and max rebalance loss.
abstract contract PositionManagerAdmin is IPositionManager, OwnableRoles {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Role for setting supply/withdrawal queues.
  uint256 internal constant CURATOR_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManager
  function addBorrowModule(address module) external override onlyOwner {
    LibStorage.positionManagerStorage().borrowModules.add(module);
    emit IPositionManager.BorrowModuleAdded(module);
  }

  /// @inheritdoc IPositionManager
  function removeBorrowModule(address module) external override onlyOwner {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();

    // Check module is not in supply queue
    uint256 supplyQueueLength = ps.supplyQueue.length;
    for (uint256 i = 0; i < supplyQueueLength;) {
      if (ps.supplyQueue[i].position == module) revert IPositionManager.ModuleStillInQueue();
      unchecked {
        ++i;
      }
    }

    // Check module is not in withdrawal queue
    uint256 withdrawalQueueLength = ps.withdrawalQueue.length;
    for (uint256 i = 0; i < withdrawalQueueLength;) {
      if (ps.withdrawalQueue[i] == module) revert IPositionManager.ModuleStillInQueue();
      unchecked {
        ++i;
      }
    }

    ps.borrowModules.remove(module);
    emit IPositionManager.BorrowModuleRemoved(module);
  }

  /// @inheritdoc IPositionManager
  function setSupplyQueue(SupplyQueueEntry[] calldata queue) external override onlyRoles(CURATOR_ROLE) {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();

    delete ps.supplyQueue;
    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      if (!ps.borrowModules.contains(queue[i].position)) revert IPositionManager.UnauthorizedPosition();
      ps.supplyQueue.push(queue[i]);
      unchecked {
        ++i;
      }
    }
    emit IPositionManager.SupplyQueueSet(queue);
  }

  /// @inheritdoc IPositionManager
  function setWithdrawalQueue(address[] calldata queue) external override onlyRoles(CURATOR_ROLE) {
    PositionManagerStorageData storage ps = LibStorage.positionManagerStorage();

    uint256 queueLength = queue.length;
    for (uint256 i = 0; i < queueLength;) {
      if (!ps.borrowModules.contains(queue[i])) revert IPositionManager.UnauthorizedPosition();
      unchecked {
        ++i;
      }
    }
    ps.withdrawalQueue = queue;
    emit IPositionManager.WithdrawalQueueSet(queue);
  }

  /// @inheritdoc IPositionManager
  function setLltv(uint256 lltv_) external override onlyOwner {
    // Safe: lltv_ is WAD precision (1e18 max), which fits in uint64 (max ~1.8e19)
    // forge-lint: disable-next-line(unsafe-typecast)
    LibStorage.positionManagerStorage().lltv = uint64(lltv_);
    emit IPositionManager.LLTVSet(lltv_);
  }

  /// @inheritdoc IPositionManager
  function setMaxRebalanceLoss(uint16 maxRebalanceLoss_) external override onlyOwner {
    LibStorage.positionManagerStorage().maxRebalanceLoss = maxRebalanceLoss_;
    emit IPositionManager.MaxRebalanceLossSet(maxRebalanceLoss_);
  }

  /// @inheritdoc IPositionManager
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external override onlyOwner {
    if (managementFee > MAX_MANAGEMENT_FEE || performanceFee > MAX_PERFORMANCE_FEE) {
      revert IPositionManager.FeeExceedsMax();
    }

    // Accrue fees to current recipient first
    _accrueFeesBeforeFeeDataChange();

    FeeData memory fd;
    fd.feeRecipient = feeRecipient;
    fd.managementFee = managementFee;
    fd.performanceFee = performanceFee;
    LibStorage.positionManagerStorage().feeData = fd;

    emit IPositionManager.FeeDataSet(feeRecipient, managementFee, performanceFee);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL HOOKS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Hook called before fee data change to accrue fees to current recipient.
  function _accrueFeesBeforeFeeDataChange() internal virtual;
}
