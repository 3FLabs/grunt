// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {SupplyQueueEntry} from "../../interfaces/manager/IPositionManager.sol";
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
          position.supply(_storage.collateralAsset, collateralToSupply);
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

  /// @dev Processes withdrawal through the withdrawal queue.
  ///      Reverts with {LibManagerErrors.ExcessDebtRepay} if the requested debt cannot be fully repaid.
  ///      Reverts with {LibManagerErrors.InsufficientAvailableCollateral} if the requested collateral cannot be withdrawn.
  /// @param _storage The position manager storage data
  /// @param collateral The amount of collateral to withdraw
  /// @param debt The amount of debt to repay
  function processWithdrawal(PositionManagerStorageData storage _storage, uint256 collateral, uint256 debt) internal {
    unchecked {
      uint256 remainingDebt = debt;
      uint256 remainingCollateral = collateral;
      uint256 queueLength = _storage.withdrawalQueue.length;

      address debtAsset = _storage.debtAsset;

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
          uint256 toWithdraw = IBorrowPosition(position).availableCollateral(_storage.lltv).min(remainingCollateral);
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

  /// @dev Processes burn by repaying debt and withdrawing collateral proportionally from each position.
  ///      This maintains the average LTV across all positions.
  /// @param _storage The position manager storage data
  /// @param collateralToWithdraw Total collateral to withdraw
  /// @param debtToRepay Total debt to repay
  /// @param totalCollateral Total collateral across all positions
  /// @param totalDebt Total debt across all positions
  function processBurn(
    PositionManagerStorageData storage _storage,
    uint256 collateralToWithdraw,
    uint256 debtToRepay,
    uint256 totalCollateral,
    uint256 totalDebt
  ) internal {
    unchecked {
      uint256 remainingCollateral = collateralToWithdraw;
      uint256 remainingDebt = debtToRepay;
      uint256 queueLength = _storage.withdrawalQueue.length;

      for (uint256 i = 0; i < queueLength; i++) {
        address position = _storage.withdrawalQueue[i];
        uint256 positionDebt = IBorrowPosition(position).totalBorrowed();
        uint256 positionCollateral = IBorrowPosition(position).totalCollateral();

        // Repay proportionally
        if (remainingDebt > 0 && positionDebt > 0 && totalDebt > 0) {
          uint256 toRepay = debtToRepay.mulDiv(positionDebt, totalDebt);
          if (toRepay > 0) {
            position.repay(_storage.debtAsset, toRepay);
            remainingDebt -= toRepay;
          }
        }

        // Withdraw proportionally
        if (remainingCollateral > 0 && positionCollateral > 0 && totalCollateral > 0) {
          uint256 toWithdraw = collateralToWithdraw.mulDiv(positionCollateral, totalCollateral);
          if (toWithdraw > 0) {
            position.withdraw(toWithdraw);
            remainingCollateral -= toWithdraw;
          }
        }
      }
    }
  }
}
