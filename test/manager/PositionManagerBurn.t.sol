// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {
  IPositionManager,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/IPositionManager.sol";

/// @title PositionManagerBurnTest
/// @notice Tests for PositionManager burn functionality
contract PositionManagerBurnTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        BURN TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_burn_proportional() public {
    // Setup: deposit and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 totalShares = positionManager.balanceOf(minter);
    uint256 sharesToBurn = totalShares / 2;

    // Mint debt to repay
    _mintDebt(minter, DEBT_AMOUNT);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Should receive approximately half
    assertApproxEqRel(collateralReceived, COLLATERAL_AMOUNT / 2, 0.01e18, "Should receive ~50% collateral");
    assertApproxEqRel(debtRepaid, DEBT_AMOUNT / 2, 0.01e18, "Should repay ~50% debt");
    assertEq(positionManager.balanceOf(minter), totalShares - sharesToBurn, "Shares should be burned");
  }

  function test_burn_all() public {
    // Setup: deposit and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 totalShares = positionManager.balanceOf(minter);

    // Mint debt to repay all
    _mintDebt(minter, DEBT_AMOUNT);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(totalShares);

    assertEq(collateralReceived, COLLATERAL_AMOUNT, "Should receive all collateral");
    assertEq(debtRepaid, DEBT_AMOUNT, "Should repay all debt");
    assertEq(positionManager.balanceOf(minter), 0, "All shares should be burned");
    assertEq(positionManager.totalSupply(), 0, "Total supply should be 0");
  }

  function test_burn_noDebt() public {
    // Setup: deposit collateral only
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 totalShares = positionManager.balanceOf(minter);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(totalShares);

    assertEq(collateralReceived, COLLATERAL_AMOUNT, "Should receive all collateral");
    assertEq(debtRepaid, 0, "No debt to repay");
  }

  function test_burn_revertOnZeroShares() public {
    vm.prank(minter);
    vm.expectRevert(IPositionManager.ZeroAmount.selector);
    positionManager.burn(0);
  }

  function test_burn_multiPosition_proportional() public {
    // First deposit goes to position1
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Move half to position2 using rebalance
    uint256 collateralToMove = COLLATERAL_AMOUNT / 2;
    uint256 debtToMove = DEBT_AMOUNT / 2;

    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: debtToMove
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToMove
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: collateralToMove
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: debtToMove
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: debtToMove, operations: ops});

    _mintDebt(rebalancer, debtToMove);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), debtToMove);
    positionManager.rebalance(data);
    vm.stopPrank();

    // Verify both positions have collateral and debt
    assertApproxEqRel(borrowPosition1.totalCollateral(), collateralToMove, 0.01e18);
    assertApproxEqRel(borrowPosition2.totalCollateral(), collateralToMove, 0.01e18);

    // Now burn 50% of shares
    uint256 totalShares = positionManager.balanceOf(minter);
    uint256 sharesToBurn = totalShares / 2;

    _mintDebt(minter, DEBT_AMOUNT); // Provide debt for repayment
    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Should receive proportional amounts from both positions
    assertApproxEqRel(collateralReceived, COLLATERAL_AMOUNT / 2, 0.01e18, "Should receive ~50% of total collateral");
    assertApproxEqRel(debtRepaid, DEBT_AMOUNT / 2, 0.01e18, "Should repay ~50% of total debt");
  }

  /// @notice Test burn with rounding that causes capping of toRepay
  function test_burn_capsRepayAmount() public {
    // Setup: create an imbalanced scenario where proportional calculation overshoots
    // We need: debtToRepay.mulDiv(positionDebt, _totalDebt) > remainingDebt

    // This can happen with rounding when burning shares from multiple positions
    // Setup two positions with different debt ratios
    _mintCollateral(minter, COLLATERAL_AMOUNT * 2);

    // Deposit to position1
    vm.prank(minter);
    int256 shares1 = positionManager.deposit(COLLATERAL_AMOUNT, 3000e18);

    // Deposit to position2
    vm.prank(minter);
    int256 shares2 = positionManager.deposit(COLLATERAL_AMOUNT, 2000e18);

    uint256 totalShares = uint256(shares1) + uint256(shares2);
    uint256 totalDebt = positionManager.debtAmount();

    // Burn most shares - the rounding in proportional calculations should trigger capping
    uint256 sharesToBurn = totalShares * 99 / 100;
    _mintDebt(minter, totalDebt); // Enough to repay

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Verify burn succeeded
    assertGt(collateralReceived, 0, "Should receive collateral");
    assertGt(debtRepaid, 0, "Should repay debt");
  }

  /// @notice Test burn with rounding that causes capping of toWithdraw
  function test_burn_capsWithdrawAmount() public {
    // Similar to above but for collateral capping
    _mintCollateral(minter, COLLATERAL_AMOUNT * 2);

    // Deposit different collateral amounts to each position
    vm.prank(minter);
    int256 shares1 = positionManager.deposit(COLLATERAL_AMOUNT * 6 / 10, 2000e18);

    vm.prank(minter);
    int256 shares2 = positionManager.deposit(COLLATERAL_AMOUNT * 14 / 10, 3000e18);

    uint256 totalShares = uint256(shares1) + uint256(shares2);
    uint256 totalDebt = positionManager.debtAmount();

    // Burn almost all shares
    uint256 sharesToBurn = totalShares * 99 / 100;
    _mintDebt(minter, totalDebt);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    assertGt(collateralReceived, 0, "Should receive collateral");
    assertGt(debtRepaid, 0, "Should repay debt");
  }

  /// @notice Test burn proportional capping when toRepay exceeds remainingDebt
  /// @dev Covers line 583: if (toRepay > remainingDebt) toRepay = remainingDebt
  function test_burn_capsRepayProportionalExcess() public {
    // Create uneven debt distribution: position1 has almost all debt, position2 has minimal
    // This can cause proportional calculation for position1 to exceed remainingDebt

    // First deposit to position1 only (default queue starts with position1)
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Now rebalance to move a tiny bit of collateral and debt to position2
    // This creates uneven distribution
    uint256 tinyDebt = DEBT_AMOUNT / 1000; // 0.1%
    uint256 tinyCollateral = COLLATERAL_AMOUNT / 1000;

    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: tinyDebt
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: tinyCollateral
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: tinyCollateral
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: tinyDebt
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: tinyDebt, operations: ops});

    _mintDebt(rebalancer, tinyDebt);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), tinyDebt);
    positionManager.rebalance(data);
    vm.stopPrank();

    // Verify uneven distribution
    uint256 pos1Debt = borrowPosition1.totalBorrowed();
    uint256 pos2Debt = borrowPosition2.totalBorrowed();
    assertGt(pos1Debt, pos2Debt * 100, "Position1 should have much more debt");

    // Now burn a portion that when calculated proportionally for position1
    // would exceed the actual debt we want to repay
    // Burn small shares which corresponds to small debt repayment
    uint256 sharesToBurn = positionManager.balanceOf(minter) / 100; // 1%

    _mintDebt(minter, DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.burn(sharesToBurn);

    // Test passes if no revert - the capping logic handled the excess
  }

  /// @notice Test burn proportional capping when toWithdraw exceeds remainingCollateral
  /// @dev Covers line 593: if (toWithdraw > remainingCollateral) toWithdraw = remainingCollateral
  function test_burn_capsWithdrawProportionalExcess() public {
    // Create uneven collateral distribution similar to debt test
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Move tiny amount of collateral to position2
    uint256 tinyCollateral = COLLATERAL_AMOUNT / 1000;

    RebalancingOperation[] memory ops = new RebalancingOperation[](2);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: tinyCollateral
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: tinyCollateral
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    vm.prank(rebalancer);
    positionManager.rebalance(data);

    // Verify uneven distribution
    uint256 pos1Collateral = borrowPosition1.totalCollateral();
    uint256 pos2Collateral = borrowPosition2.totalCollateral();
    assertGt(pos1Collateral, pos2Collateral * 100, "Position1 should have much more collateral");

    // Burn small shares to trigger proportional capping
    uint256 sharesToBurn = positionManager.balanceOf(minter) / 100;

    vm.prank(minter);
    positionManager.burn(sharesToBurn);

    // Test passes if no revert - the capping logic handled the excess
  }
}
