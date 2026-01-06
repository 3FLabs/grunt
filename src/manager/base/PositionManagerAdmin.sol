// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManager, SupplyQueueEntry} from "../../interfaces/manager/IPositionManager.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/PositionManagerTypes.sol";
import {LibPositionManagerStorage} from "../../libs/manager/LibPositionManagerStorage.sol";
import {
  PM_ROLE_CURATOR,
  PM_MAX_MANAGEMENT_FEE,
  PM_MAX_PERFORMANCE_FEE
} from "../../libs/manager/LibPositionManagerConstants.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

/// @title PositionManagerAdmin
/// @notice Abstract contract handling administrative functions for PositionManager.
/// @dev Manages borrow modules, supply/withdrawal queues, LLTV, and max rebalance loss.
abstract contract PositionManagerAdmin is IPositionManager, OwnableRoles {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManager
  function addBorrowModule(address module) external override onlyOwner {
    LibPositionManagerStorage.load().borrowModules.add(module);
    emit IPositionManager.BorrowModuleAdded(module);
  }

  /// @inheritdoc IPositionManager
  function removeBorrowModule(address module) external override onlyOwner {
    LibPositionManagerStorage.load().borrowModules.remove(module);
    emit IPositionManager.BorrowModuleRemoved(module);
  }

  /// @inheritdoc IPositionManager
  function setSupplyQueue(SupplyQueueEntry[] calldata queue) external override onlyRoles(PM_ROLE_CURATOR) {
    PositionManagerStorageData storage ps = LibPositionManagerStorage.load();

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
  function setWithdrawalQueue(address[] calldata queue) external override onlyRoles(PM_ROLE_CURATOR) {
    PositionManagerStorageData storage ps = LibPositionManagerStorage.load();

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
    LibPositionManagerStorage.load().lltv = uint64(lltv_);
    emit IPositionManager.LLTVSet(lltv_);
  }

  /// @inheritdoc IPositionManager
  function setMaxRebalanceLoss(uint16 maxRebalanceLoss_) external override onlyOwner {
    LibPositionManagerStorage.load().maxRebalanceLoss = maxRebalanceLoss_;
    emit IPositionManager.MaxRebalanceLossSet(maxRebalanceLoss_);
  }

  /// @inheritdoc IPositionManager
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external override onlyOwner {
    if (managementFee > PM_MAX_MANAGEMENT_FEE || performanceFee > PM_MAX_PERFORMANCE_FEE) {
      revert IPositionManager.FeeExceedsMax();
    }

    // Accrue fees to current recipient first
    _accrueFeesBeforeFeeDataChange();

    FeeData memory fd;
    fd.feeRecipient = feeRecipient;
    fd.managementFee = managementFee;
    fd.performanceFee = performanceFee;
    LibPositionManagerStorage.load().feeData = fd;

    emit IPositionManager.FeeDataSet(feeRecipient, managementFee, performanceFee);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL HOOKS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Hook called before fee data change to accrue fees to current recipient.
  function _accrueFeesBeforeFeeDataChange() internal virtual;
}
