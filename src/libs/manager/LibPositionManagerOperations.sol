// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {IPositionManager, SupplyQueueEntry} from "../../interfaces/manager/IPositionManager.sol";
import {PositionManagerStorageData} from "./PositionManagerTypes.sol";
import {LibPositionExecutor} from "./LibPositionExecutor.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibPositionManagerOperations
/// @notice Library handling deposit, withdrawal, and burn queue processing for PositionManager.
/// @dev Used with `using LibPositionManagerOperations for PositionManagerStorageData`.
library LibPositionManagerOperations {
  using FixedPointMathLib for uint256;
  using LibPositionExecutor for address;

  /// @dev Processes deposit through the supply queue.
  /// @param ps The position manager storage data
  /// @param collateral The amount of collateral to deposit
  /// @param debt The amount of debt to borrow
  function processDeposit(PositionManagerStorageData storage ps, uint256 collateral, uint256 debt) internal {
    unchecked {

      uint256 remainingCollateral = collateral;
      uint256 remainingDebt = debt;
      uint256 queueLength = ps.supplyQueue.length;

      for (uint256 i = 0; i < queueLength && remainingDebt > 0; i++) {
        SupplyQueueEntry memory entry = ps.supplyQueue[i];
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
          position.supply(ps.collateralAsset, collateralToSupply);
          remainingCollateral -= collateralToSupply;
        }

        // Then borrow
        position.borrow(toBorrow);
        remainingDebt -= toBorrow;
      }

      // If we couldn't borrow all the requested debt, revert
      if (remainingDebt > 0) revert IPositionManager.InsufficientBorrowCapacity();

      // Note: remainingCollateral is guaranteed to be 0 here due to proportional math.
      // When toBorrow == remainingDebt (final iteration), collateralToSupply = remainingCollateral.
    }
  }

  /// @dev Processes withdrawal through the withdrawal queue.
  /// @param ps The position manager storage data
  /// @param collateral The amount of collateral to withdraw
  /// @param debt The amount of debt to repay
  function processWithdrawal(PositionManagerStorageData storage ps, uint256 collateral, uint256 debt) internal {
    unchecked {
      uint256 remainingDebt = debt;
      uint256 remainingCollateral = collateral;
      uint256 queueLength = ps.withdrawalQueue.length;

      address debtAsset = ps.debtAsset;

      for (uint256 i = 0; i < queueLength && (remainingDebt > 0 || remainingCollateral > 0); i++) {
        address position = ps.withdrawalQueue[i];

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
          uint256 toWithdraw = IBorrowPosition(position).availableCollateral(ps.lltv).min(remainingCollateral);
          if (toWithdraw > 0) {
            position.withdraw(toWithdraw);
            remainingCollateral -= toWithdraw;
          }
        }
      }

      // If we couldn't repay all debt, revert (would leave tokens stuck in contract)
      if (remainingDebt > 0) revert IPositionManager.ExcessDebtRepay();

      // If we couldn't withdraw all requested collateral, revert
      if (remainingCollateral > 0) revert IPositionManager.InsufficientAvailableCollateral();
    }
  }

  /// @dev Processes burn by repaying debt and withdrawing collateral proportionally from each position.
  ///      This maintains the average LTV across all positions.
  /// @param ps The position manager storage data
  /// @param collateralToWithdraw Total collateral to withdraw
  /// @param debtToRepay Total debt to repay
  /// @param totalCollateral Total collateral across all positions
  /// @param totalDebt Total debt across all positions
  function processBurn(
    PositionManagerStorageData storage ps,
    uint256 collateralToWithdraw,
    uint256 debtToRepay,
    uint256 totalCollateral,
    uint256 totalDebt
  ) internal {
    unchecked {
      uint256 remainingCollateral = collateralToWithdraw;
      uint256 remainingDebt = debtToRepay;
      uint256 queueLength = ps.withdrawalQueue.length;

      for (uint256 i = 0; i < queueLength; i++) {
        address position = ps.withdrawalQueue[i];
        uint256 positionDebt = IBorrowPosition(position).totalBorrowed();
        uint256 positionCollateral = IBorrowPosition(position).totalCollateral();

        // Repay proportionally
        if (remainingDebt > 0 && positionDebt > 0 && totalDebt > 0) {
          uint256 toRepay = debtToRepay.mulDiv(positionDebt, totalDebt);
          if (toRepay > 0) {
            position.repay(ps.debtAsset, toRepay);
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
