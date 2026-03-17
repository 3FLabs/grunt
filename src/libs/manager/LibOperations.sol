// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {SupplyQueueEntry} from "../../interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
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

  /// @dev Processes a deposit by iterating through the supply queue, supplying collateral and borrowing
  ///      debt from each position while respecting the position manager's target LTV.
  ///
  ///      For each position in the supply queue (until all debt is fulfilled):
  ///        1. Determine the maximum borrow: min(available liquidity, entry.maxBorrow, remainingDebt).
  ///        2. Ask the position how much additional collateral is needed to borrow that amount at the
  ///           target LTV, accounting for any existing collateral/debt in the position.
  ///        3. If the required collateral exceeds what's available, reduce the borrow amount to what
  ///           the remaining collateral can support at the target LTV.
  ///        4. Supply the collateral (if any) and execute the borrow.
  ///
  ///      After the loop, any leftover collateral (not needed for borrowing) is deposited into the
  ///      first supply queue position as idle collateral.
  ///
  ///      Reverts with {LibManagerErrors.InsufficientBorrowCapacity} if the requested debt cannot
  ///      be fully borrowed across all positions in the queue.
  /// @param _storage The position manager storage data.
  /// @param collateral The total amount of collateral to deposit.
  /// @param debt The total amount of debt to borrow.
  function processDeposit(PositionManagerStorageData storage _storage, uint256 collateral, uint256 debt) internal {
    unchecked {
      uint256 remainingCollateral = collateral;
      uint256 remainingDebt = debt;
      uint256 queueLength = _storage.supplyQueue.length;

      // Cache the target LTV set by the position manager owner
      uint256 ltv = _storage.ltv;

      for (uint256 i = 0; i < queueLength && remainingDebt > 0; i++) {
        SupplyQueueEntry memory entry = _storage.supplyQueue[i];
        address position = entry.position;

        // Cap the borrow at available liquidity, the per-entry max, and the remaining debt
        uint256 toBorrow =
          IBorrowPosition(position).availableLiquidity().min(uint256(entry.maxBorrow)).min(remainingDebt);

        if (toBorrow == 0) continue;

        // Determine how much collateral this position needs to borrow `toBorrow` at the target LTV.
        // Returns 0 if the position already has enough excess collateral from prior deposits.
        uint256 collateralNeeded = IBorrowPosition(position).collateralForBorrow(toBorrow, ltv);

        // If we don't have enough collateral, reduce the borrow to what our remaining collateral allows
        if (collateralNeeded > remainingCollateral) {
          toBorrow = IBorrowPosition(position).borrowForCollateral(remainingCollateral, ltv);
          if (toBorrow == 0) continue;
          collateralNeeded = remainingCollateral;
        }

        // Supply collateral to the position (via LibExecutor which handles approval)
        if (collateralNeeded > 0) {
          position.supply(_storage.metadata.collateralAsset, collateralNeeded);
          remainingCollateral -= collateralNeeded;
        }

        // Execute the borrow
        position.borrow(toBorrow);
        remainingDebt -= toBorrow;
      }

      // If we couldn't borrow all the requested debt, revert
      if (remainingDebt > 0) revert LibManagerErrors.InsufficientBorrowCapacity();

      // Deposit any leftover collateral (not needed for borrowing) into the first position.
      // This keeps all collateral productively deployed rather than idle in the PositionManager.
      if (remainingCollateral > 0) {
        _storage.supplyQueue[0].position.supply(_storage.metadata.collateralAsset, remainingCollateral);
      }
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
    WithdrawalStrategy strategy,
    bool checkLtv
  ) internal {
    if (strategy == WithdrawalStrategy.SEQUENTIAL) {
      _withdrawSequential(_storage, collateral, debt);
    } else {
      _withdrawProportional(_storage, collateral, debt, checkLtv);
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
    uint256 debtToRepay,
    bool checkLtv
  ) private {
    unchecked {
      address[] memory queue = _storage.withdrawalQueue;
      uint256 queueLength = queue.length;

      // Cache storage values to avoid stack-too-deep
      uint256 ltv = _storage.ltv;
      address debtAsset = _storage.metadata.debtAsset;

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
          if (toWithdraw > 0) {
            // When checkLtv is true (withdrawals), verify the position can release this collateral
            // while respecting the storage LTV. Burns skip this check since amounts are proportional.
            if (checkLtv && toWithdraw > IBorrowPosition(queue[i]).availableCollateral(ltv)) {
              revert LibManagerErrors.InsufficientAvailableCollateral();
            }
            queue[i].withdraw(toWithdraw);
          }
          prevWithdrawn = targetWithdrawn;
        }
      }
    }
  }
}
