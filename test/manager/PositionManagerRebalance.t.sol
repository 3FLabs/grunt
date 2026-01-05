// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/IPositionManager.sol";

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
    positionManager.rebalance(data);
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

    uint256 initialSnapshot = positionManager.lastTotalAssets();
    uint256 initialTimestamp = positionManager.lastFeeAccrualTimestamp();

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
    positionManager.rebalance(data);
    vm.stopPrank();

    // Verify fee recipient received management fees (accrued before rebalance)
    assertGt(positionManager.balanceOf(feeRecipient), 0, "Fee recipient should have received fees");

    // Verify timestamp was updated
    assertGt(positionManager.lastFeeAccrualTimestamp(), initialTimestamp, "Timestamp should be updated");

    // Verify snapshot was updated to post-rebalance value
    assertGt(positionManager.lastTotalAssets(), initialSnapshot, "Snapshot should reflect post-rebalance state");
    assertEq(
      positionManager.lastTotalAssets(),
      COLLATERAL_AMOUNT + additionalCollateral,
      "Snapshot should equal new total assets"
    );
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
    (uint256 collateralExcess, uint256 debtExcess) = positionManager.rebalance(data);
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
}
