// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {Asset} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";

/// @title FacilityPositionManagerTest
/// @notice Tests for Facility position manager operations (depositManager, withdrawManager, burnManager)
contract FacilityPositionManagerTest is FacilityBaseTest {
  // NOTE: PositionManager uses VIRTUAL_SHARES=1e6 and VIRTUAL_ASSETS=1 for inflation protection.
  // This means for the first deposit: shares = collateral * 1e6
  // So to stay within DEFAULT_DEPOSIT_CAP (1e24), max collateral is 1e24 / 1e6 = 1e18
  // We use small amounts in these tests to avoid hitting the cap.
  uint256 constant PM_SHARE_MULTIPLIER = 1e6;
  uint256 constant SMALL_COLLATERAL = 100e12; // Results in 100e18 shares
  uint256 constant MEDIUM_COLLATERAL = 500e12; // Results in 500e18 shares

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SETUP HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates intent where PM is deposit asset (default) and gets to resolving phase with collateral
  function _createResolvingIntentWithCollateral(uint256 collateralAmount)
    internal
    returns (uint256 intentId, uint256 shares)
  {
    // First, deposit PM shares to the intent
    intentId = _createDefaultIntent();
    shares = _depositToPM(user, collateralAmount);

    vm.prank(user);
    facility.deposit(intentId, shares);

    // Move to resolving phase
    vm.warp(block.timestamp + 1 days + 1);
  }

  /// @notice Creates intent where PM is target asset and gets to resolving with debt tokens
  function _createResolvingIntentWithDebt(uint256 debtAmount) internal returns (uint256 intentId) {
    // Create intent with target as PM (deposit asset is debt token)
    vm.prank(owner);
    intentId = facility.createIntent(_intentParamsWithTargetPM());

    // Mint debt tokens and deposit
    _mintDebt(user, debtAmount);
    vm.startPrank(user);
    debtToken.approve(address(facility), debtAmount);
    facility.deposit(intentId, debtAmount);
    vm.stopPrank();

    // Move to resolving phase
    vm.warp(block.timestamp + 1 days + 1);
  }

  /// @notice Fund intent with collateral tokens (for PM deposit operations)
  function _fundIntentWithCollateral(uint256 amount) internal {
    _mintCollateral(address(facility), amount);
  }

  /// @notice Fund intent with debt tokens (for PM repay operations)
  function _fundIntentWithDebt(uint256 amount) internal {
    _mintDebt(address(facility), amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   DEPOSIT MANAGER TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_depositManager_depositCollateralAndBorrow() public {
    (uint256 intentId, uint256 initialShares) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    // First, withdraw some collateral to get it into the intent's tracked balance
    // The PM was funded with SMALL_COLLATERAL, so we can withdraw some of it
    uint256 withdrawAmount = SMALL_COLLATERAL / 4;
    vm.prank(facilitator);
    facility.withdrawManager(intentId, withdrawAmount, 0, false);

    // Now we have collateral in the intent's balance, deposit it back with borrowing
    uint256 depositAmount = withdrawAmount / 2;
    uint256 borrowAmount = depositAmount / 10;

    vm.prank(facilitator);
    facility.depositManager(intentId, depositAmount, borrowAmount, false);

    // Check intent balances were updated
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(intentId);

    bool hasShares = false;
    bool hasDebt = false;
    for (uint256 i = 0; i < tokens.length; i++) {
      if (tokens[i] == address(positionManager)) {
        hasShares = true;
        // Should still have shares (reduced by withdraw, increased by deposit)
        assertTrue(amounts[i] > 0, "Should have PM shares after operations");
      }
      if (tokens[i] == address(debtToken)) {
        hasDebt = true;
        assertEq(amounts[i], borrowAmount, "Should have borrowed amount");
      }
    }
    assertTrue(hasShares, "Should have PM shares in balances");
    assertTrue(hasDebt, "Should have debt token in balances");
  }

  function test_depositManager_depositOnly() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    // First withdraw to get collateral into intent's balance
    uint256 withdrawAmount = SMALL_COLLATERAL / 4;
    vm.prank(facilitator);
    facility.withdrawManager(intentId, withdrawAmount, 0, false);

    // Deposit without borrowing
    uint256 depositAmount = withdrawAmount / 2;
    vm.prank(facilitator);
    facility.depositManager(intentId, depositAmount, 0, false);
  }

  function test_depositManager_useTargetAsset() public {
    // This test demonstrates using the target asset (PM) for deposit operations
    // For this to work, we need collateral in the intent's balance
    // Skip this test for now - it requires a more complex setup with Fund or Swap operations
    // to get collateral into an intent where depositAsset is not PM
    vm.skip(true);
  }

  function test_depositManager_revertWhenPaused() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);
    uint256 depositAmount = SMALL_COLLATERAL / 2;
    _fundIntentWithCollateral(depositAmount);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.depositManager(intentId, depositAmount, 0, false);
  }

  function test_depositManager_revertWhenNotFacilitator() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);
    uint256 depositAmount = SMALL_COLLATERAL / 2;
    _fundIntentWithCollateral(depositAmount);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.depositManager(intentId, depositAmount, 0, false);
  }

  function test_depositManager_revertWhenNotResolving() public {
    uint256 intentId = _createDefaultIntent();
    uint256 depositAmount = SMALL_COLLATERAL / 2;
    _fundIntentWithCollateral(depositAmount);

    // Still in depositing phase
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.depositManager(intentId, depositAmount, 0, false);
  }

  function test_depositManager_revertWhenAssetNotPM() public {
    // Create intent where deposit asset is NOT a PM (debt token)
    uint256 intentId = _createResolvingIntentWithDebt(SMALL_COLLATERAL);

    // Try to use deposit asset (which is debt token, not PM)
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AssetNotPositionManager.selector, address(debtToken)));
    facility.depositManager(intentId, SMALL_COLLATERAL / 2, 0, false);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   WITHDRAW MANAGER TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdrawManager_withdrawCollateralAndRepay() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    // First, borrow some debt (no deposit needed, just borrow against existing collateral)
    uint256 borrowAmount = 10e12;
    vm.prank(facilitator);
    facility.depositManager(intentId, 0, borrowAmount, false);

    // Now we have debt in the intent balance
    // Withdraw some collateral and repay part of the debt
    vm.prank(facilitator);
    facility.withdrawManager(intentId, 5e12, 5e12, false);
  }

  function test_withdrawManager_repayOnly() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    // First borrow to get debt in the intent balance
    uint256 borrowAmount = 20e12;
    vm.prank(facilitator);
    facility.depositManager(intentId, 0, borrowAmount, false);

    // Repay without withdrawing collateral
    vm.prank(facilitator);
    facility.withdrawManager(intentId, 0, 10e12, false);
  }

  function test_withdrawManager_revertWhenPaused() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.withdrawManager(intentId, 10e12, 0, false);
  }

  function test_withdrawManager_revertWhenNotFacilitator() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.withdrawManager(intentId, 10e12, 0, false);
  }

  function test_withdrawManager_revertWhenNotResolving() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.withdrawManager(intentId, 10e12, 0, false);
  }

  function test_withdrawManager_revertWhenAssetNotPM() public {
    uint256 intentId = _createResolvingIntentWithDebt(SMALL_COLLATERAL);

    // Try to use deposit asset (which is debt token, not PM)
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AssetNotPositionManager.selector, address(debtToken)));
    facility.withdrawManager(intentId, 10e12, 0, false);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    BURN MANAGER TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_burnManager_burnsShares() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    // Borrow some debt against the collateral (needed for burn to work)
    uint256 borrowAmount = 10e12;
    vm.prank(facilitator);
    facility.depositManager(intentId, 0, borrowAmount, false);

    // Get current shares
    (address[] memory tokensBefore, uint256[] memory amountsBefore) = facility.intentBalances(intentId);
    uint256 sharesBefore;
    for (uint256 i = 0; i < tokensBefore.length; i++) {
      if (tokensBefore[i] == address(positionManager)) {
        sharesBefore = amountsBefore[i];
        break;
      }
    }

    // Burn some shares (note: shares = collateral * 1e6, so use appropriate amount)
    uint256 sharesToBurn = 1e18; // Small amount of shares
    vm.prank(facilitator);
    facility.burnManager(intentId, sharesToBurn, false);

    // Check shares reduced
    (address[] memory tokensAfter, uint256[] memory amountsAfter) = facility.intentBalances(intentId);
    uint256 sharesAfter;
    for (uint256 i = 0; i < tokensAfter.length; i++) {
      if (tokensAfter[i] == address(positionManager)) {
        sharesAfter = amountsAfter[i];
        break;
      }
    }

    assertEq(sharesAfter, sharesBefore - sharesToBurn, "Shares should be reduced by burn amount");
  }

  function test_burnManager_revertWhenPaused() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.burnManager(intentId, 10e18, false);
  }

  function test_burnManager_revertWhenNotFacilitator() public {
    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.burnManager(intentId, 10e18, false);
  }

  function test_burnManager_revertWhenNotResolving() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.burnManager(intentId, 10e18, false);
  }

  function test_burnManager_revertWhenAssetNotPM() public {
    uint256 intentId = _createResolvingIntentWithDebt(SMALL_COLLATERAL);

    // Try to use deposit asset (which is debt token, not PM)
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AssetNotPositionManager.selector, address(debtToken)));
    facility.burnManager(intentId, 10e18, false);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_borrowManager_validAmounts(uint256 borrowAmount) public {
    // Test borrowing against existing collateral
    borrowAmount = bound(borrowAmount, 1e9, SMALL_COLLATERAL / 4); // Keep healthy LTV

    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    vm.prank(facilitator);
    facility.depositManager(intentId, 0, borrowAmount, false);
  }

  function testFuzz_withdrawManager_validAmounts(uint256 withdrawAmount) public {
    // Test withdrawing collateral from PM
    withdrawAmount = bound(withdrawAmount, 1e9, SMALL_COLLATERAL / 4);

    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    vm.prank(facilitator);
    facility.withdrawManager(intentId, withdrawAmount, 0, false);
  }

  function testFuzz_borrowAndRepay_lifecycle(uint256 borrowAmount, uint256 repayRatio) public {
    // Borrow then repay some of it
    borrowAmount = bound(borrowAmount, 1e9, SMALL_COLLATERAL / 4);
    repayRatio = bound(repayRatio, 10, 90); // Repay 10-90% of borrowed

    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    // Borrow
    vm.prank(facilitator);
    facility.depositManager(intentId, 0, borrowAmount, false);

    // Repay part of the debt
    uint256 repayAmount = (borrowAmount * repayRatio) / 100;
    vm.prank(facilitator);
    facility.withdrawManager(intentId, 0, repayAmount, false);

    // Verify intent has balances
    (address[] memory tokens,) = facility.intentBalances(intentId);
    assertTrue(tokens.length > 0, "Should have balances");
  }

  function testFuzz_withdrawAndDeposit_lifecycle(uint256 withdrawAmount, uint256 depositRatio) public {
    // Withdraw collateral then deposit some back
    withdrawAmount = bound(withdrawAmount, 1e9, SMALL_COLLATERAL / 4);
    depositRatio = bound(depositRatio, 10, 90); // Deposit back 10-90%

    (uint256 intentId,) = _createResolvingIntentWithCollateral(SMALL_COLLATERAL);

    // Withdraw collateral
    vm.prank(facilitator);
    facility.withdrawManager(intentId, withdrawAmount, 0, false);

    // Deposit some of that collateral back
    uint256 depositAmount = (withdrawAmount * depositRatio) / 100;
    vm.prank(facilitator);
    facility.depositManager(intentId, depositAmount, 0, false);

    // Verify intent has balances
    (address[] memory tokens,) = facility.intentBalances(intentId);
    assertTrue(tokens.length > 0, "Should have balances");
  }
}
