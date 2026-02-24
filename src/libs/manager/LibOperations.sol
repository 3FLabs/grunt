// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {SupplyQueueEntry, WithdrawalStrategy} from "../../interfaces/manager/IPositionManager.sol";
import {PositionManagerStorageData} from "./LibStorage.sol";
import {LibExecutor} from "./LibExecutor.sol";
import {LibManagerErrors} from "./LibManagerErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibOperations
/// @author 3F Protocol
/// @notice Library handling deposit, withdrawal, and burn queue processing for PositionManager.
/// @dev Used with `using LibOperations for PositionManagerStorageData`.
library LibOperations {
  using FixedPointMathLib for uint256;
  using LibExecutor for address;

  /// @dev Processes deposit through the supply queue.
  ///      Reverts with {LibManagerErrors.InsufficientBorrowCapacity} if the requested debt cannot be borrowed.
  /// @param _storage The position manager storage data
  /// @param collateral The amount of collateral to deposit
  /// @param debt The amount of debt to borrow
  function processDeposit(PositionManagerStorageData storage _storage, uint256 collateral, uint256 debt) internal {
    unchecked {

      uint256 remainingCollateral = collateral;
      uint256 remainingDebt = debt;
      uint256 queueLength = _storage.supplyQueue.length;

      for (uint256 i = 0; i < queueLength && remainingDebt > 0; i++) {
        SupplyQueueEntry memory entry = _storage.supplyQueue[i];
        address position = entry.position;

        // Calculate how much we can borrow from this position
        uint256 availableLiquidity = IBorrowPosition(position).availableLiquidity();
        uint256 toBorrow = availableLiquidity.min(uint256(entry.maxBorrow)).min(remainingDebt);

        if (toBorrow == 0) {
          continue;
        }

        // Calculate proportional collateral
        // If we're borrowing X% of remaining debt, we supply X% of remaining collateral
        uint256 collateralToSupply = remainingCollateral.mulDiv(toBorrow, remainingDebt);

        // Supply collateral first (if any)
        if (collateralToSupply > 0) {
          position.supply(_storage.metadata.collateralAsset, collateralToSupply);
          remainingCollateral -= collateralToSupply;
        }

        // Then borrow
        position.borrow(toBorrow);
        remainingDebt -= toBorrow;
      }

      // If we couldn't borrow all the requested debt, revert
      if (remainingDebt > 0) revert LibManagerErrors.InsufficientBorrowCapacity();

      // Note: remainingCollateral is guaranteed to be 0 here due to proportional math.
      // When toBorrow == remainingDebt (final iteration), collateralToSupply = remainingCollateral.
    }
  }

  /// @dev Processes withdrawal through the withdrawal queue using the specified strategy.
  /// @param _storage The position manager storage data
  /// @param collateral The amount of collateral to withdraw
  /// @param debt The amount of debt to repay
  /// @param strategy The withdrawal strategy (SEQUENTIAL or PROPORTIONAL)
  function processWithdrawal(
    PositionManagerStorageData storage _storage,
    uint256 collateral,
    uint256 debt,
    WithdrawalStrategy strategy
  ) internal {
    if (strategy == WithdrawalStrategy.SEQUENTIAL) {
      _withdrawSequential(_storage, collateral, debt);
    } else {
      _withdrawProportional(_storage, collateral, debt);
    }
  }

  /// @dev Withdraws sequentially through the withdrawal queue, draining positions one-by-one.
  ///      For each position: repays as much debt as possible, then withdraws available collateral.
  ///      Reverts with {LibManagerErrors.ExcessDebtRepay} if the requested debt cannot be fully repaid.
  ///      Reverts with {LibManagerErrors.InsufficientAvailableCollateral} if the requested collateral cannot be withdrawn.
  /// @param _storage The position manager storage data
  /// @param collateral The amount of collateral to withdraw
  /// @param debt The amount of debt to repay
  function _withdrawSequential(PositionManagerStorageData storage _storage, uint256 collateral, uint256 debt) private {
    unchecked {
      uint256 remainingDebt = debt;
      uint256 remainingCollateral = collateral;
      uint256 queueLength = _storage.withdrawalQueue.length;

      address debtAsset = _storage.metadata.debtAsset;

      for (uint256 i = 0; i < queueLength && (remainingDebt > 0 || remainingCollateral > 0); i++) {
        address position = _storage.withdrawalQueue[i];

        // Repay debt first (increases available collateral for withdrawal)
        if (remainingDebt > 0) {
          uint256 positionDebt = IBorrowPosition(position).totalBorrowed();
          if (positionDebt > 0) {
            uint256 toRepay = positionDebt.min(remainingDebt);
            position.repay(debtAsset, toRepay);
            remainingDebt -= toRepay;
          }
        }

        // Then withdraw collateral
        if (remainingCollateral > 0) {
          uint256 toWithdraw = IBorrowPosition(position).availableCollateral(_storage.ltv).min(remainingCollateral);
          if (toWithdraw > 0) {
            position.withdraw(toWithdraw);
            remainingCollateral -= toWithdraw;
          }
        }
      }

      // If we couldn't repay all debt, revert (would leave tokens stuck in contract)
      if (remainingDebt > 0) revert LibManagerErrors.ExcessDebtRepay();

      // If we couldn't withdraw all requested collateral, revert
      if (remainingCollateral > 0) revert LibManagerErrors.InsufficientAvailableCollateral();
    }
  }

  /// @dev Withdraws proportionally across all positions in the withdrawal queue.
  ///      Uses a two-pass approach: first builds cumulative debt/collateral arrays,
  ///      then distributes repayment and withdrawal using a running cumulative algorithm
  ///      (similar to Bresenham's line algorithm) that guarantees no position is over-repaid and zero dust.
  ///      Because debtToRepay <= queueTotalDebt, each step's allocation is mathematically bounded by debts[i].
  /// @param _storage The position manager storage data
  /// @param collateralToWithdraw Total collateral to withdraw
  /// @param debtToRepay Total debt to repay
  function _withdrawProportional(
    PositionManagerStorageData storage _storage,
    uint256 collateralToWithdraw,
    uint256 debtToRepay
  ) private {
    unchecked {
      address[] memory queue = _storage.withdrawalQueue;
      uint256 queueLength = queue.length;

      // Pass 1: build cumulative debt and collateral arrays
      uint256[] memory cumDebts = new uint256[](queueLength);
      uint256[] memory cumCollaterals = new uint256[](queueLength);

      for (uint256 i = 0; i < queueLength; i++) {
        cumDebts[i] = (i > 0 ? cumDebts[i - 1] : 0) + IBorrowPosition(queue[i]).totalBorrowed();
        cumCollaterals[i] = (i > 0 ? cumCollaterals[i - 1] : 0) + IBorrowPosition(queue[i]).totalCollateral();
      }

      // Queue totals are the last cumulative values
      uint256 lastIdx = queueLength - 1;
      if (debtToRepay > cumDebts[lastIdx]) revert LibManagerErrors.ExcessDebtRepay();
      if (collateralToWithdraw > cumCollaterals[lastIdx]) revert LibManagerErrors.InsufficientAvailableCollateral();

      // Pass 2: cumulative proportional distribution
      // Each position's allocation = target_cumulative(i) - target_cumulative(i-1), which is
      // guaranteed to never exceed the position's actual debt/collateral.
      address debtAsset = _storage.metadata.debtAsset;
      uint256 prevRepaid;
      uint256 prevWithdrawn;

      for (uint256 i = 0; i < queueLength; i++) {
        if (debtToRepay > 0) {
          uint256 targetRepaid = cumDebts[i].mulDiv(debtToRepay, cumDebts[lastIdx]);
          uint256 toRepay = targetRepaid - prevRepaid;
          if (toRepay > 0) queue[i].repay(debtAsset, toRepay);
          prevRepaid = targetRepaid;
        }

        if (collateralToWithdraw > 0) {
          uint256 targetWithdrawn = cumCollaterals[i].mulDiv(collateralToWithdraw, cumCollaterals[lastIdx]);
          uint256 toWithdraw = targetWithdrawn - prevWithdrawn;
          if (toWithdraw > 0) queue[i].withdraw(toWithdraw);
          prevWithdrawn = targetWithdrawn;
        }
      }
    }
  }
}
