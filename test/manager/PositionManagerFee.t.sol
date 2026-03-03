// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {LibManagerErrors} from "../../src/libs/manager/LibManagerErrors.sol";

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
    uint24 excessiveManagementFee = 201; // > 2%
    uint24 validPerformanceFee = 2000;

    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.FeeExceedsMax.selector);
    positionManager.setFeeData(feeRecipient, excessiveManagementFee, validPerformanceFee);
  }

  function test_setFeeData_revertOnExcessivePerformanceFee() public {
    uint24 validManagementFee = 200;
    uint24 excessivePerformanceFee = 5001; // > 50%

    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.FeeExceedsMax.selector);
    positionManager.setFeeData(feeRecipient, validManagementFee, excessivePerformanceFee);
  }

  function test_setFeeData_maxFeesAllowed() public {
    uint24 maxManagementFee = 200; // Exactly 2%
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
  /*         PERFORMANCE FEE NET OF MANAGEMENT FEE TESTS         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_performanceFee_chargedNetOfManagementFee() public {
    // Setup: both fees enabled
    uint24 managementFee = 200; // 2% per year
    uint24 performanceFee = 2000; // 20%
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);

    // Deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 totalSupplyAfterDeposit = positionManager.totalSupply();

    // Simulate 20% gain and 1 year passage
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    vm.warp(block.timestamp + 365 days);

    // Calculate expected fees manually:
    // currentTotalAssets = 10_000e18 * 1.2 = 12_000e18
    // gross gain = 12_000e18 - 10_000e18 = 2_000e18
    // managementFeeAssets = 12_000e18 * 200 / 10_000 = 240e18 (2% of currentTotalAssets)
    // net gain = 2_000e18 - 240e18 = 1_760e18
    // performanceFeeAssets = 1_760e18 * 2000 / 10_000 = 352e18 (20% of net gain)

    // Trigger fee accrual
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 feeShares = positionManager.balanceOf(feeRecipient);
    assertGt(feeShares, 0, "Fee recipient should have shares");

    // Compare with performance-fee-only scenario to verify the deduction
    // If perf fee were on gross gain: perfFeeAssets = 2_000e18 * 20% = 400e18
    // With net deduction: perfFeeAssets = 1_760e18 * 20% = 352e18
    // Total fee assets: 240 + 352 = 592e18 (net) vs 240 + 400 = 640e18 (gross)
    // Fee shares should correspond to 592/12_000 ~= 4.93% of supply (net)
    // vs 640/12_000 ~= 5.33% of supply (gross)
    uint256 grossFeeSharesPct = 640e18 * 1e18 / COLLATERAL_AMOUNT; // ~5.33%
    uint256 feeSharesPct = feeShares * 1e18 / totalSupplyAfterDeposit;
    assertLt(feeSharesPct, grossFeeSharesPct, "Fee should be less than gross-based fee");
  }

  function test_performanceFee_zeroWhenManagementFeeExceedsGain() public {
    // Scenario: 1% gain but 2% management fee over 1 year exceeds it
    // Expected: performance fee should NOT be charged (net gain is negative)

    // --- Snapshot initial state ---
    uint256 snap = vm.snapshotState();

    // --- Scenario A: management fee only (control baseline) ---
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 101 / 100); // 1% gain
    vm.warp(block.timestamp + 365 days);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 mgmtOnlyShares = positionManager.balanceOf(feeRecipient);
    assertGt(mgmtOnlyShares, 0, "Management fee should produce shares");

    // --- Revert and run Scenario B: management + performance fee ---
    vm.revertToState(snap);

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 101 / 100); // same 1% gain
    vm.warp(block.timestamp + 365 days);

    // currentTotalAssets = 10_100e18
    // gross gain = 100e18
    // managementFeeAssets = 10_100e18 * 200 / 10_000 = 202e18
    // net gain = 100 - 202 = negative → no performance fee

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 bothShares = positionManager.balanceOf(feeRecipient);

    // Both scenarios should produce identical shares: no performance fee was charged
    // because management fee assets (202e18) > gross gain (100e18)
    assertEq(bothShares, mgmtOnlyShares, "No incremental performance fee should be charged when mgmt fee exceeds gains");
  }

  function test_performanceFee_lessWithManagementFee() public {
    // Compare performance fee shares across three fee configurations
    // to prove management fees reduce the performance fee via net-gain deduction.

    // --- Snapshot initial state ---
    uint256 snap = vm.snapshotState();

    // --- Scenario A: performance fee only (gross gain baseline) ---
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // 20% gain
    vm.warp(block.timestamp + 365 days);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 perfOnlyShares = positionManager.balanceOf(feeRecipient);
    assertGt(perfOnlyShares, 0, "Perf-only: fee recipient should have shares");

    // --- Revert and run Scenario B: management + performance fee ---
    vm.revertToState(snap);
    snap = vm.snapshotState();

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // same 20% gain
    vm.warp(block.timestamp + 365 days);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 bothShares = positionManager.balanceOf(feeRecipient);

    // --- Revert and run Scenario C: management fee only ---
    vm.revertToState(snap);

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // same 20% gain
    vm.warp(block.timestamp + 365 days);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 mgmtOnlyShares = positionManager.balanceOf(feeRecipient);

    // --- Assertions ---
    // With both fees, total shares > management-only shares (perf fee was charged)
    assertGt(bothShares, mgmtOnlyShares, "Both fees should produce more shares than mgmt-only");

    // Isolate performance fee contribution:
    // perfOnlyShares = perf fee on gross gain (no mgmt fee deduction)
    // bothShares - mgmtOnlyShares ≈ perf fee on net gain (after mgmt fee deduction)
    uint256 perfSharesWithMgmt = bothShares - mgmtOnlyShares;
    assertGt(
      perfOnlyShares, perfSharesWithMgmt, "Performance fee on gross gain should exceed performance fee on net gain"
    );
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    PENDING FEES VIEW TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pendingFees_ZeroWhenNoFeeRecipient() public {
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertGt(totalAssets_, 0, "totalAssets should be non-zero");
    assertGt(totalSupply_, 0, "totalSupply should be non-zero");
    assertEq(mgmtShares, 0, "no mgmt fee shares without recipient");
    assertEq(perfShares, 0, "no perf fee shares without recipient");
  }

  function test_pendingFees_ZeroWhenNoSupply() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertEq(totalAssets_, 0, "totalAssets should be zero");
    assertEq(totalSupply_, 0, "totalSupply should be zero");
    assertEq(mgmtShares, 0, "no mgmt fee shares with zero supply");
    assertEq(perfShares, 0, "no perf fee shares with zero supply");
  }

  function test_pendingFees_ManagementFeeOnly() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0); // 2% per year

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertEq(totalAssets_, COLLATERAL_AMOUNT, "totalAssets");
    assertGt(totalSupply_, 0, "totalSupply");
    assertGt(mgmtShares, 0, "should have management fee shares");
    assertEq(perfShares, 0, "no performance fee shares");
  }

  function test_pendingFees_PerformanceFeeOnly() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000); // 20% perf fee

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // 20% price increase
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertEq(totalAssets_, COLLATERAL_AMOUNT * 120 / 100, "totalAssets reflects gain");
    assertGt(totalSupply_, 0, "totalSupply");
    assertEq(mgmtShares, 0, "no management fee shares");
    assertGt(perfShares, 0, "should have performance fee shares");
  }

  function test_pendingFees_BothFees() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // 20% gain
    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertGt(totalAssets_, 0, "totalAssets");
    assertGt(totalSupply_, 0, "totalSupply");
    assertGt(mgmtShares, 0, "should have management fee shares");
    assertGt(perfShares, 0, "should have performance fee shares");
  }

  function test_pendingFees_MatchesActualAccrual() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    vm.warp(block.timestamp + 365 days);

    // Read pending fees before accrual
    (, uint256 totalSupplyBefore, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    uint256 pendingTotal = mgmtShares + perfShares;

    // Trigger accrual with a minimal deposit
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 actualFeeShares = positionManager.balanceOf(feeRecipient);

    // The pending fee prediction should exactly match the actual minted fee shares
    assertEq(pendingTotal, actualFeeShares, "pendingFees must match actual accrued fee shares");

    // totalSupply before accrual should match what was returned
    // (deposit mints shares for minter + fee shares, so totalSupply increased by both)
    uint256 totalSupplyAfter = positionManager.totalSupply();
    // totalSupplyAfter = totalSupplyBefore + feeShares + newDepositShares
    assertGt(totalSupplyAfter, totalSupplyBefore + actualFeeShares, "supply grew by fees + deposit shares");
  }

  function test_pendingFees_ZeroAfterAccrual() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    vm.warp(block.timestamp + 365 days);

    // Trigger accrual
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    // Immediately after accrual, pending fees should be zero (no time elapsed, no new gains)
    (,, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertEq(mgmtShares, 0, "no pending mgmt fees after accrual");
    assertEq(perfShares, 0, "no pending perf fees after accrual");
  }

  function test_pendingFees_NoPerformanceFeeWhenMgmtExceedsGain() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // 1% gain but 2% management fee over 1 year => net gain negative => no perf fee
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 101 / 100);
    vm.warp(block.timestamp + 365 days);

    (,, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertGt(mgmtShares, 0, "should have management fee shares");
    assertEq(perfShares, 0, "no performance fee when mgmt fee exceeds gain");
  }
}
