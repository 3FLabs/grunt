// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {IPositionManager, SupplyQueueEntry, WithdrawalStrategy} from "src/interfaces/manager/IPositionManager.sol";
import {LibManagerErrors} from "../../src/libs/manager/LibManagerErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../src/libs/common/LibCommonErrors.sol";

/// @title PositionManagerDepositTest
/// @notice Tests for PositionManager deposit functionality
contract PositionManagerDepositTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       DEPOSIT TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_debtOnly() public {
    // First deposit some collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 sharesBefore = positionManager.balanceOf(minter);
    uint256 additionalDebt = 1000e18;

    // Now deposit with only debt (borrow more)
    vm.prank(minter);
    int256 sharesDelta = positionManager.deposit(0, additionalDebt);

    // Assets decreased (borrowed more), so shares should be burned
    assertLt(sharesDelta, 0, "Should burn shares when only borrowing");
    assertLt(positionManager.balanceOf(minter), sharesBefore, "Minter should have fewer shares");
    assertEq(positionManager.debtAmount(), additionalDebt, "Debt should increase");
  }

  function test_deposit_revertOnZeroAmount() public {
    vm.prank(minter);
    vm.expectRevert(CommonErrors.AmountZero.selector);
    positionManager.deposit(0, 0);
  }

  function test_deposit_revertOnUnauthorized() public {
    _mintCollateral(user, COLLATERAL_AMOUNT);

    vm.prank(user);
    collateralToken.approve(address(positionManager), COLLATERAL_AMOUNT);

    vm.prank(user);
    vm.expectRevert();
    positionManager.deposit(COLLATERAL_AMOUNT, 0);
  }

  function test_deposit_multipleDeposits() public {
    // First deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares1 = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Second deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares2 = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    assertGt(shares1, 0);
    assertGt(shares2, 0);
    assertEq(positionManager.collateralAmount(), COLLATERAL_AMOUNT * 2);
    assertEq(positionManager.debtAmount(), DEBT_AMOUNT * 2);
  }

  /// @notice Test deposit skips positions with no available liquidity (toBorrow == 0 branch)
  function test_deposit_skipsPositionWithNoLiquidity() public {
    // Drain all liquidity from market1 by borrowing elsewhere
    // First create another borrow position that will borrow all liquidity
    address drainer = makeAddr("drainer");
    collateralToken.setBalance(drainer, 200_000e18);

    vm.prank(drainer);
    collateralToken.approve(address(morpho), 200_000e18);

    // Supply collateral and borrow all liquidity from market1
    vm.startPrank(drainer);
    morpho.supplyCollateral(marketParams1, 200_000e18, drainer, "");
    morpho.borrow(marketParams1, 100_000e18, 0, drainer, drainer); // Borrow all liquidity
    vm.stopPrank();

    // Now market1 has no liquidity, but market2 still has liquidity
    assertEq(morpho.market(marketId1).totalSupplyAssets - morpho.market(marketId1).totalBorrowAssets, 0);

    // Minter deposits - should skip position1 (no liquidity) and use position2
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Should succeed using position2
    assertGt(shares, 0, "Should mint shares");

    // All debt should be from position2 since position1 had no liquidity
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should have no debt");
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT, "Position2 should have all debt");
  }

  /// @notice Test deposit with maxBorrow == 0 skips position
  function test_deposit_skipsPositionWithZeroMaxBorrow() public {
    // Set position1's maxBorrow to 0
    SupplyQueueEntry[] memory newQueue = new SupplyQueueEntry[](2);
    newQueue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: 0});
    newQueue[1] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});

    vm.prank(curator);
    positionManager.setSupplyQueue(newQueue);

    // Deposit should skip position1 (maxBorrow == 0) and use position2
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    assertGt(shares, 0, "Should mint shares");
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should have no debt");
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT, "Position2 should have all debt");
  }

  function test_deposit_emptySupplyQueue_revertOnCollateral() public {
    // Clear supply queue
    SupplyQueueEntry[] memory emptyQueue = new SupplyQueueEntry[](0);
    vm.prank(curator);
    positionManager.setSupplyQueue(emptyQueue);

    _mintCollateral(minter, COLLATERAL_AMOUNT);

    // Deposit with collateral should revert when supply queue is empty
    vm.prank(minter);
    vm.expectRevert(LibManagerErrors.EmptySupplyQueue.selector);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);
  }

  function test_deposit_emptySupplyQueue_withDebt_reverts() public {
    // Clear supply queue
    SupplyQueueEntry[] memory emptyQueue = new SupplyQueueEntry[](0);
    vm.prank(curator);
    positionManager.setSupplyQueue(emptyQueue);

    _mintCollateral(minter, COLLATERAL_AMOUNT);

    // Deposit with debt should revert due to insufficient borrow capacity
    vm.prank(minter);
    vm.expectRevert(LibManagerErrors.InsufficientBorrowCapacity.selector);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       FUZZ TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_deposit(uint256 collateral, uint256 debt) public {
    // Bound collateral to reasonable range
    collateral = bound(collateral, 1e18, 50_000e18);
    // Debt must be less than 65% of collateral to pass safe LTV checks (65%)
    // Using 64% with margin. Also cap at available liquidity
    uint256 maxDebt = (collateral * 64) / 100;
    if (maxDebt > 100_000e18) maxDebt = 100_000e18; // First pool has 100k liquidity
    debt = bound(debt, 0, maxDebt);

    _mintCollateral(minter, collateral);

    vm.prank(minter);
    int256 shares = positionManager.deposit(collateral, debt);

    assertGt(shares, 0, "Should mint positive shares");
    assertEq(positionManager.collateralAmount(), collateral);
    assertEq(positionManager.debtAmount(), debt);
  }

  function testFuzz_depositAndBurn(uint256 collateral, uint256 burnRatio) public {
    collateral = bound(collateral, 1e18, 1_000_000e18);
    burnRatio = bound(burnRatio, 1, 100); // 1-100%

    _mintCollateral(minter, collateral);
    vm.prank(minter);
    positionManager.deposit(collateral, 0);

    uint256 totalShares = positionManager.balanceOf(minter);
    uint256 sharesToBurn = totalShares * burnRatio / 100;

    if (sharesToBurn > 0) {
      vm.prank(minter);
      (uint256 collateralReceived,) = positionManager.burn(sharesToBurn, WithdrawalStrategy.PROPORTIONAL);

      assertApproxEqRel(
        collateralReceived, collateral * burnRatio / 100, 0.01e18, "Collateral received should be proportional"
      );
    }
  }
}
