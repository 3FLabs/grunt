// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {LibManagerErrors} from "../../src/libs/manager/LibManagerErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../src/libs/common/LibCommonErrors.sol";

/// @title PositionManagerWithdrawTest
/// @notice Tests for PositionManager withdraw functionality
contract PositionManagerWithdrawTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WITHDRAW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdraw_repayDebtOnly() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 sharesBefore = positionManager.balanceOf(minter);
    uint256 repayAmount = 1000e18;
    _mintDebt(minter, repayAmount);

    vm.prank(minter);
    int256 sharesDelta = positionManager.withdraw(0, repayAmount);

    // Assets increased (debt repaid), so shares should be minted
    assertGt(sharesDelta, 0, "Should mint shares when repaying debt");
    assertGt(positionManager.balanceOf(minter), sharesBefore, "Minter should have more shares");
    assertEq(positionManager.debtAmount(), DEBT_AMOUNT - repayAmount, "Debt should decrease");
  }

  function test_withdraw_collateralOnly() public {
    // Setup: deposit collateral only (no debt)
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 sharesBefore = positionManager.balanceOf(minter);
    uint256 withdrawAmount = 1000e18;

    vm.prank(minter);
    int256 sharesDelta = positionManager.withdraw(withdrawAmount, 0);

    // Assets decreased (collateral withdrawn), so shares should be burned
    assertLt(sharesDelta, 0, "Should burn shares when withdrawing collateral");
    assertLt(positionManager.balanceOf(minter), sharesBefore, "Minter should have fewer shares");
    assertEq(collateralToken.balanceOf(minter), withdrawAmount, "Minter should receive collateral");
  }

  function test_withdraw_collateralAndRepay() public {
    // Setup: deposit and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 repayAmount = DEBT_AMOUNT; // Repay all debt
    uint256 withdrawAmount = 2000e18;
    _mintDebt(minter, repayAmount);

    vm.prank(minter);
    positionManager.withdraw(withdrawAmount, repayAmount);

    assertEq(positionManager.debtAmount(), 0, "All debt should be repaid");
    assertEq(collateralToken.balanceOf(minter), withdrawAmount, "Should receive collateral");
  }

  function test_withdraw_revertOnInsufficientAvailableCollateral() public {
    // Setup: deposit and borrow at high LTV
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 6000e18); // 60% LTV

    // Try to withdraw collateral without repaying (would exceed LLTV)
    vm.prank(minter);
    vm.expectRevert(LibManagerErrors.InsufficientAvailableCollateral.selector);
    positionManager.withdraw(5000e18, 0);
  }

  function test_withdraw_revertOnZeroAmount() public {
    vm.prank(minter);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    positionManager.withdraw(0, 0);
  }

  function test_withdraw_emptyWithdrawalQueue() public {
    // First deposit normally
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Clear withdrawal queue
    address[] memory emptyQueue = new address[](0);
    vm.prank(curator);
    positionManager.setWithdrawalQueue(emptyQueue);

    // Try to withdraw collateral - should revert
    vm.prank(minter);
    vm.expectRevert(LibManagerErrors.InsufficientAvailableCollateral.selector);
    positionManager.withdraw(1000e18, 0);
  }

  /// @notice Test withdrawal repay pass skips positions with no debt (positionDebt == 0 branch)
  function test_withdraw_skipsPositionWithNoDebt() public {
    // Setup: position1 has collateral only (no debt), position2 has debt
    // To achieve this, we need to modify the supply queue so debt goes only to position2

    // First deposit collateral only to position1 (via default supply queue)
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Verify position1 has collateral but no debt
    assertGt(borrowPosition1.totalCollateral(), 0, "Position1 should have collateral");
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should have no debt");

    // Now change supply queue to only have position2
    SupplyQueueEntry[] memory newSupplyQueue = new SupplyQueueEntry[](1);
    newSupplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(newSupplyQueue);

    // Deposit with debt - all debt goes to position2
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Verify setup: position1 has no debt, position2 has debt
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should still have no debt");
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT, "Position2 should have all debt");

    // Withdrawal queue is: [position1, position2]
    // When repaying debt, it should:
    // - Check position1, find positionDebt == 0, skip (hitting our target branch!)
    // - Check position2, find debt, repay there
    _mintDebt(minter, DEBT_AMOUNT / 2);

    vm.prank(minter);
    positionManager.withdraw(0, DEBT_AMOUNT / 2);

    // Debt should be repaid from position2
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT / 2, "Position2 should have half debt repaid");
  }

  /// @notice Test withdrawal where collateral pass skips positions with no available collateral
  function test_withdraw_skipsPositionWithNoAvailableCollateral() public {
    // Setup: deposit to position1 at max LTV (no available collateral)
    // Position1: high LTV, no available collateral
    // Position2: lower LTV, has available collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT * 2);

    // First supply queue entry - borrow at near max on position1
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, (COLLATERAL_AMOUNT * 69) / 100); // 69% LTV, very close to LLTV of 70%

    // Second deposit to position2 with lower LTV
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, COLLATERAL_AMOUNT / 2); // 50% LTV

    // Try to withdraw collateral - should skip position1 (no available collateral at 70% LLTV)
    // and withdraw from position2
    vm.prank(minter);
    positionManager.withdraw(1000e18, 0);

    // Should succeed by withdrawing from position2
    assertTrue(positionManager.collateralAmount() < COLLATERAL_AMOUNT * 2, "Some collateral should be withdrawn");
  }

  /// @notice Test that repaying more debt than exists reverts
  function test_withdraw_revertOnExcessDebtRepay() public {
    // Setup: deposit collateral and borrow some debt
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 totalDebt = positionManager.debtAmount();

    // Try to repay more than total debt
    uint256 excessRepay = totalDebt + 1000e18;
    _mintDebt(minter, excessRepay);

    vm.prank(minter);
    vm.expectRevert(LibManagerErrors.ExcessDebtRepay.selector);
    positionManager.withdraw(0, excessRepay);
  }

  /// @notice Test that contract doesn't end up with debt token balance after withdrawal
  function test_withdraw_noResidualDebtBalance() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Repay exact debt amount
    _mintDebt(minter, DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.withdraw(0, DEBT_AMOUNT);

    // Contract should have no debt token balance
    assertEq(debtToken.balanceOf(address(positionManager)), 0, "PM should have no debt token balance");
  }
}
