// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {
  IPositionManagerRebalancing,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "../../interfaces/manager/base/IPositionManagerRebalancing.sol";
import {ITransferGuard} from "../../interfaces/guard/ITransferGuard.sol";
import {PositionManagerBase} from "./PositionManagerBase.sol";
import {PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibManagerErrors} from "../../libs/manager/LibManagerErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../libs/common/LibCommonErrors.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {BPS} from "../../libs/Constants.sol";
import {LibExecutor} from "../../libs/manager/LibExecutor.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title PositionManagerRebalancing
/// @author 3F Protocol
/// @notice Abstract contract handling rebalancing operations for PositionManager.
/// @dev Allows redistribution of collateral and debt across borrow positions.
abstract contract PositionManagerRebalancing is IPositionManagerRebalancing, PositionManagerBase {
  using SafeTransferLib for address;
  using LibExecutor for address;
  using LibView for PositionManagerStorageData;
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       REBALANCING                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IPositionManagerRebalancing
  /// @dev Reverts with {LibCommonErrors.Paused} if the contract is paused.
  ///      Reverts with {LibManagerErrors.RebalanceLossExceedsMax} if total assets decrease exceeds maxRebalanceLoss.
  ///      Protected by nonReentrant to prevent malicious modules from manipulating
  ///      guard state (pause/unpause) mid-transaction via callbacks.
  ///
  ///      Operator note: Morpho rounds repay shares down (toSharesDown) and borrow shares up
  ///      (toSharesUp), which can produce a 1-2 wei "phantom" NAV decrease across a single
  ///      rebalance even when no real economic loss occurs. With `maxRebalanceLoss == 0` the
  ///      check below would revert on this dust. Production deployments must therefore configure
  ///      `maxRebalanceLoss > 0` (a single basis point is enough); `maxRebalanceLoss == 0` will
  ///      revert otherwise-valid rebalances and must not be used.
  function rebalance(RebalancingData calldata data, address receiver)
    public
    virtual
    override
    onlyRoles(REBALANCER_ROLE)
    nonReentrant
    returns (uint256 collateralExcess, uint256 debtExcess)
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Enforce cooldown between consecutive rebalance calls
    uint40 cooldown = _storage.rebalanceConfig.rebalanceCooldown;
    uint40 lastRebalance = _storage.rebalanceConfig.lastRebalanceTimestamp;
    if (cooldown > 0 && lastRebalance > 0) {
      // Safe: block.timestamp fits in uint40 for ~35,000 years
      // Subtraction is safe because block.timestamp >= lastRebalance (time is monotonic).
      // Using `elapsed < cooldown` instead of `timestamp < lastRebalance + cooldown`
      // to avoid uint40 overflow when cooldown is large.
      // forge-lint: disable-next-line(unsafe-typecast)
      if (uint40(block.timestamp) - lastRebalance < cooldown) {
        revert LibManagerErrors.RebalanceCooldownNotElapsed();
      }
    }

    // Check if paused via transfer guard
    address guard = _storage.transferGuard;
    if (guard != address(0) && ITransferGuard(guard).paused(address(this))) {
      revert CommonErrors.Paused();
    }

    // Accrue fees based on pre-rebalance state and capture totalAssets before operations
    uint256 totalAssetsBefore = _accrueFees();

    address _collateralAsset = _storage.metadata.collateralAsset;
    address _debtAsset = _storage.metadata.debtAsset;

    if (data.collateral > 0) {
      _collateralAsset.safeTransferFrom(msg.sender, address(this), data.collateral);
    }
    if (data.debt > 0) {
      _debtAsset.safeTransferFrom(msg.sender, address(this), data.debt);
    }

    uint256 opsLength = data.operations.length;
    for (uint256 i = 0; i < opsLength; ++i) {
      _dispatchRebalancingOperation(data.operations[i], _collateralAsset, _debtAsset);
    }

    collateralExcess = _collateralAsset.safeTransferAll(receiver);
    debtExcess = _debtAsset.safeTransferAll(receiver);

    // Record rebalance timestamp for cooldown enforcement
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.rebalanceConfig.lastRebalanceTimestamp = uint40(block.timestamp);

    emit Rebalanced(receiver, data.collateral, data.debt, collateralExcess, debtExcess);

    // Update snapshot to post-rebalance state. Goes through updateSnapshot so lastDebt is kept
    // in sync with lastTotalAssets in a single iteration over the borrow modules.
    LibStorage.updateSnapshot(_storage);
    uint256 totalAssetsAfter = _storage.lastTotalAssets;

    // Check that totalAssets didn't decrease by more than maxRebalanceLoss
    if (totalAssetsAfter < totalAssetsBefore) {
      uint256 loss = totalAssetsBefore - totalAssetsAfter;
      // loss * BPS / totalAssetsBefore > maxRebalanceLoss
      // Rearranged to avoid division: loss * BPS > maxRebalanceLoss * totalAssetsBefore
      if (loss * BPS > uint256(_storage.rebalanceConfig.maxRebalanceLoss) * totalAssetsBefore) {
        revert LibManagerErrors.RebalanceLossExceedsMax();
      }
    }
  }

  /// @dev Dispatches a single rebalancing operation to the appropriate helper.
  ///      Reverts with {LibManagerErrors.UnauthorizedPosition} if the position is not a registered borrow module.
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
      revert LibManagerErrors.UnauthorizedPosition();
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
}
