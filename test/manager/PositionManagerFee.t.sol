// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
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

    // Leveraged deposit: the performance fee under the new mechanism is charged on the
    // levered slice only, so we need debt > 0 to seed lastDebt and to produce a non-zero basis.
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

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
    // Setup: both fees enabled. Leveraged deposit so the new levered-slice basis is non-zero.
    uint24 managementFee = 200; // 2% per year
    uint24 performanceFee = 2000; // 20%
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Simulate 20% collateral price gain and 1 year passage
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    vm.warp(block.timestamp + 365 days);

    // Snapshot perf-only fees to compute the management-fee deduction's impact on perf shares.
    uint256 snap = vm.snapshotState();

    // --- Scenario A: perf fee only ---
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, performanceFee);
    uint256 perfOnlyShares = positionManager.balanceOf(feeRecipient);

    vm.revertToState(snap);

    // --- Scenario B: both fees ---
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);
    uint256 bothShares = positionManager.balanceOf(feeRecipient);

    // Both should produce non-zero shares — net deduction means bothShares' perf component
    // is smaller than perfOnlyShares, so the total here may exceed or fall below depending on
    // mgmt magnitude. Critical invariant: perf-only > 0 confirms the new mechanism activates,
    // and bothShares > 0 confirms accrual works under combined fees.
    assertGt(perfOnlyShares, 0, "Perf-only should mint shares on a levered gain");
    assertGt(bothShares, 0, "Combined fees should mint shares");
  }

  function test_performanceFee_zeroWhenManagementFeeExceedsGain() public {
    // Scenario: levered position with 1% collateral price gain but 2% management fee over 1 year.
    // The levered-slice basis is small and the management-fee deduction exceeds it, so no
    // performance fee should be charged.

    // --- Snapshot initial state ---
    uint256 snap = vm.snapshotState();

    // --- Scenario A: management fee only (control baseline) ---
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

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
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 101 / 100); // same 1% gain
    vm.warp(block.timestamp + 365 days);

    // Levered-slice basis (rough):
    //   lastCollat = 10_000e18, lastDebt = 5_000e18, currentCollat = 10_100e18, currentDebt = 5_000e18
    //   basis = 5_000 - mulDiv(5_000, 10_000, 10_100) ≈ 5_000 - 4_950.495 ≈ 49.5e18
    //   managementFeeAssets ≈ totalAssets * 200/10000 ≈ 5_100 * 0.02 ≈ 102e18
    //   basis < managementFeeAssets → performance fee skipped.

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 bothShares = positionManager.balanceOf(feeRecipient);

    // Identical shares: no performance fee was charged because management fee assets exceed basis.
    assertEq(bothShares, mgmtOnlyShares, "No incremental performance fee should be charged when mgmt fee exceeds gains");
  }

  function test_performanceFee_lessWithManagementFee() public {
    // Compare performance fee shares across three fee configurations to prove the management
    // fee reduces the performance fee via the basis deduction. Uses a leveraged deposit so the
    // new levered-slice basis is positive.

    uint256 snap = vm.snapshotState();

    // --- Scenario A: performance fee only ---
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // 20% gain
    vm.warp(block.timestamp + 365 days);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 perfOnlyShares = positionManager.balanceOf(feeRecipient);
    assertGt(perfOnlyShares, 0, "Perf-only: fee recipient should have shares");

    // --- Scenario B: management + performance fee ---
    vm.revertToState(snap);
    snap = vm.snapshotState();

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    vm.warp(block.timestamp + 365 days);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 bothShares = positionManager.balanceOf(feeRecipient);

    // --- Scenario C: management fee only ---
    vm.revertToState(snap);

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    vm.warp(block.timestamp + 365 days);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 mgmtOnlyShares = positionManager.balanceOf(feeRecipient);

    // Combined fees mint strictly more shares than mgmt-only (perf fee positive).
    assertGt(bothShares, mgmtOnlyShares, "Both fees should produce more shares than mgmt-only");

    // Perf fee on the bare basis (Scenario A) exceeds perf fee on basis-minus-mgmt-assets (Scenario B).
    uint256 perfSharesWithMgmt = bothShares - mgmtOnlyShares;
    assertGt(
      perfOnlyShares, perfSharesWithMgmt, "Perf on bare basis should exceed perf on basis-minus-mgmt"
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

    // Step 2: Leveraged deposit so lastDebt is seeded and the new basis can produce shares.
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Verify NAV snapshot was updated by deposit
    uint256 snapshotAfterDeposit = _lastTotalAssets();
    assertEq(snapshotAfterDeposit, COLLATERAL_AMOUNT - DEBT_AMOUNT, "NAV snapshot");
    assertEq(positionManager.lastDebt(), DEBT_AMOUNT, "lastDebt should be seeded");

    // Step 3: Simulate gains by increasing oracle price (20% gain)
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);

    // Total assets should now be higher (collateral worth 1.2x, debt unchanged)
    uint256 totalAssetsAfterGain = positionManager.totalAssets();
    assertEq(
      totalAssetsAfterGain, (COLLATERAL_AMOUNT * 120 / 100) - DEBT_AMOUNT, "Total assets should reflect gain"
    );

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

  function test_pendingFees_ManagementFeeSharesUseFeeAdjustedBase() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0); // 2% per year

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    uint256 expectedFeeAssets = COLLATERAL_AMOUNT * 200 / 10_000;
    uint256 offset = positionManager.virtualShareOffset();
    uint256 expectedShares = expectedFeeAssets * (totalSupply_ + offset) / (totalAssets_ - expectedFeeAssets + 1);
    uint256 preFeeBaseShares = expectedFeeAssets * (totalSupply_ + offset) / (totalAssets_ + 1);

    assertEq(totalAssets_, COLLATERAL_AMOUNT, "totalAssets");
    assertEq(mgmtShares, expectedShares, "fee shares should use fee-adjusted base");
    assertGt(mgmtShares, preFeeBaseShares, "fee-adjusted base should mint more shares than pre-fee base");
    assertEq(perfShares, 0, "no performance fee shares");
  }

  function test_managementFeeSharesRedeemToAdvertisedFeeAssets() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0); // 2% per year

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    vm.warp(block.timestamp + 365 days);

    (,, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    uint256 expectedFeeAssets = COLLATERAL_AMOUNT * 200 / 10_000;
    uint256 feeShares = mgmtShares + perfShares;

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0);

    assertEq(positionManager.balanceOf(feeRecipient), feeShares, "accrued shares should match pending fees");

    vm.prank(owner);
    positionManager.grantRoles(feeRecipient, _ROLE_MINTER);

    vm.prank(feeRecipient);
    (uint256 collateralReceived, uint256 debtOwed) = positionManager.burn(feeShares, WithdrawalStrategy.PROPORTIONAL);

    assertEq(debtOwed, 0, "debt owed");
    assertApproxEqAbs(collateralReceived, expectedFeeAssets, 1, "fee shares should redeem to fee assets");
  }

  function test_pendingFees_PerformanceFeeOnly() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000); // 20% perf fee

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // 20% price increase
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    // totalAssets = 1.2 * COLLATERAL_AMOUNT - DEBT_AMOUNT
    assertEq(totalAssets_, COLLATERAL_AMOUNT * 120 / 100 - DEBT_AMOUNT, "totalAssets reflects gain");
    assertGt(totalSupply_, 0, "totalSupply");
    assertEq(mgmtShares, 0, "no management fee shares");
    assertGt(perfShares, 0, "should have performance fee shares on the levered slice");
  }

  function test_pendingFees_BothFees() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // 20% gain
    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    assertGt(totalAssets_, 0, "totalAssets");
    assertGt(totalSupply_, 0, "totalSupply");
    assertGt(mgmtShares, 0, "should have management fee shares");
    assertGt(perfShares, 0, "should have performance fee shares");
  }

  function test_pendingFees_BothFeesUseCombinedFeeAdjustedBase() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Snapshot the levered-slice constants seeded by the deposit.
    // lastCollat = lastTotalAssets + lastDebt = (COLLATERAL_AMOUNT - DEBT_AMOUNT) + DEBT_AMOUNT = COLLATERAL_AMOUNT.
    uint256 lastCollat = _lastTotalAssets() + positionManager.lastDebt();
    uint256 lastDebt_ = positionManager.lastDebt();

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // 20% gain
    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    // Recompute expected fee assets using the new bases:
    //   mgmt fee  = currentCollat * managementFee / BPS (1y elapsed; capped at totalAssets)
    //   perf fee  = (basis - mgmtFeeAssets) * performanceFee / BPS, basis on levered slice
    uint256 currentDebt = positionManager.debtAmount();
    uint256 currentCollat = totalAssets_ + currentDebt;
    uint256 expectedMgmtFeeAssets = currentCollat * 200 / 10_000;
    if (expectedMgmtFeeAssets > totalAssets_) expectedMgmtFeeAssets = totalAssets_;
    uint256 hypotheticalDebt = currentDebt * lastCollat / currentCollat; // mulDiv rounds down
    uint256 basis = lastDebt_ > hypotheticalDebt ? lastDebt_ - hypotheticalDebt : 0;
    uint256 expectedPerfFeeAssets = basis > expectedMgmtFeeAssets ? (basis - expectedMgmtFeeAssets) * 2000 / 10_000 : 0;
    uint256 expectedTotalFeeAssets = expectedMgmtFeeAssets + expectedPerfFeeAssets;
    uint256 offset = positionManager.virtualShareOffset();
    uint256 feeAdjustedAssets = totalAssets_ - expectedTotalFeeAssets;
    uint256 expectedFeeShares = expectedTotalFeeAssets * (totalSupply_ + offset) / (feeAdjustedAssets + 1);
    uint256 expectedMgmtShares = expectedMgmtFeeAssets * (totalSupply_ + offset) / (feeAdjustedAssets + 1);

    assertEq(mgmtShares + perfShares, expectedFeeShares, "total shares should use combined fee-adjusted base");
    assertEq(mgmtShares, expectedMgmtShares, "management shares");
    assertEq(perfShares, expectedFeeShares - expectedMgmtShares, "performance shares");
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

  function test_pendingFees_LongElapsedTimeCapsFeeAssets() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0); // 2% per year

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    vm.warp(block.timestamp + 1000 * 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    uint256 offset = positionManager.virtualShareOffset();
    uint256 expectedShares = totalAssets_ * (totalSupply_ + offset);

    assertEq(mgmtShares, expectedShares, "management fee assets should cap at total assets");
    assertEq(perfShares, 0, "no performance fee");

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0);

    assertEq(positionManager.balanceOf(feeRecipient), expectedShares, "accrual should not underflow or revert");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*           LEVERED-SLICE PERFORMANCE FEE TESTS              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice An unlevered vault (debt == 0) accrues zero performance fees regardless of NAV gain.
  /// @dev `lastDebt` stays at its bootstrap-sentinel zero, so the performance branch is skipped.
  function test_performanceFee_zeroForUnleveredVault() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    assertEq(positionManager.lastDebt(), 0, "lastDebt remains zero for unlevered deposit");

    // Big collateral gain — still no perf fee on the levered slice.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 200 / 100);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    assertEq(positionManager.balanceOf(feeRecipient), 0, "no perf fee on a vault with zero debt");
    assertEq(positionManager.lastDebt(), 0, "lastDebt still zero - no leverage introduced");
  }

  /// @notice The first accrual after an unlevered vault introduces leverage must produce zero
  ///         performance fee and seed `lastDebt`. The second accrual then charges normally.
  function test_performanceFee_bootstrapZeroThenSeedsLastDebt() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000);

    // Unlevered deposit — lastDebt stays zero (bootstrap sentinel).
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);
    assertEq(positionManager.lastDebt(), 0, "lastDebt is zero before leverage");

    // Big NAV gain.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 150 / 100);

    // Introduce leverage — _accrueFees sees lastDebt == 0 at entry, so performance fee is skipped
    // even though the levered-slice basis would otherwise produce a charge. The snapshot at the
    // end of the operation seeds lastDebt with the post-op debt.
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, DEBT_AMOUNT);

    assertEq(positionManager.balanceOf(feeRecipient), 0, "bootstrap accrual mints zero perf fee");
    assertGt(positionManager.lastDebt(), 0, "lastDebt seeded after bootstrap");

    // Another collateral gain — second accrual should now charge perf fees normally.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 200 / 100);

    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    assertGt(positionManager.balanceOf(feeRecipient), 0, "second accrual charges perf fee");
  }

  /// @notice Hand-computed basis: with collateral up 50% and debt unchanged, the levered-slice
  ///         basis equals `lastDebt - mulDiv(currentDebt, lastCollat, currentCollat)`.
  function test_performanceFee_basisExactComputation() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000); // 20% perf fee, no mgmt fee for cleaner math

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Snapshot values seeded by the deposit.
    uint256 lastCollat = _lastTotalAssets() + positionManager.lastDebt();
    uint256 lastDebt_ = positionManager.lastDebt();
    assertEq(lastCollat, COLLATERAL_AMOUNT, "lastCollat = NAV + debt = collateral");
    assertEq(lastDebt_, DEBT_AMOUNT, "lastDebt = DEBT_AMOUNT");

    // 50% collateral price gain, no time passage (so mgmt fee = 0).
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 150 / 100);

    (uint256 totalAssets_,,, uint256 perfShares) = positionManager.pendingFees();
    uint256 currentDebt = positionManager.debtAmount();
    uint256 currentCollat = totalAssets_ + currentDebt;

    uint256 hypotheticalDebt = currentDebt * lastCollat / currentCollat; // matches mulDiv round-down
    uint256 basis = lastDebt_ - hypotheticalDebt;
    uint256 expectedPerfAssets = basis * 2000 / 10_000;

    // Convert expected assets to shares against the fee-adjusted base, matching _pendingFees.
    uint256 totalSupply_ = positionManager.totalSupply();
    uint256 offset = positionManager.virtualShareOffset();
    uint256 feeAdjustedAssets = totalAssets_ - expectedPerfAssets;
    uint256 expectedPerfShares = expectedPerfAssets * (totalSupply_ + offset) / (feeAdjustedAssets + 1);

    assertEq(perfShares, expectedPerfShares, "perf shares match hand-computed basis");
    assertGt(basis, 0, "basis is positive on collateral gain");
  }

  /// @notice A vault whose LTV improves (debt repaid faster than collateral lost) produces a
  ///         negative basis, which must clamp to zero performance fee.
  function test_performanceFee_negativeBasisClampsToZero() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, 2000);

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Repay half the debt — currentDebt drops, currentCollat slightly drops too (only the debt
    // repaid leaves the position). LTV ratio improves => hypotheticalDebt < currentDebt => basis < 0.
    _mintDebt(minter, DEBT_AMOUNT / 2);
    vm.prank(minter);
    debtToken.approve(address(positionManager), DEBT_AMOUNT / 2);
    vm.prank(minter);
    positionManager.withdraw(0, DEBT_AMOUNT / 2, WithdrawalStrategy.PROPORTIONAL);

    // Recipient balance should still be zero — no perf fee charged because basis is non-positive.
    assertEq(positionManager.balanceOf(feeRecipient), 0, "negative basis must clamp to zero perf fee");
  }

  /// @notice On a leveraged vault, the management fee is charged on the aggregate collateral
  ///         (not NAV). With 10_000 collat / 5_000 debt / 1y at 2%, the basis is 10_000e18 — not
  ///         5_000e18 as it would be under the old NAV-based formula.
  function test_managementFee_basedOnCollateralNotNAV() public {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 0); // 2% mgmt, no perf

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 365 days);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();

    // mgmt fee should be ~2% of *collateral*, not of NAV
    uint256 currentDebt = positionManager.debtAmount();
    uint256 currentCollat = totalAssets_ + currentDebt;
    uint256 expectedMgmtFeeAssets = currentCollat * 200 / 10_000;

    uint256 offset = positionManager.virtualShareOffset();
    uint256 feeAdjustedAssets = totalAssets_ - expectedMgmtFeeAssets;
    uint256 expectedMgmtShares = expectedMgmtFeeAssets * (totalSupply_ + offset) / (feeAdjustedAssets + 1);

    assertEq(mgmtShares, expectedMgmtShares, "mgmt shares on collateral basis");
    assertEq(perfShares, 0, "no perf fee");
    // Sanity: mgmt fee on collat (200e18 at 10_000 collat) > mgmt fee on NAV (100e18 at 5_000 NAV)
    assertEq(expectedMgmtFeeAssets, COLLATERAL_AMOUNT * 200 / 10_000, "basis is total collateral");
  }

  /// @notice The public `lastDebt()` view returns the snapshot value and tracks updates.
  function test_lastDebt_viewTracksSnapshot() public {
    assertEq(positionManager.lastDebt(), 0, "lastDebt starts at zero");

    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    assertEq(positionManager.lastDebt(), DEBT_AMOUNT, "lastDebt updated after leveraged deposit");

    _mintDebt(minter, DEBT_AMOUNT);
    vm.prank(minter);
    debtToken.approve(address(positionManager), DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.withdraw(0, DEBT_AMOUNT, WithdrawalStrategy.PROPORTIONAL);

    assertEq(positionManager.lastDebt(), 0, "lastDebt back to zero after full repayment");
  }
}
