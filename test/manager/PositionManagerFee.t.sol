// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";

/// @title PositionManagerFeeTest
/// @notice Tests for PositionManager fee functionality
contract PositionManagerFeeTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     FEE ACCRUAL TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setFeeData() public {
    uint24 managementFee = 200; // 2% per year
    uint24 performanceFee = 2000; // 20%

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);

    (address recipient, uint24 mgmtFee, uint24 perfFee,,) = positionManager.feeData();
    assertEq(recipient, feeRecipient);
    assertEq(mgmtFee, managementFee);
    assertEq(perfFee, performanceFee);
  }

  function test_managementFeeAccrual() public {
    // Setup fees
    uint24 managementFee = 200; // 2% per year
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, 0);

    // Deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 totalSupplyBefore = positionManager.totalSupply();

    // Advance time by 1 year
    vm.warp(block.timestamp + 365 days);

    // Trigger fee accrual with another deposit
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 feeRecipientShares = positionManager.balanceOf(feeRecipient);
    assertGt(feeRecipientShares, 0, "Fee recipient should have shares");

    // Fee should be approximately 2% of total supply
    uint256 expectedFeeShares = totalSupplyBefore * 200 / 10000;
    assertApproxEqRel(feeRecipientShares, expectedFeeShares, 0.1e18, "Fee should be ~2%");
  }

  function test_performanceFeeAccrual() public {
    // Setup fees
    uint24 performanceFee = 2000; // 20%
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, performanceFee);

    // Deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Simulate gains by increasing oracle price (collateral worth more)
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // 20% price increase

    // Trigger fee accrual
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 feeRecipientShares = positionManager.balanceOf(feeRecipient);
    assertGt(feeRecipientShares, 0, "Fee recipient should have shares from performance fee");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FEE VALIDATION TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setFeeData_revertOnExcessiveManagementFee() public {
    uint24 excessiveManagementFee = 5001; // > 50%
    uint24 validPerformanceFee = 2000;

    vm.prank(owner);
    vm.expectRevert(IPositionManager.FeeExceedsMax.selector);
    positionManager.setFeeData(feeRecipient, excessiveManagementFee, validPerformanceFee);
  }

  function test_setFeeData_revertOnExcessivePerformanceFee() public {
    uint24 validManagementFee = 200;
    uint24 excessivePerformanceFee = 5001; // > 50%

    vm.prank(owner);
    vm.expectRevert(IPositionManager.FeeExceedsMax.selector);
    positionManager.setFeeData(feeRecipient, validManagementFee, excessivePerformanceFee);
  }

  function test_setFeeData_maxFeesAllowed() public {
    uint24 maxManagementFee = 5000; // Exactly 50%
    uint24 maxPerformanceFee = 5000; // Exactly 50%

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, maxManagementFee, maxPerformanceFee);

    (address recipient, uint24 mgmtFee, uint24 perfFee,,) = positionManager.feeData();
    assertEq(recipient, feeRecipient);
    assertEq(mgmtFee, maxManagementFee);
    assertEq(perfFee, maxPerformanceFee);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 ZERO SUPPLY FEE ACCRUAL TESTS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_feeAccrual_zeroSupply() public {
    // Setup fees before any deposits
    uint24 managementFee = 200; // 2% per year
    uint24 performanceFee = 2000; // 20%
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);

    // Advance time
    vm.warp(block.timestamp + 365 days);

    // First deposit should not cause issues with fee calculation
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, 0);

    assertGt(shares, 0, "Should mint shares on first deposit");
    // Fee recipient should have 0 shares since there was no supply before
    assertEq(positionManager.balanceOf(feeRecipient), 0, "No fees should accrue with zero supply");
  }

  function test_feeAccrual_zeroTotalAssets() public {
    // This edge case shouldn't happen in practice but test the behavior
    // Setup fees
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    // Deposit and borrow to create position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Advance time
    vm.warp(block.timestamp + 365 days);

    // Crash price to make totalAssets = 0 (underwater)
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 10 / 100); // 10% of original

    // Deposit should still work
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    // Should not revert, fees should be 0 since totalAssets is 0
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              PERFORMANCE FEE SNAPSHOT BUG TEST              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Test that calling setFeeData multiple times does NOT mint infinite performance fees
  /// @dev This test catches the bug where lastTotalAssets is not updated after accruing fees
  ///      when there IS a fee recipient set
  function test_setFeeData_cannotMintInfinitePerformanceFees() public {
    // Step 1: Set performance fee FIRST (so feeRecipient is not address(0))
    uint24 performanceFee = 2000; // 20%
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, performanceFee);

    // Step 2: Deposit some collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Verify snapshot was updated by deposit
    uint256 snapshotAfterDeposit = _lastTotalAssets();
    assertEq(snapshotAfterDeposit, COLLATERAL_AMOUNT, "Snapshot should equal deposit amount");

    // Step 3: Simulate gains by increasing oracle price (20% gain)
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);

    // Total assets should now be higher
    uint256 totalAssetsAfterGain = positionManager.totalAssets();
    assertEq(totalAssetsAfterGain, COLLATERAL_AMOUNT * 120 / 100, "Total assets should reflect gain");

    // Step 4: Call setFeeData - this triggers _accrueFees which should mint performance fees
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, performanceFee);

    uint256 feeSharesAfterFirstSet = positionManager.balanceOf(feeRecipient);
    assertGt(feeSharesAfterFirstSet, 0, "Fee shares should be minted for the gain");

    // Step 5: Call setFeeData again - NO new gains occurred, so NO new fees should be minted
    // If the bug exists (lastTotalAssets not updated), this would mint fees again!
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, performanceFee);

    uint256 feeSharesAfterSecondSet = positionManager.balanceOf(feeRecipient);

    // The fee shares should NOT increase - we already took fees on these gains
    assertEq(
      feeSharesAfterSecondSet, feeSharesAfterFirstSet, "Performance fees should NOT be minted again for the same gains"
    );

    // Step 6: Call setFeeData a third time to be absolutely sure
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, performanceFee);

    uint256 feeSharesAfterThirdSet = positionManager.balanceOf(feeRecipient);

    assertEq(
      feeSharesAfterThirdSet,
      feeSharesAfterFirstSet,
      "Performance fees should still not increase after third setFeeData call"
    );
  }
}
