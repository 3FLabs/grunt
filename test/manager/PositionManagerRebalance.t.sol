// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {
  IPositionManager,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType,
  SupplyQueueEntry
} from "src/interfaces/manager/IPositionManager.sol";
import {IPositionManagerAdmin} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {LibManagerErrors} from "../../src/libs/manager/LibManagerErrors.sol";

/// @title PositionManagerRebalanceTest
/// @notice Tests for PositionManager rebalance functionality
contract PositionManagerRebalanceTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REBALANCE TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_moveLiquidity() public {
    // Setup: deposit collateral and borrow in position 1
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Check initial state
    assertEq(borrowPosition1.totalCollateral(), COLLATERAL_AMOUNT);
    assertEq(borrowPosition1.totalBorrowed(), DEBT_AMOUNT);
    assertEq(borrowPosition2.totalCollateral(), 0);
    assertEq(borrowPosition2.totalBorrowed(), 0);

    // Rebalance: move half to position 2
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

    RebalancingData memory data = RebalancingData({
      collateral: 0,
      debt: debtToMove, // Need to provide debt for repayment
      operations: ops
    });

    // Mint debt for rebalancer to repay
    _mintDebt(rebalancer, debtToMove);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), debtToMove);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    // Check balances moved
    assertApproxEqRel(borrowPosition1.totalCollateral(), collateralToMove, 0.01e18);
    assertApproxEqRel(borrowPosition2.totalCollateral(), collateralToMove, 0.01e18);
  }

  function test_rebalance_accruesFeesAndUpdatesSnapshot() public {
    // Setup fees
    uint24 managementFee = 200; // 2% per year
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, 0);

    // Deposit to create position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 initialSnapshot = _lastTotalAssets();
    uint256 initialTimestamp = _lastFeeAccrualTimestamp();

    // Advance time
    vm.warp(block.timestamp + 365 days);

    // Rebalance (just supply more collateral)
    uint256 additionalCollateral = 1000e18;
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.SUPPLY, amount: additionalCollateral
    });

    RebalancingData memory data = RebalancingData({collateral: additionalCollateral, debt: 0, operations: ops});

    _mintCollateral(rebalancer, additionalCollateral);
    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), additionalCollateral);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    // Verify fee recipient received management fees (accrued before rebalance)
    assertGt(positionManager.balanceOf(feeRecipient), 0, "Fee recipient should have received fees");

    // Verify timestamp was updated
    assertGt(_lastFeeAccrualTimestamp(), initialTimestamp, "Timestamp should be updated");

    // Verify snapshot was updated to post-rebalance value
    assertGt(_lastTotalAssets(), initialSnapshot, "Snapshot should reflect post-rebalance state");
    assertEq(_lastTotalAssets(), COLLATERAL_AMOUNT + additionalCollateral, "Snapshot should equal new total assets");
  }

  function test_rebalance_returnsExcessCorrectly() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Rebalance with more collateral than needed
    uint256 excessCollateral = 1000e18;
    uint256 excessDebt = 500e18;

    // Only supply half of what we provide
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.SUPPLY, amount: excessCollateral / 2
    });

    RebalancingData memory data = RebalancingData({collateral: excessCollateral, debt: excessDebt, operations: ops});

    _mintCollateral(rebalancer, excessCollateral);
    _mintDebt(rebalancer, excessDebt);

    uint256 rebalancerCollateralBefore = collateralToken.balanceOf(rebalancer);
    uint256 rebalancerDebtBefore = debtToken.balanceOf(rebalancer);

    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), excessCollateral);
    debtToken.approve(address(positionManager), excessDebt);
    (uint256 collateralExcess, uint256 debtExcess) = positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    // Should return the unused amounts
    assertEq(collateralExcess, excessCollateral / 2, "Should return unused collateral");
    assertEq(debtExcess, excessDebt, "Should return all unused debt");

    // Verify rebalancer received the excess back
    assertEq(
      collateralToken.balanceOf(rebalancer),
      rebalancerCollateralBefore - excessCollateral + collateralExcess,
      "Rebalancer should receive collateral excess"
    );
    assertEq(
      debtToken.balanceOf(rebalancer),
      rebalancerDebtBefore - excessDebt + debtExcess,
      "Rebalancer should receive debt excess"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                MAX REBALANCE LOSS TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setMaxRebalanceLoss() public {
    uint16 maxLoss = 100; // 1%

    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(maxLoss);

    assertEq(_maxRebalanceLoss(), maxLoss, "Max rebalance loss should be set");
  }

  function test_setMaxRebalanceLoss_emitsEvent() public {
    uint16 maxLoss = 100; // 1%

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit IPositionManagerAdmin.MaxRebalanceLossSet(maxLoss);
    positionManager.setMaxRebalanceLoss(maxLoss);
  }

  function test_setMaxRebalanceLoss_onlyOwner() public {
    vm.prank(minter);
    vm.expectRevert();
    positionManager.setMaxRebalanceLoss(100);
  }

  function test_rebalance_revertOnExcessiveLoss() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Set max rebalance loss to 1% (100 BPS)
    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(100);

    // Try to withdraw 5% of collateral (causing 5% loss in totalAssets)
    uint256 collateralToWithdraw = COLLATERAL_AMOUNT * 5 / 100;

    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToWithdraw
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    vm.prank(rebalancer);
    vm.expectRevert(LibManagerErrors.RebalanceLossExceedsMax.selector);
    positionManager.rebalance(data, rebalancer);
  }

  function test_rebalance_allowsLossWithinThreshold() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Set max rebalance loss to 5% (500 BPS)
    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(500);

    // Withdraw 4% of collateral (within 5% threshold)
    uint256 collateralToWithdraw = COLLATERAL_AMOUNT * 4 / 100;

    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToWithdraw
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // Should not revert
    vm.prank(rebalancer);
    positionManager.rebalance(data, rebalancer);

    // Verify collateral was withdrawn
    assertEq(
      borrowPosition1.totalCollateral(), COLLATERAL_AMOUNT - collateralToWithdraw, "Collateral should be withdrawn"
    );
  }

  function test_rebalance_allowsExactThresholdLoss() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Set max rebalance loss to exactly 5% (500 BPS)
    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(500);

    // Withdraw exactly 5% of collateral (at the exact threshold)
    uint256 collateralToWithdraw = COLLATERAL_AMOUNT * 5 / 100;

    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToWithdraw
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // Should not revert (exactly at threshold)
    vm.prank(rebalancer);
    positionManager.rebalance(data, rebalancer);
  }

  function test_rebalance_alwaysAllowsAssetIncrease() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Set max rebalance loss to 0 (no loss allowed)
    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(0);

    // Supply more collateral (increases totalAssets)
    uint256 additionalCollateral = 1000e18;

    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.SUPPLY, amount: additionalCollateral
    });

    RebalancingData memory data = RebalancingData({collateral: additionalCollateral, debt: 0, operations: ops});

    _mintCollateral(rebalancer, additionalCollateral);
    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), additionalCollateral);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    // Should not revert because totalAssets increased
    assertEq(
      borrowPosition1.totalCollateral(), COLLATERAL_AMOUNT + additionalCollateral, "Collateral should be increased"
    );
  }

  function test_rebalance_revertWithZeroMaxLossOnAnyLoss() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Set max rebalance loss to 0 (no loss allowed)
    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(0);

    // Try to withdraw even 1 wei (should revert)
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: 1
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    vm.prank(rebalancer);
    vm.expectRevert(LibManagerErrors.RebalanceLossExceedsMax.selector);
    positionManager.rebalance(data, rebalancer);
  }

  function test_maxRebalanceLoss_defaultIsZero() public view {
    assertEq(_maxRebalanceLoss(), 0, "Default max rebalance loss should be 0");
  }

  function testFuzz_rebalance_lossThresholdEnforced(uint16 maxLossPercent, uint8 actualLossPercent) public {
    // Bound inputs
    maxLossPercent = uint16(bound(maxLossPercent, 0, 10000)); // 0-100%
    actualLossPercent = uint8(bound(actualLossPercent, 1, 99)); // 1-99%

    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Set max rebalance loss
    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(maxLossPercent);

    // Calculate collateral to withdraw based on actual loss percent
    uint256 collateralToWithdraw = COLLATERAL_AMOUNT * actualLossPercent / 100;

    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToWithdraw
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // Convert actualLossPercent to BPS for comparison
    uint16 actualLossBps = uint16(uint256(actualLossPercent) * 100);

    vm.prank(rebalancer);
    if (actualLossBps > maxLossPercent) {
      vm.expectRevert(LibManagerErrors.RebalanceLossExceedsMax.selector);
    }
    positionManager.rebalance(data, rebalancer);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              UNAUTHORIZED POSITION TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_revertUnauthorizedPosition_supply() public {
    // Create a fake position address that is NOT in borrowModules
    address fakePosition = makeAddr("fakePosition");

    // Try to supply to the fake position
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] =
      RebalancingOperation({position: fakePosition, operationType: RebalancingOperationType.SUPPLY, amount: 1000e18});

    RebalancingData memory data = RebalancingData({collateral: 1000e18, debt: 0, operations: ops});

    _mintCollateral(rebalancer, 1000e18);
    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), 1000e18);

    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();
  }

  function test_rebalance_revertUnauthorizedPosition_borrow() public {
    // Create a fake position address that is NOT in borrowModules
    address fakePosition = makeAddr("fakePosition");

    // Try to borrow from the fake position
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] =
      RebalancingOperation({position: fakePosition, operationType: RebalancingOperationType.BORROW, amount: 1000e18});

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    vm.prank(rebalancer);
    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.rebalance(data, rebalancer);
  }

  function test_rebalance_revertUnauthorizedPosition_withdraw() public {
    // Create a fake position address that is NOT in borrowModules
    address fakePosition = makeAddr("fakePosition");

    // Try to withdraw from the fake position
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] =
      RebalancingOperation({position: fakePosition, operationType: RebalancingOperationType.WITHDRAW, amount: 1000e18});

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    vm.prank(rebalancer);
    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.rebalance(data, rebalancer);
  }

  function test_rebalance_revertUnauthorizedPosition_repay() public {
    // Create a fake position address that is NOT in borrowModules
    address fakePosition = makeAddr("fakePosition");

    // Try to repay to the fake position
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] =
      RebalancingOperation({position: fakePosition, operationType: RebalancingOperationType.REPAY, amount: 1000e18});

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 1000e18, operations: ops});

    _mintDebt(rebalancer, 1000e18);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), 1000e18);

    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();
  }

  function test_rebalance_revertUnauthorizedPosition_removedModule() public {
    // Setup: deposit collateral to position 1
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Remove position 2 from queues first (required before removing module)
    // Queue operations require CURATOR_ROLE
    SupplyQueueEntry[] memory newSupplyQueue = new SupplyQueueEntry[](1);
    newSupplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: type(uint96).max});

    address[] memory newWithdrawalQueue = new address[](1);
    newWithdrawalQueue[0] = address(borrowPosition1);

    vm.startPrank(curator);
    positionManager.setSupplyQueue(newSupplyQueue);
    positionManager.setWithdrawalQueue(newWithdrawalQueue);
    vm.stopPrank();

    // Now remove position 2 from borrow modules (requires owner)
    vm.prank(owner);
    positionManager.removeBorrowModule(address(borrowPosition2));

    // Try to supply to the removed position
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: 1000e18
    });

    RebalancingData memory data = RebalancingData({collateral: 1000e18, debt: 0, operations: ops});

    _mintCollateral(rebalancer, 1000e18);
    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), 1000e18);

    // Should revert because position 2 is no longer a borrow module
    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();
  }

  function test_rebalance_succeedsWithAuthorizedPosition() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Rebalance with authorized position (borrowPosition1 is in borrowModules)
    uint256 additionalCollateral = 1000e18;

    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.SUPPLY, amount: additionalCollateral
    });

    RebalancingData memory data = RebalancingData({collateral: additionalCollateral, debt: 0, operations: ops});

    _mintCollateral(rebalancer, additionalCollateral);
    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), additionalCollateral);

    // Should succeed because borrowPosition1 is an authorized borrow module
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    // Verify the supply went through
    assertEq(borrowPosition1.totalCollateral(), COLLATERAL_AMOUNT + additionalCollateral);
  }

  function testFuzz_rebalance_onlyAuthorizedPositions(address randomPosition) public {
    // Ensure the random position is not one of our authorized positions
    vm.assume(randomPosition != address(borrowPosition1));
    vm.assume(randomPosition != address(borrowPosition2));
    vm.assume(randomPosition != address(0));
    vm.assume(randomPosition != address(0xfbb67fda52d4bfb8bf)); // zero sentinel (from EnumerableSetLib)

    // Try to supply to the random position
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] =
      RebalancingOperation({position: randomPosition, operationType: RebalancingOperationType.SUPPLY, amount: 1e18});

    RebalancingData memory data = RebalancingData({collateral: 1e18, debt: 0, operations: ops});

    _mintCollateral(rebalancer, 1e18);
    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), 1e18);

    // Should always revert for unauthorized positions
    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();
  }

  function test_rebalance_revertMixedAuthorizedAndUnauthorized() public {
    // Create a fake position
    address fakePosition = makeAddr("fakePosition");

    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Try to do a valid operation followed by an unauthorized one
    RebalancingOperation[] memory ops = new RebalancingOperation[](2);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: 100e18
    });
    ops[1] =
      RebalancingOperation({position: fakePosition, operationType: RebalancingOperationType.SUPPLY, amount: 100e18});

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    vm.prank(rebalancer);
    // Should revert on the second operation (unauthorized position)
    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.rebalance(data, rebalancer);
  }
}
