// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {LibOperationsHarness} from "test/mock/libs/LibOperationsHarness.sol";
import {MockBorrowPosition} from "test/mock/borrow/MockBorrowPosition.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

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

    harness.setMetadata("Test PM", "TPM", 18, address(collateralToken), address(debtToken));
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

    // Fund harness with collateral
    collateralToken.mint(address(harness), 100e18);
    harness.approveToken(address(collateralToken), address(position1), 100e18);
    harness.approveToken(address(collateralToken), address(position2), 100e18);

    harness.processDeposit(100e18, 100e18);

    // Should borrow 30 from first, 70 from second (proportionally distribute collateral)
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
    harness.approveToken(address(collateralToken), address(position2), 100e18);

    harness.processDeposit(100e18, 50e18);

    assertEq(position1.totalBorrowed(), 0);
    assertEq(position2.totalBorrowed(), 50e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  processWithdrawal TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_processWithdrawal_singlePosition() public {
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

    harness.processWithdrawal(100e18, 50e18);

    assertEq(position.totalBorrowed(), 0);
    assertEq(position.totalCollateral(), 0);
    assertEq(collateralToken.balanceOf(address(harness)), 100e18);
  }

  function test_processWithdrawal_revertOnExcessDebtRepay() public {
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
    harness.processWithdrawal(100e18, 50e18);
  }

  function test_processWithdrawal_revertOnInsufficientCollateral() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(0);
    position.setTotalCollateral(50e18);
    position.setTotalCollateralQuoted(50e18);

    collateralToken.mint(address(position), 50e18);

    harness.addWithdrawalQueueEntry(address(position));

    vm.expectRevert(LibManagerErrors.InsufficientAvailableCollateral.selector);
    harness.processWithdrawal(100e18, 0);
  }

  function test_processWithdrawal_multiplePositions() public {
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

    harness.processWithdrawal(100e18, 50e18);

    assertEq(position1.totalBorrowed(), 0);
    assertEq(position2.totalBorrowed(), 0);
    assertEq(collateralToken.balanceOf(address(harness)), 100e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     processBurn TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_processBurn_singlePosition() public {
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
    harness.processBurn(100e18, 50e18, 200e18, 100e18);

    assertEq(position.totalBorrowed(), 50e18);
    assertEq(position.totalCollateral(), 100e18);
    assertEq(collateralToken.balanceOf(address(harness)), 100e18);
  }

  function test_processBurn_multiplePositions() public {
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
    harness.processBurn(100e18, 50e18, 200e18, 100e18);

    // Debt repaid proportionally: 60% from position1, 40% from position2
    assertEq(position1.totalBorrowed(), 30e18); // 60 - 50*60/100 = 30
    assertEq(position2.totalBorrowed(), 20e18); // 40 - 50*40/100 = 20

    // Collateral withdrawn proportionally: 50% each (100 each total)
    assertEq(position1.totalCollateral(), 50e18); // 100 - 100*100/200 = 50
    assertEq(position2.totalCollateral(), 50e18); // 100 - 100*100/200 = 50
  }

  function test_processBurn_zeroDebt() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(0);
    position.setTotalCollateral(100e18);
    position.setTotalCollateralQuoted(100e18);

    collateralToken.mint(address(position), 100e18);

    harness.addWithdrawalQueueEntry(address(position));

    harness.processBurn(50e18, 0, 100e18, 0);

    assertEq(position.totalCollateral(), 50e18);
    assertEq(collateralToken.balanceOf(address(harness)), 50e18);
  }

  function test_processBurn_zeroCollateral() public {
    MockBorrowPosition position = new MockBorrowPosition(address(collateralToken), address(debtToken));
    position.setTotalBorrowed(100e18);
    position.setTotalCollateral(0);

    harness.addWithdrawalQueueEntry(address(position));

    debtToken.mint(address(harness), 50e18);
    harness.approveToken(address(debtToken), address(position), 50e18);

    harness.processBurn(0, 50e18, 0, 100e18);

    assertEq(position.totalBorrowed(), 50e18);
  }
}
