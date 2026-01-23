// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibExecutorHarness} from "test/mock/libs/LibExecutorHarness.sol";
import {MockBorrowPosition} from "test/mock/borrow/MockBorrowPosition.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title LibExecutorTest
/// @notice Unit tests for manager LibExecutor library
contract LibExecutorTest is Test {
  LibExecutorHarness harness;
  MockBorrowPosition position;
  MockERC20 collateralToken;
  MockERC20 debtToken;

  function setUp() public {
    collateralToken = new MockERC20("Collateral", "COL", 18);
    debtToken = new MockERC20("Debt", "DEBT", 18);

    harness = new LibExecutorHarness();
    position = new MockBorrowPosition(address(collateralToken), address(debtToken));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       supply TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_supply_approvesAndResetsApproval() public {
    collateralToken.mint(address(harness), 100e18);

    // Before supply, allowance should be 0
    assertEq(collateralToken.allowance(address(harness), address(position)), 0);

    harness.supply(address(position), address(collateralToken), 100e18);

    // After supply, allowance should be reset to 0
    assertEq(collateralToken.allowance(address(harness), address(position)), 0);
  }

  function testFuzz_supply(uint128 amount) public {
    vm.assume(amount > 0);

    collateralToken.mint(address(harness), amount);

    harness.supply(address(position), address(collateralToken), amount);

    assertEq(position.totalCollateral(), amount);
    assertEq(collateralToken.balanceOf(address(position)), amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      withdraw TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_withdraw(uint128 supplyAmount, uint128 withdrawAmount) public {
    vm.assume(supplyAmount > 0);
    vm.assume(withdrawAmount > 0 && withdrawAmount <= supplyAmount);

    collateralToken.mint(address(harness), supplyAmount);
    harness.supply(address(position), address(collateralToken), supplyAmount);

    harness.withdraw(address(position), withdrawAmount);

    assertEq(position.totalCollateral(), uint256(supplyAmount) - uint256(withdrawAmount));
    assertEq(collateralToken.balanceOf(address(harness)), withdrawAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        borrow TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_borrow(uint128 liquidity, uint128 borrowAmount) public {
    vm.assume(liquidity > 0);
    vm.assume(borrowAmount > 0 && borrowAmount <= liquidity);

    debtToken.mint(address(position), liquidity);
    position.setAvailableLiquidity(liquidity);

    harness.borrow(address(position), borrowAmount);

    assertEq(position.totalBorrowed(), borrowAmount);
    assertEq(debtToken.balanceOf(address(harness)), borrowAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        repay TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_repay_approvesAndResetsApproval() public {
    debtToken.mint(address(position), 100e18);
    position.setAvailableLiquidity(100e18);
    harness.borrow(address(position), 100e18);

    // Before repay, allowance should be 0
    assertEq(debtToken.allowance(address(harness), address(position)), 0);

    harness.repay(address(position), address(debtToken), 50e18);

    // After repay, allowance should be reset to 0
    assertEq(debtToken.allowance(address(harness), address(position)), 0);
  }

  function testFuzz_repay(uint128 borrowAmount, uint128 repayAmount) public {
    vm.assume(borrowAmount > 0);
    vm.assume(repayAmount > 0 && repayAmount <= borrowAmount);

    debtToken.mint(address(position), borrowAmount);
    position.setAvailableLiquidity(borrowAmount);
    harness.borrow(address(position), borrowAmount);

    harness.repay(address(position), address(debtToken), repayAmount);

    assertEq(position.totalBorrowed(), uint256(borrowAmount) - uint256(repayAmount));
    assertEq(debtToken.balanceOf(address(harness)), uint256(borrowAmount) - uint256(repayAmount));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    COMBINED TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_fullCycle_supplyBorrowRepayWithdraw() public {
    // Supply collateral
    collateralToken.mint(address(harness), 100e18);
    harness.supply(address(position), address(collateralToken), 100e18);

    // Borrow debt
    debtToken.mint(address(position), 50e18);
    position.setAvailableLiquidity(50e18);
    harness.borrow(address(position), 50e18);

    assertEq(position.totalCollateral(), 100e18);
    assertEq(position.totalBorrowed(), 50e18);
    assertEq(collateralToken.balanceOf(address(harness)), 0);
    assertEq(debtToken.balanceOf(address(harness)), 50e18);

    // Repay debt
    harness.repay(address(position), address(debtToken), 50e18);

    assertEq(position.totalBorrowed(), 0);

    // Withdraw collateral
    harness.withdraw(address(position), 100e18);

    assertEq(position.totalCollateral(), 0);
    assertEq(collateralToken.balanceOf(address(harness)), 100e18);
  }
}
