// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {LibOperationsHarness} from "test/mock/libs/LibOperationsHarness.sol";
import {MockBorrowPosition} from "test/mock/borrow/MockBorrowPosition.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";

/// @title LibOperationsTest
/// @notice Unit tests for manager LibOperations library
contract LibOperationsTest is Test {
  LibOperationsHarness harness;
  MockERC20 collateralToken;
  MockERC20 debtToken;

  function setUp() public {
    harness = new LibOperationsHarness();
    collateralToken = new MockERC20("Collateral", "COL", 18);
    debtToken = new MockERC20("Debt", "DEBT", 18);

    harness.setMetadata("Test PM", "TPM", address(collateralToken), address(debtToken));
    harness.setLtv(0.86e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   processDeposit TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_processDeposit_singlePosition() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(1000e18);

    // Fund position with debt tokens to borrow from
    debtToken.mint(address(position), 1000e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    // Fund harness with collateral
    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    harness.processDeposit(100e18, 50e18);

    assertEq(position.totalCollateral(), 100e18);
    assertEq(position.totalBorrowed(), 50e18);
    assertEq(debtToken.balanceOf(address(harness)), 50e18);
  }

  function test_processDeposit_multiplePositions() public {
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    position1.setAvailableLiquidity(30e18);
    position2.setAvailableLiquidity(70e18);

    debtToken.mint(address(position1), 30e18);
    debtToken.mint(address(position2), 70e18);

    harness.addSupplyQueueEntry(address(position1), type(uint96).max);
    harness.addSupplyQueueEntry(address(position2), type(uint96).max);

    // At 86% LTV, borrowing 100 total requires ceil(100/0.86) ≈ 117 collateral
    // Supply enough collateral to cover both positions
    collateralToken.mint(address(harness), 120e18);
    harness.approveToken(address(collateralToken), address(position1), 120e18);
    harness.approveToken(address(collateralToken), address(position2), 120e18);

    harness.processDeposit(120e18, 100e18);

    // Should borrow 30 from first, 70 from second
    assertEq(position1.totalBorrowed(), 30e18);
    assertEq(position2.totalBorrowed(), 70e18);
    assertEq(debtToken.balanceOf(address(harness)), 100e18);
  }

  function test_processDeposit_respectsMaxBorrow() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(1000e18);
    debtToken.mint(address(position), 1000e18);

    // Set maxBorrow to 50
    harness.addSupplyQueueEntry(address(position), 50e18);

    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    harness.processDeposit(100e18, 50e18);

    assertEq(position.totalBorrowed(), 50e18);
  }

  function test_processDeposit_revertOnInsufficientBorrowCapacity() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(50e18);
    debtToken.mint(address(position), 50e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    vm.expectRevert(LibManagerErrors.InsufficientBorrowCapacity.selector);
    harness.processDeposit(100e18, 100e18);
  }

  function test_processDeposit_zeroDebt() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    // Should not revert - zero debt means nothing to borrow
    harness.processDeposit(100e18, 0);
  }

  function test_processDeposit_skipPositionWithZeroLiquidity() public {
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    position1.setAvailableLiquidity(0); // No liquidity
    position2.setAvailableLiquidity(100e18);

    debtToken.mint(address(position2), 100e18);

    harness.addSupplyQueueEntry(address(position1), type(uint96).max);
    harness.addSupplyQueueEntry(address(position2), type(uint96).max);

    collateralToken.mint(address(harness), 100e18);
    // Approve both: position2 for the borrow collateral, position1 for leftover collateral
    harness.approveToken(address(collateralToken), address(position1), 100e18);
    harness.approveToken(address(collateralToken), address(position2), 100e18);

    harness.processDeposit(100e18, 50e18);

    assertEq(position1.totalBorrowed(), 0);
    assertEq(position2.totalBorrowed(), 50e18);
    // Leftover collateral goes to the first position in the supply queue
    assertGt(position1.totalCollateral(), 0, "Leftover collateral should go to first position");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             processDeposit LTV CONSTRAINT TESTS              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_processDeposit_respectsLtv_singlePosition() public {
    // At 86% LTV with 1:1 price, borrowing 86 requires ceil(86/0.86) = 100 collateral
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(1000e18);
    debtToken.mint(address(position), 1000e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    harness.processDeposit(100e18, 86e18);

    // Position should have exactly 100 collateral and 86 borrowed (86% LTV)
    assertEq(position.totalCollateral(), 100e18, "All collateral should be supplied");
    assertEq(position.totalBorrowed(), 86e18, "Should borrow exactly 86");
  }

  function test_processDeposit_cannotExceedLtv() public {
    // Trying to borrow 90 with 100 collateral at 86% LTV should fail
    // because 90/100 = 90% > 86%
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(1000e18);
    debtToken.mint(address(position), 1000e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    // borrowForCollateral(100, 0.86) = 86, which is less than 90 → remaining debt > 0
    vm.expectRevert(LibManagerErrors.InsufficientBorrowCapacity.selector);
    harness.processDeposit(100e18, 90e18);
  }

  function test_processDeposit_ltvBoundCollateralAllocation() public {
    // Two positions with enough liquidity. Collateral should be allocated per LTV needs, not proportionally.
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    position1.setAvailableLiquidity(50e18);
    position2.setAvailableLiquidity(50e18);

    debtToken.mint(address(position1), 50e18);
    debtToken.mint(address(position2), 50e18);

    harness.addSupplyQueueEntry(address(position1), type(uint96).max);
    harness.addSupplyQueueEntry(address(position2), type(uint96).max);

    // At 86% LTV, borrowing 50+50=100 requires ceil(100/0.86) ≈ 117 collateral total
    collateralToken.mint(address(harness), 120e18);
    harness.approveToken(address(collateralToken), address(position1), 120e18);
    harness.approveToken(address(collateralToken), address(position2), 120e18);

    harness.processDeposit(120e18, 100e18);

    // Each position should be at or below 86% LTV
    // position1: borrowed=50, collateral=ceil(50/0.86)≈59
    assertLe(
      position1.totalBorrowed() * 1e18 / position1.totalCollateral(),
      0.86e18,
      "Position 1 should be at or below 86% LTV"
    );
    // position2: borrowed=50, collateral=ceil(50/0.86)≈59
    assertLe(
      position2.totalBorrowed() * 1e18 / position2.totalCollateral(),
      0.86e18,
      "Position 2 should be at or below 86% LTV"
    );
    // Total borrowed should be 100
    assertEq(position1.totalBorrowed() + position2.totalBorrowed(), 100e18);
  }

  function test_processDeposit_leftoverCollateralGoesToFirstPosition() public {
    // If collateral exceeds what's needed for borrowing, the excess goes to position[0]
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(100e18);
    debtToken.mint(address(position), 100e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    // Supply 200 collateral but only borrow 50 (needs ~59 at 86% LTV, 141 leftover)
    collateralToken.mint(address(harness), 200e18);
    harness.approveToken(address(collateralToken), address(position), 200e18);

    harness.processDeposit(200e18, 50e18);

    // All 200 collateral should end up in the position (59 for borrow + 141 leftover)
    assertEq(position.totalCollateral(), 200e18, "All collateral should be in the position");
    assertEq(position.totalBorrowed(), 50e18, "Should borrow exactly 50");
  }

  function test_processDeposit_collateralConstrainedBorrow() public {
    // Position has lots of liquidity, but limited collateral means limited borrow
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(1000e18);
    debtToken.mint(address(position), 1000e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    // Only 50 collateral → at 86% LTV, max borrow = 50 * 0.86 = 43
    collateralToken.mint(address(harness), 50e18);
    harness.approveToken(address(collateralToken), address(position), 50e18);

    // Requesting 43 should work
    harness.processDeposit(50e18, 43e18);

    assertEq(position.totalBorrowed(), 43e18);
    assertEq(position.totalCollateral(), 50e18);
  }

  function test_processDeposit_collateralFallbackReducesBorrow() public {
    // When collateral can't cover the full borrow, toBorrow is reduced via borrowForCollateral
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    position1.setAvailableLiquidity(100e18);
    position2.setAvailableLiquidity(100e18);
    debtToken.mint(address(position1), 100e18);
    debtToken.mint(address(position2), 100e18);

    harness.addSupplyQueueEntry(address(position1), type(uint96).max);
    harness.addSupplyQueueEntry(address(position2), type(uint96).max);

    // 100 collateral, trying to borrow 100+100=200. At 86% LTV, needs 233 collateral.
    // Position1 tries to borrow 100, needs ~117 collateral. Only 100 available.
    // Falls back: borrowForCollateral(100, 0.86) = 86. Supplies 100 collateral, borrows 86.
    // Position2 tries to borrow remaining 114, needs ~133 collateral. Only 0 remaining.
    // Falls back: borrowForCollateral(0, 0.86) = 0, skip.
    // remainingDebt = 114 > 0 → revert
    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position1), 100e18);
    harness.approveToken(address(collateralToken), address(position2), 100e18);

    vm.expectRevert(LibManagerErrors.InsufficientBorrowCapacity.selector);
    harness.processDeposit(100e18, 200e18);
  }

  function test_processDeposit_existingPositionWithExcessCollateral() public {
    // Position already has collateral that can absorb new borrow without needing more
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(100e18);
    position.setTotalCollateral(200e18); // Already has 200 collateral, 0 debt
    position.setTotalCollateralQuoted(200e18);
    debtToken.mint(address(position), 100e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    // At 86% LTV, 200 existing collateral supports 172 borrow. Borrowing 50 needs 0 new collateral.
    collateralToken.mint(address(harness), 10e18);
    harness.approveToken(address(collateralToken), address(position), 10e18);

    harness.processDeposit(10e18, 50e18);

    // Should borrow 50 without adding collateral (existing 200 covers it)
    assertEq(position.totalBorrowed(), 50e18);
    // All 10 collateral goes as leftover to position[0]
    assertEq(position.totalCollateral(), 210e18, "Leftover collateral added to first position");
  }

  function test_processDeposit_multiplePositions_ltvPerPosition() public {
    // Verify each position individually stays within LTV, not just the aggregate
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position3 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    position1.setAvailableLiquidity(40e18);
    position2.setAvailableLiquidity(30e18);
    position3.setAvailableLiquidity(30e18);
    debtToken.mint(address(position1), 40e18);
    debtToken.mint(address(position2), 30e18);
    debtToken.mint(address(position3), 30e18);

    harness.addSupplyQueueEntry(address(position1), type(uint96).max);
    harness.addSupplyQueueEntry(address(position2), type(uint96).max);
    harness.addSupplyQueueEntry(address(position3), type(uint96).max);

    // Need enough collateral: ceil(100/0.86) ≈ 117
    collateralToken.mint(address(harness), 120e18);
    harness.approveToken(address(collateralToken), address(position1), 120e18);
    harness.approveToken(address(collateralToken), address(position2), 120e18);
    harness.approveToken(address(collateralToken), address(position3), 120e18);

    harness.processDeposit(120e18, 100e18);

    // Each position must individually be at or below 86% LTV
    if (position1.totalCollateral() > 0 && position1.totalBorrowed() > 0) {
      assertLe(position1.totalBorrowed() * 1e18 / position1.totalCollateral(), 0.86e18, "Position 1 exceeds LTV");
    }
    if (position2.totalCollateral() > 0 && position2.totalBorrowed() > 0) {
      assertLe(position2.totalBorrowed() * 1e18 / position2.totalCollateral(), 0.86e18, "Position 2 exceeds LTV");
    }
    if (position3.totalCollateral() > 0 && position3.totalBorrowed() > 0) {
      assertLe(position3.totalBorrowed() * 1e18 / position3.totalCollateral(), 0.86e18, "Position 3 exceeds LTV");
    }

    // Total borrowed must be 100
    assertEq(
      position1.totalBorrowed() + position2.totalBorrowed() + position3.totalBorrowed(),
      100e18,
      "Total borrowed must match requested debt"
    );
  }

  function test_processDeposit_differentLtvValues() public {
    // Test with a lower LTV (50%) — should require more collateral
    harness.setLtv(0.5e18);

    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(1000e18);
    debtToken.mint(address(position), 1000e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    // At 50% LTV, borrowing 50 requires 100 collateral
    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    harness.processDeposit(100e18, 50e18);

    assertEq(position.totalBorrowed(), 50e18);
    assertEq(position.totalCollateral(), 100e18);
    // 50/100 = 50% = LTV, exactly at the limit
    assertEq(position.totalBorrowed() * 1e18 / position.totalCollateral(), 0.5e18);
  }

  function test_processDeposit_differentLtv_insufficientCollateral() public {
    // At 50% LTV, 100 collateral can only borrow 50. Requesting 60 should fail.
    harness.setLtv(0.5e18);

    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setAvailableLiquidity(1000e18);
    debtToken.mint(address(position), 1000e18);

    harness.addSupplyQueueEntry(address(position), type(uint96).max);

    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position), 100e18);

    vm.expectRevert(LibManagerErrors.InsufficientBorrowCapacity.selector);
    harness.processDeposit(100e18, 60e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  withdrawSequential TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdrawSequential_singlePosition() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(50e18);
    position.setTotalCollateral(100e18);
    position.setTotalCollateralQuoted(100e18);

    // Fund position with collateral to withdraw
    collateralToken.mint(address(position), 100e18);

    harness.addWithdrawalQueueEntry(address(position));

    // Fund harness with debt to repay
    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position), 50e18);

    harness.processWithdrawal(100e18, 50e18, WithdrawalStrategy.SEQUENTIAL, false);

    assertEq(position.totalBorrowed(), 0);
    assertEq(position.totalCollateral(), 0);
    assertEq(collateralToken.balanceOf(address(harness)), 100e18);
  }

  function test_withdrawSequential_revertOnExcessDebtRepay() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(30e18);
    position.setTotalCollateral(100e18);
    position.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position), 100e18);

    harness.addWithdrawalQueueEntry(address(position));

    // Try to repay more debt than exists
    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position), 50e18);

    vm.expectRevert(LibManagerErrors.ExcessDebtRepay.selector);
    harness.processWithdrawal(100e18, 50e18, WithdrawalStrategy.SEQUENTIAL, false);
  }

  function test_withdrawSequential_revertOnInsufficientCollateral() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(0);
    position.setTotalCollateral(50e18);
    position.setTotalCollateralQuoted(50e18);

    collateralToken.mint(address(position), 50e18);

    harness.addWithdrawalQueueEntry(address(position));

    vm.expectRevert(LibManagerErrors.InsufficientAvailableCollateral.selector);
    harness.processWithdrawal(100e18, 0, WithdrawalStrategy.SEQUENTIAL, false);
  }

  function test_withdrawSequential_multiplePositions() public {
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    position1.setTotalBorrowed(30e18);
    position1.setTotalCollateral(50e18);
    position1.setTotalCollateralQuoted(50e18);
    position2.setTotalBorrowed(20e18);
    position2.setTotalCollateral(50e18);
    position2.setTotalCollateralQuoted(50e18);

    collateralToken.mint(address(position1), 50e18);
    collateralToken.mint(address(position2), 50e18);

    harness.addWithdrawalQueueEntry(address(position1));
    harness.addWithdrawalQueueEntry(address(position2));

    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position1), 50e18);
    harness.approveToken(address(debtToken), address(position2), 50e18);

    harness.processWithdrawal(100e18, 50e18, WithdrawalStrategy.SEQUENTIAL, false);

    assertEq(position1.totalBorrowed(), 0);
    assertEq(position2.totalBorrowed(), 0);
    assertEq(collateralToken.balanceOf(address(harness)), 100e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     withdrawProportional TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdrawProportional_singlePosition() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(100e18);
    position.setTotalCollateral(200e18);
    position.setTotalCollateralQuoted(200e18);

    collateralToken.mint(address(position), 200e18);

    harness.addWithdrawalQueueEntry(address(position));

    // Fund harness with debt to repay
    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position), 50e18);

    // Burn 50% of position
    harness.processWithdrawal(100e18, 50e18, WithdrawalStrategy.PROPORTIONAL, false);

    assertEq(position.totalBorrowed(), 50e18);
    assertEq(position.totalCollateral(), 100e18);
    assertEq(collateralToken.balanceOf(address(harness)), 100e18);
  }

  function test_withdrawProportional_multiplePositions() public {
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    position1.setTotalBorrowed(60e18);
    position1.setTotalCollateral(100e18);
    position1.setTotalCollateralQuoted(100e18);
    position2.setTotalBorrowed(40e18);
    position2.setTotalCollateral(100e18);
    position2.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position1), 100e18);
    collateralToken.mint(address(position2), 100e18);

    harness.addWithdrawalQueueEntry(address(position1));
    harness.addWithdrawalQueueEntry(address(position2));

    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position1), 50e18);
    harness.approveToken(address(debtToken), address(position2), 50e18);

    // Burn 50% proportionally
    harness.processWithdrawal(100e18, 50e18, WithdrawalStrategy.PROPORTIONAL, false);

    // Debt repaid proportionally: 60% from position1, 40% from position2
    assertEq(position1.totalBorrowed(), 30e18); // 60 - 50*60/100 = 30
    assertEq(position2.totalBorrowed(), 20e18); // 40 - 50*40/100 = 20

    // Collateral withdrawn proportionally: 50% each (100 each total)
    assertEq(position1.totalCollateral(), 50e18); // 100 - 100*100/200 = 50
    assertEq(position2.totalCollateral(), 50e18); // 100 - 100*100/200 = 50
  }

  function test_withdrawProportional_zeroDebt() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(0);
    position.setTotalCollateral(100e18);
    position.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position), 100e18);

    harness.addWithdrawalQueueEntry(address(position));

    harness.processWithdrawal(50e18, 0, WithdrawalStrategy.PROPORTIONAL, false);

    assertEq(position.totalCollateral(), 50e18);
    assertEq(collateralToken.balanceOf(address(harness)), 50e18);
  }

  function test_withdrawProportional_zeroCollateral() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(100e18);
    position.setTotalCollateral(0);

    harness.addWithdrawalQueueEntry(address(position));

    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position), 50e18);

    harness.processWithdrawal(0, 50e18, WithdrawalStrategy.PROPORTIONAL, false);

    assertEq(position.totalBorrowed(), 50e18);
  }

  function test_withdrawProportional_revertOnExcessDebtRepay() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(30e18);
    position.setTotalCollateral(100e18);
    position.setTotalCollateralQuoted(100e18);

    harness.addWithdrawalQueueEntry(address(position));

    vm.expectRevert(LibManagerErrors.ExcessDebtRepay.selector);
    harness.processWithdrawal(50e18, 50e18, WithdrawalStrategy.PROPORTIONAL, false);
  }

  function test_withdrawProportional_revertOnInsufficientCollateral() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(100e18);
    position.setTotalCollateral(30e18);
    position.setTotalCollateralQuoted(30e18);

    harness.addWithdrawalQueueEntry(address(position));

    vm.expectRevert(LibManagerErrors.InsufficientAvailableCollateral.selector);
    harness.processWithdrawal(50e18, 50e18, WithdrawalStrategy.PROPORTIONAL, false);
  }

  /// @notice Reproduces the over-repay bug on the last position when debt is skewed.
  /// Uses small raw values (no e18) to amplify integer division rounding.
  /// 10 queue entries: debts = [10, 10, 10, 10, 10, 10, 10, 10, 10, 1], queueTotalDebt = 91
  /// debtToRepay = 90
  /// Positions 0-8: toRepay = mulDiv(90, 10, 91) = 9 each → 81 total repaid
  /// Position 9 (last): toRepay = remainingDebt = 90 - 81 = 9, but debt is only 1 → revert
  function test_withdrawProportional_overRepayLastPosition_skewedDebt() public {
    uint256 numPositions = 10;
    MockBorrowPosition[] memory positions = new MockBorrowPosition[](numPositions);

    // Create 9 positions with debt=10 and 1 position with debt=1 (raw values, no e18)
    // Each position has collateral=20 (enough to not be the bottleneck)
    for (uint256 i = 0; i < numPositions; i++) {
      positions[i] = new MockBorrowPosition(address(collateralToken), address(debtToken));
      uint256 debt = (i == numPositions - 1) ? 1 : 10;
      positions[i].setTotalBorrowed(debt);
      positions[i].setTotalCollateral(20);
      positions[i].setTotalCollateralQuoted(20);
      collateralToken.mint(address(positions[i]), 20);
      harness.addWithdrawalQueueEntry(address(positions[i]));
    }
    // queueTotalDebt = 9*10 + 1 = 91

    uint256 debtToRepay = 90;
    uint256 collateralToWithdraw = 100;

    // Fund harness with debt tokens and approve all positions
    debtToken.mint(address(harness), debtToRepay);
    for (uint256 i = 0; i < numPositions; i++) {
      harness.approveToken(address(debtToken), address(positions[i]), debtToRepay);
    }

    // This should NOT revert — the total debt in the queue (91) covers debtToRepay (90).
    // But the current implementation assigns remainingDebt=9 to position 9 which only has debt=1.
    harness.processWithdrawal(collateralToWithdraw, debtToRepay, WithdrawalStrategy.PROPORTIONAL, false);

    // Verify no position was over-repaid
    for (uint256 i = 0; i < numPositions; i++) {
      assertGe(positions[i].totalBorrowed(), 0, "position debt should not underflow");
    }
  }

  /// @notice Same issue for collateral: skewed collateral causes over-withdraw on last position.
  /// Uses small raw values to amplify integer division rounding.
  /// 10 queue entries: collaterals = [20, 20, 20, 20, 20, 20, 20, 20, 20, 1], queueTotalCollateral = 181
  /// collateralToWithdraw = 180
  /// Positions 0-8: toWithdraw = mulDiv(180, 20, 181) = 19 each → 171 total
  /// Position 9 (last): toWithdraw = remainingCollateral = 180 - 171 = 9, but collateral is only 1 → revert
  function test_withdrawProportional_overWithdrawLastPosition_skewedCollateral() public {
    uint256 numPositions = 10;
    MockBorrowPosition[] memory positions = new MockBorrowPosition[](numPositions);

    for (uint256 i = 0; i < numPositions; i++) {
      positions[i] = new MockBorrowPosition(address(collateralToken), address(debtToken));
      uint256 coll = (i == numPositions - 1) ? 1 : 20;
      positions[i].setTotalBorrowed(10);
      positions[i].setTotalCollateral(coll);
      positions[i].setTotalCollateralQuoted(coll);
      collateralToken.mint(address(positions[i]), coll);
      harness.addWithdrawalQueueEntry(address(positions[i]));
    }
    // queueTotalCollateral = 9*20 + 1 = 181

    uint256 debtToRepay = 50;
    uint256 collateralToWithdraw = 180;

    debtToken.mint(address(harness), debtToRepay);
    for (uint256 i = 0; i < numPositions; i++) {
      harness.approveToken(address(debtToken), address(positions[i]), debtToRepay);
    }

    // This should NOT revert — total collateral (181) covers withdrawal (180).
    // But current code assigns remainingCollateral=9 to position 9 which only has collateral=1.
    harness.processWithdrawal(collateralToWithdraw, debtToRepay, WithdrawalStrategy.PROPORTIONAL, false);

    for (uint256 i = 0; i < numPositions; i++) {
      assertGe(positions[i].totalCollateral(), 0, "position collateral should not underflow");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*          withdrawProportional checkLtv TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdrawProportional_checkLtv_revertsWhenExceedsAvailable() public {
    // Two positions at 86% LTV. Withdraw collateral without repaying enough debt
    // so that the proportional withdrawal exceeds per-position availableCollateral.
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    // Both positions at ~86% LTV: 86 debt / 100 collateral
    position1.setTotalBorrowed(86e18);
    position1.setTotalCollateral(100e18);
    position1.setTotalCollateralQuoted(100e18);
    position2.setTotalBorrowed(86e18);
    position2.setTotalCollateral(100e18);
    position2.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position1), 100e18);
    collateralToken.mint(address(position2), 100e18);

    harness.addWithdrawalQueueEntry(address(position1));
    harness.addWithdrawalQueueEntry(address(position2));

    // Try to withdraw 50 collateral with 0 debt repayment.
    // At 86% LTV with 86 debt and 100 collateral, availableCollateral = 100 - ceil(86/0.86) = 0.
    // So any collateral withdrawal should revert with checkLtv=true.
    vm.expectRevert(LibManagerErrors.InsufficientAvailableCollateral.selector);
    harness.processWithdrawal(50e18, 0, WithdrawalStrategy.PROPORTIONAL, true);
  }

  function test_withdrawProportional_checkLtv_succeedsWhenSufficientRepayment() public {
    // Repay enough debt so that each position has sufficient availableCollateral.
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    // Both positions: 50 debt / 100 collateral (50% LTV, well below 86% limit)
    position1.setTotalBorrowed(50e18);
    position1.setTotalCollateral(100e18);
    position1.setTotalCollateralQuoted(100e18);
    position2.setTotalBorrowed(50e18);
    position2.setTotalCollateral(100e18);
    position2.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position1), 100e18);
    collateralToken.mint(address(position2), 100e18);

    harness.addWithdrawalQueueEntry(address(position1));
    harness.addWithdrawalQueueEntry(address(position2));

    // Repay 50 debt proportionally (25 each), then withdraw 20 collateral (10 each).
    // After repay: each position has 25 debt / 100 collateral.
    // availableCollateral(0.86) = 100 - ceil(25/0.86) ≈ 100 - 30 = 70. 10 < 70, so OK.
    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position1), 50e18);
    harness.approveToken(address(debtToken), address(position2), 50e18);

    harness.processWithdrawal(20e18, 50e18, WithdrawalStrategy.PROPORTIONAL, true);

    assertEq(position1.totalBorrowed(), 25e18);
    assertEq(position2.totalBorrowed(), 25e18);
    assertEq(position1.totalCollateral(), 90e18);
    assertEq(position2.totalCollateral(), 90e18);
    assertEq(collateralToken.balanceOf(address(harness)), 20e18);
  }

  function test_withdrawProportional_checkLtv_false_skipsLtvCheck() public {
    // Same scenario as the revert test above, but with checkLtv=false (burn path).
    // Should succeed because LTV is not checked.
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    // Both positions at ~86% LTV
    position1.setTotalBorrowed(86e18);
    position1.setTotalCollateral(100e18);
    position1.setTotalCollateralQuoted(100e18);
    position2.setTotalBorrowed(86e18);
    position2.setTotalCollateral(100e18);
    position2.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position1), 100e18);
    collateralToken.mint(address(position2), 100e18);

    harness.addWithdrawalQueueEntry(address(position1));
    harness.addWithdrawalQueueEntry(address(position2));

    // Repay 86 debt proportionally, withdraw 50 collateral. After repay each has 43 debt / 100 coll.
    // availableCollateral(0.86) = 100 - ceil(43/0.86) = 100 - 50 = 50. 25 <= 50, so passes anyway.
    // But let's do 0 debt repayment + 50 withdrawal — same as the revert test but checkLtv=false.
    // This should succeed (burn path doesn't check LTV).
    harness.processWithdrawal(50e18, 0, WithdrawalStrategy.PROPORTIONAL, false);

    assertEq(position1.totalCollateral(), 75e18);
    assertEq(position2.totalCollateral(), 75e18);
  }

  function test_withdrawProportional_checkLtv_multiplePositions_partialLtvViolation() public {
    // One position is tight on LTV, the other has room. Proportional withdrawal should
    // revert if the tight position can't release its proportional share.
    MockBorrowPosition position1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition position2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    // Position1: 86 debt / 100 collateral (tight, no room)
    position1.setTotalBorrowed(86e18);
    position1.setTotalCollateral(100e18);
    position1.setTotalCollateralQuoted(100e18);
    // Position2: 0 debt / 100 collateral (lots of room)
    position2.setTotalBorrowed(0);
    position2.setTotalCollateral(100e18);
    position2.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position1), 100e18);
    collateralToken.mint(address(position2), 100e18);

    harness.addWithdrawalQueueEntry(address(position1));
    harness.addWithdrawalQueueEntry(address(position2));

    // Withdraw 100 collateral proportionally (50 from each), repay 0 debt.
    // Position1 availableCollateral(0.86) = 100 - ceil(86/0.86) = 0. Needs 50. Revert.
    vm.expectRevert(LibManagerErrors.InsufficientAvailableCollateral.selector);
    harness.processWithdrawal(100e18, 0, WithdrawalStrategy.PROPORTIONAL, true);
  }

  function test_withdrawProportional_checkLtv_zeroCollateralWithdrawal() public {
    // checkLtv=true but collateralToWithdraw=0. Should succeed (no LTV check needed).
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(86e18);
    position.setTotalCollateral(100e18);
    position.setTotalCollateralQuoted(100e18);

    harness.addWithdrawalQueueEntry(address(position));

    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position), 50e18);

    // Only repay debt, no collateral withdrawal — should always work
    harness.processWithdrawal(0, 50e18, WithdrawalStrategy.PROPORTIONAL, true);

    assertEq(position.totalBorrowed(), 36e18);
  }
}
