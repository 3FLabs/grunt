// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {
  IPositionManager,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/IPositionManager.sol";

/// @title PositionManagerLiquidationTest
/// @notice Tests for PositionManager liquidation scenarios
contract PositionManagerLiquidationTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    LIQUIDATION TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_liquidation_singlePosition_partialLiquidation() public {
    // Setup: deposit collateral and borrow at high utilization
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 debtBefore = positionManager.debtAmount();
    uint256 totalAssetsBefore = positionManager.totalAssets();
    uint256 sharesBefore = positionManager.balanceOf(minter);

    // Crash oracle price to make position liquidatable
    // LLTV is 80%, so at 60% of original price, the position becomes liquidatable
    // debt = 5000, collateral = 10000 * 0.6 = 6000 quoted
    // maxBorrow = 6000 * 0.8 = 4800 < 5000 debt -> liquidatable
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    // Setup liquidator
    address liquidator = makeAddr("liquidator");
    uint256 seizedCollateral = 1000e18; // Seize 1000 collateral tokens

    // Give liquidator debt tokens to repay
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    // Execute liquidation on Morpho
    vm.prank(liquidator);
    (uint256 seizedAssets, uint256 repaidAssets) =
      morpho.liquidate(marketParams1, address(borrowPosition1), seizedCollateral, 0, "");

    // Verify position state after liquidation
    uint256 collateralAfter = positionManager.collateralAmount();
    uint256 debtAfter = positionManager.debtAmount();
    uint256 totalAssetsAfter = positionManager.totalAssets();

    // Collateral should have decreased by seized amount
    assertEq(collateralAfter, collateralBefore - seizedAssets, "Collateral should decrease by seized amount");

    // Debt should have decreased by repaid amount
    assertEq(debtAfter, debtBefore - repaidAssets, "Debt should decrease by repaid amount");

    // Total assets should have decreased (liquidation has a cost due to incentive)
    assertLt(totalAssetsAfter, totalAssetsBefore, "Total assets should decrease after liquidation");

    // Shares should remain the same (no burning occurred)
    assertEq(positionManager.balanceOf(minter), sharesBefore, "Shares should not change from liquidation");

    // Share value should have decreased
    uint256 shareValueBefore = totalAssetsBefore * WAD / sharesBefore;
    uint256 shareValueAfter = totalAssetsAfter * WAD / sharesBefore;
    assertLt(shareValueAfter, shareValueBefore, "Share value should decrease after liquidation");
  }

  function test_liquidation_singlePosition_fullLiquidation() public {
    // Setup: deposit collateral and borrow at high utilization (close to LLTV)
    uint256 highDebt = (COLLATERAL_AMOUNT * 70) / 100; // 70% LTV
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, highDebt);

    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 debtBefore = positionManager.debtAmount();

    // Crash oracle price significantly to allow full liquidation
    // At 50% price: collateral = 5000 quoted, maxBorrow = 4000, debt = 7000 -> very underwater
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 50 / 100);

    // Setup liquidator
    address liquidator = makeAddr("liquidator");

    // Give liquidator enough debt tokens
    debtToken.setBalance(liquidator, debtBefore * 2);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), debtBefore * 2);

    // Execute full liquidation - seize all collateral
    vm.prank(liquidator);
    morpho.liquidate(marketParams1, address(borrowPosition1), collateralBefore, 0, "");

    // Verify position state after full liquidation
    uint256 collateralAfter = positionManager.collateralAmount();
    uint256 debtAfter = positionManager.debtAmount();

    // All collateral should be seized
    assertEq(collateralAfter, 0, "All collateral should be seized");

    // Some debt may remain if collateral wasn't enough to cover all debt + incentive
    // This is a bad debt scenario
    if (debtAfter > 0) {
      // Position is now underwater with no collateral - this is bad debt
      assertEq(positionManager.totalAssets(), 0, "Total assets should be 0 when underwater");
    }

    // Shares still exist but are now worthless or near-worthless
    assertGt(positionManager.balanceOf(minter), 0, "Shares still exist");
  }

  function test_liquidation_multiPosition_oneLiquidated() public {
    // Setup: deposit to first position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Move half to second position via rebalance
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
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    // Verify both positions have roughly equal amounts
    uint256 pos1Collateral = borrowPosition1.totalCollateral();
    uint256 pos2Collateral = borrowPosition2.totalCollateral();
    uint256 totalCollateralBefore = positionManager.collateralAmount();
    uint256 totalAssetsBefore = positionManager.totalAssets();

    // Crash oracle to make positions liquidatable
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    // Liquidate only position 1
    address liquidator = makeAddr("liquidator");
    uint256 seizeAmount = pos1Collateral / 2; // Partial liquidation of position 1

    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    vm.prank(liquidator);
    (uint256 seizedAssets,) = morpho.liquidate(marketParams1, address(borrowPosition1), seizeAmount, 0, "");

    // Position 2 should be unaffected
    assertEq(borrowPosition2.totalCollateral(), pos2Collateral, "Position 2 collateral unchanged");

    // Total collateral should decrease by seized amount
    assertEq(
      positionManager.collateralAmount(),
      totalCollateralBefore - seizedAssets,
      "Total collateral decreased by seized amount"
    );

    // Total assets should have decreased
    assertLt(positionManager.totalAssets(), totalAssetsBefore, "Total assets decreased");
  }

  function test_liquidation_burnAfterPartialLiquidation() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 sharesBefore = positionManager.balanceOf(minter);

    // Crash oracle and execute partial liquidation
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    address liquidator = makeAddr("liquidator");
    uint256 seizeAmount = 2000e18;

    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    vm.prank(liquidator);
    morpho.liquidate(marketParams1, address(borrowPosition1), seizeAmount, 0, "");

    // Reset oracle price for burn operation
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    // Now try to burn shares - should still work but with reduced value
    uint256 sharesToBurn = sharesBefore / 2;

    // Need to provide debt tokens for repayment during burn
    _mintDebt(minter, DEBT_AMOUNT);

    uint256 collateralBefore = positionManager.collateralAmount();

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Should receive proportional amounts (but less than original due to liquidation loss)
    assertGt(collateralReceived, 0, "Should receive some collateral");
    assertGt(debtRepaid, 0, "Should repay some debt");

    // Proportions should be maintained
    assertApproxEqRel(
      collateralReceived, collateralBefore * sharesToBurn / sharesBefore, 0.01e18, "Collateral proportional to shares"
    );
  }

  function test_liquidation_depositAfterLiquidation() public {
    // Setup initial position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 sharesBefore = positionManager.balanceOf(minter);

    // Crash and liquidate
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    vm.prank(liquidator);
    morpho.liquidate(marketParams1, address(borrowPosition1), 2000e18, 0, "");

    // Reset oracle
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    // New user deposits after liquidation
    address newUser = makeAddr("newUser");
    vm.prank(owner);
    positionManager.grantRoles(newUser, _ROLE_MINTER);

    uint256 newDeposit = 5000e18;
    collateralToken.setBalance(newUser, newDeposit);
    vm.startPrank(newUser);
    collateralToken.approve(address(positionManager), newDeposit);
    int256 newShares = positionManager.deposit(newDeposit, 0);
    vm.stopPrank();

    // New user should receive shares at the current (diluted) price
    assertGt(newShares, 0, "New user should receive shares");

    // The share price should reflect the post-liquidation state
    // New user should get more shares per collateral than original user would have
    // because share value decreased
    uint256 totalSupply = positionManager.totalSupply();

    // Verify the new shares are correctly valued
    assertEq(totalSupply, uint256(int256(sharesBefore) + newShares), "Total supply correct");
  }

  function test_liquidation_withdrawAfterFullLiquidation() public {
    // Setup: deposit at high LTV
    uint256 highDebt = (COLLATERAL_AMOUNT * 70) / 100;
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, highDebt);

    // Crash hard and fully liquidate
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);

    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, highDebt * 2);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), highDebt * 2);

    // Seize all collateral
    vm.prank(liquidator);
    morpho.liquidate(marketParams1, address(borrowPosition1), COLLATERAL_AMOUNT, 0, "");

    // Position should now have 0 collateral
    assertEq(positionManager.collateralAmount(), 0, "No collateral left");

    // totalAssets should be 0 (underwater)
    assertEq(positionManager.totalAssets(), 0, "No assets left");

    // Trying to withdraw should fail (no available collateral)
    vm.prank(minter);
    vm.expectRevert(IPositionManager.InsufficientAvailableCollateral.selector);
    positionManager.withdraw(1, 0);
  }
}
