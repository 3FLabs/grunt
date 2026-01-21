// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
  IPositionManager,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "../../interfaces/manager/IPositionManager.sol";
import {ITransferGuard} from "../../interfaces/guard/ITransferGuard.sol";
import {PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibErrors} from "../../libs/manager/LibErrors.sol";
import {LibErrors as CommonErrors} from "../../libs/common/LibErrors.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {BPS} from "../../libs/manager/LibConstants.sol";
import {LibExecutor} from "../../libs/manager/LibExecutor.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title PositionManagerRebalancing
/// @author 3F Protocol
/// @notice Abstract contract handling rebalancing operations for PositionManager.
/// @dev Allows redistribution of collateral and debt across borrow positions.
abstract contract PositionManagerRebalancing is IPositionManager, OwnableRoles {
  using SafeTransferLib for address;
  using LibExecutor for address;
  using LibView for PositionManagerStorageData;
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Role for executing rebalancing operations.
  uint256 internal constant REBALANCER_ROLE = _ROLE_2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       REBALANCING                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManager
  /// @dev Reverts with {LibErrors.Paused} if the contract is paused.
  ///      Reverts with {LibErrors.RebalanceLossExceedsMax} if total assets decrease exceeds maxRebalanceLoss.
  function rebalance(RebalancingData calldata data, address receiver)
    public
    virtual
    override
    onlyRoles(REBALANCER_ROLE)
    returns (uint256 collateralExcess, uint256 debtExcess)
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Check if paused via transfer guard
    address guard = _storage.transferGuard;
    if (guard != address(0) && ITransferGuard(guard).paused(address(this))) {
      revert CommonErrors.Paused();
    }

    // Accrue fees based on pre-rebalance state and capture totalAssets before operations
    uint256 totalAssetsBefore = _accrueFeesForRebalance();

    address _collateralAsset = _storage.collateralAsset;
    address _debtAsset = _storage.debtAsset;

    if (data.collateral > 0) {
      _collateralAsset.safeTransferFrom(msg.sender, address(this), data.collateral);
    }
    if (data.debt > 0) {
      _debtAsset.safeTransferFrom(msg.sender, address(this), data.debt);
    }

    uint256 opsLength = data.operations.length;
    for (uint256 i = 0; i < opsLength;) {
      _dispatchRebalancingOperation(data.operations[i], _collateralAsset, _debtAsset);
      unchecked {
        ++i;
      }
    }

    collateralExcess = _collateralAsset.safeTransferAll(receiver);
    debtExcess = _debtAsset.safeTransferAll(receiver);

    // Update snapshot to post-rebalance state
    uint256 totalAssetsAfter = _storage.totalAssets();
    _storage.lastTotalAssets = totalAssetsAfter;

    // Check that totalAssets didn't decrease by more than maxRebalanceLoss
    if (totalAssetsAfter < totalAssetsBefore) {
      uint256 loss = totalAssetsBefore - totalAssetsAfter;
      // loss * BPS / totalAssetsBefore > maxRebalanceLoss
      // Rearranged to avoid division: loss * BPS > maxRebalanceLoss * totalAssetsBefore
      if (loss * BPS > uint256(_storage.maxRebalanceLoss) * totalAssetsBefore) {
        revert LibErrors.RebalanceLossExceedsMax();
      }
    }
  }

  /// @dev Dispatches a single rebalancing operation to the appropriate helper.
  ///      Reverts with {LibErrors.UnauthorizedPosition} if the position is not a registered borrow module.
  /// @param operation The rebalancing operation to execute
  /// @param _collateralAsset The collateral asset address
  /// @param _debtAsset The debt asset address
  function _dispatchRebalancingOperation(
    RebalancingOperation calldata operation,
    address _collateralAsset,
    address _debtAsset
  ) internal {
    address position = operation.position;
    uint256 amount = operation.amount;
    RebalancingOperationType operationType = operation.operationType;

    // Validate that the position is a registered borrow module
    if (!LibStorage.positionManagerStorage().borrowModules.contains(position)) {
      revert LibErrors.UnauthorizedPosition();
    }

    if (operationType == RebalancingOperationType.REPAY) {
      position.repay(_debtAsset, amount);
    } else if (operationType == RebalancingOperationType.WITHDRAW) {
      position.withdraw(amount);
    } else if (operationType == RebalancingOperationType.BORROW) {
      position.borrow(amount);
    } else if (operationType == RebalancingOperationType.SUPPLY) {
      position.supply(_collateralAsset, amount);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL HOOKS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Hook called to accrue fees before rebalancing.
  /// @return totalAssetsBefore The total assets before rebalancing
  function _accrueFeesForRebalance() internal virtual returns (uint256 totalAssetsBefore);
}
