// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {AddressStatus} from "src/interfaces/guard/ITransferGuard.sol";

/// @title FacilityLPTest
/// @notice Tests for Facility LP operations (deposit, withdraw, claim)
contract FacilityLPTest is FacilityBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       DEPOSIT TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_multipleUsers() public {
    uint256 intentId = _createDefaultIntent();
    uint256 deposit1 = 1000e18;
    uint256 deposit2 = 500e18;

    // User 1 deposits
    _depositToPM(user, deposit1);
    vm.prank(user);
    facility.deposit(intentId, deposit1);

    // User 2 deposits
    _depositToPM(user2, deposit2);
    vm.prank(user2);
    facility.deposit(intentId, deposit2);

    assertEq(facility.balanceOf(user, intentId), deposit1, "User 1 balance incorrect");
    assertEq(facility.balanceOf(user2, intentId), deposit2, "User 2 balance incorrect");
    assertEq(facility.totalSupply(intentId), deposit1 + deposit2, "Total supply incorrect");
  }

  function test_deposit_revertWhenZeroAmount() public {
    uint256 intentId = _createDefaultIntent();

    // Deposit 0 should revert
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.deposit(intentId, 0);
  }

  function test_deposit_revertWhenPaused() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);

    // Pause the facility
    vm.prank(pauser);
    facility.pauseFor(1 hours);

    // Should revert
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.deposit(intentId, DEFAULT_AMOUNT);
  }

  function test_deposit_revertWhenNotDepositing() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);

    // Move past resolveStart
    vm.warp(block.timestamp + 1 days + 1);

    // Should revert - intent is now in resolving phase
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotDepositing.selector, intentId));
    facility.deposit(intentId, DEFAULT_AMOUNT);
  }

  function test_deposit_revertWhenExceedsCap() public {
    uint256 intentId = _createDefaultIntent();
    uint256 exceedingAmount = DEFAULT_DEPOSIT_CAP + 1;

    _depositToPM(user, exceedingAmount);

    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibFacilityErrors.DepositCapExceeded.selector, intentId, DEFAULT_DEPOSIT_CAP, exceedingAmount
      )
    );
    facility.deposit(intentId, exceedingAmount);
  }

  function test_deposit_revertWhenIntentResolved() public {
    // Create intent with deposits (helper already moves to RESOLVING phase)
    uint256 intentId = _createIntentWithDeposits(1000e18);

    // Resolve the intent
    vm.prank(facilitator);
    facility.resolve(intentId);

    // Try to deposit - should revert
    _depositToPM(user2, 100e18);
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotDepositing.selector, intentId));
    facility.deposit(intentId, 100e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WITHDRAW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdraw_revertWhenZeroAmount() public {
    uint256 intentId = _createDefaultIntent();
    uint256 depositAmount = 1000e18;

    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Withdraw 0 should revert
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.withdraw(intentId, user, user, 0);
  }

  function test_withdraw_toReceiver() public {
    uint256 intentId = _createDefaultIntent();
    uint256 depositAmount = 1000e18;

    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Withdraw to user2
    vm.prank(user);
    facility.withdraw(intentId, user, user2, depositAmount);

    // User2 should receive tokens
    assertEq(positionManager.balanceOf(user2), depositAmount, "Receiver should get tokens");
  }

  function test_withdraw_withOperator() public {
    uint256 intentId = _createDefaultIntent();
    uint256 depositAmount = 1000e18;

    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Set user2 as operator for user
    vm.prank(user);
    facility.setOperator(user2, true);

    // user2 withdraws on behalf of user
    vm.prank(user2);
    facility.withdraw(intentId, user, user2, depositAmount);

    assertEq(facility.balanceOf(user, intentId), 0, "User LP balance should be 0");
    assertEq(positionManager.balanceOf(user2), depositAmount, "Operator should receive tokens");
  }

  function test_withdraw_revertWhenPaused() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.withdraw(intentId, user, user, DEFAULT_AMOUNT);
  }

  function test_withdraw_revertWhenNotDepositing() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    // Move past resolveStart
    vm.warp(block.timestamp + 1 days + 1);

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotDepositing.selector, intentId));
    facility.withdraw(intentId, user, user, DEFAULT_AMOUNT);
  }

  function test_withdraw_revertWhenInsufficientBalance() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    vm.prank(user);
    vm.expectRevert(); // InsufficientBalance
    facility.withdraw(intentId, user, user, DEFAULT_AMOUNT + 1);
  }

  function test_withdraw_revertWhenNotOperator() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    // user2 tries to withdraw from user without being operator
    vm.prank(user2);
    vm.expectRevert(); // InsufficientPermission
    facility.withdraw(intentId, user, user2, DEFAULT_AMOUNT);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CLAIM TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_claim_afterResolve() public {
    uint256 depositAmount = 1000e18;
    uint256 intentId = _createIntentWithDeposits(depositAmount);

    // Intent is already in RESOLVING phase (helper warped time), just resolve
    vm.prank(facilitator);
    facility.resolve(intentId);

    // Claim
    uint256 pmBalanceBefore = positionManager.balanceOf(user);
    vm.prank(user);
    (address[] memory tokens, uint256[] memory amounts) = facility.claim(intentId, user, user, depositAmount);

    // Should receive deposit asset back (PM shares)
    assertEq(tokens.length, 1, "Should have 1 token");
    assertEq(tokens[0], address(positionManager), "Token should be PM");
    assertEq(amounts[0], depositAmount, "Amount should match deposit");
    assertEq(positionManager.balanceOf(user), pmBalanceBefore + depositAmount, "Should receive PM shares");
    assertEq(facility.balanceOf(user, intentId), 0, "LP balance should be 0");
  }

  function test_claim_revertWhenZeroShares() public {
    uint256 depositAmount = 1000e18;
    uint256 intentId = _createIntentWithDeposits(depositAmount);

    // Intent is already in RESOLVING phase, just resolve
    vm.prank(facilitator);
    facility.resolve(intentId);

    // Claim 0 shares should revert
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.claim(intentId, user, user, 0);
  }

  function test_claim_withOperator() public {
    uint256 depositAmount = 1000e18;
    uint256 intentId = _createIntentWithDeposits(depositAmount);

    // Intent is already in RESOLVING phase, just resolve
    vm.prank(facilitator);
    facility.resolve(intentId);

    // Set user2 as operator
    vm.prank(user);
    facility.setOperator(user2, true);

    // user2 claims on behalf of user, receiving tokens
    vm.prank(user2);
    (address[] memory tokens, uint256[] memory amounts) = facility.claim(intentId, user, user2, depositAmount);

    assertEq(tokens.length, 1, "Should have 1 token");
    assertEq(amounts[0], depositAmount, "Amount should match");
    assertEq(positionManager.balanceOf(user2), depositAmount, "Operator should receive tokens");
    assertEq(facility.balanceOf(user, intentId), 0, "User LP balance should be 0");
  }

  function test_claim_revertWhenPaused() public {
    uint256 depositAmount = 1000e18;
    uint256 intentId = _createIntentWithDeposits(depositAmount);

    // Intent is already in RESOLVING phase, just resolve
    vm.prank(facilitator);
    facility.resolve(intentId);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.claim(intentId, user, user, depositAmount);
  }

  function test_claim_revertWhenNotResolved() public {
    uint256 depositAmount = 1000e18;
    uint256 intentId = _createIntentWithDeposits(depositAmount);

    // Intent is in resolving phase but not resolved
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolved.selector, intentId));
    facility.claim(intentId, user, user, depositAmount);
  }

  function test_claim_revertWhenInsufficientBalance() public {
    uint256 depositAmount = 1000e18;
    uint256 intentId = _createIntentWithDeposits(depositAmount);

    // Intent is already in RESOLVING phase, just resolve
    vm.prank(facilitator);
    facility.resolve(intentId);

    vm.prank(user);
    vm.expectRevert(); // InsufficientBalance
    facility.claim(intentId, user, user, depositAmount + 1);
  }

  function test_claim_revertWhenNotOperator() public {
    uint256 depositAmount = 1000e18;
    // _createIntentWithDeposits already warps time to RESOLVING state
    uint256 intentId = _createIntentWithDeposits(depositAmount);

    // Resolve the intent (no lock needed - intent is already RESOLVING)
    vm.prank(facilitator);
    facility.resolve(intentId);

    // user2 tries to claim from user without being operator
    vm.prank(user2);
    vm.expectRevert(); // InsufficientPermission
    facility.claim(intentId, user, user2, depositAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_deposit_amount(uint256 amount) public {
    amount = bound(amount, 1, DEFAULT_DEPOSIT_CAP);

    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, amount);

    vm.prank(user);
    facility.deposit(intentId, amount);

    assertEq(facility.balanceOf(user, intentId), amount, "LP balance should match deposit");
    assertEq(facility.totalSupply(intentId), amount, "Total supply should match deposit");
  }

  function testFuzz_withdraw_partialAmount(uint256 depositAmount, uint256 withdrawAmount) public {
    depositAmount = bound(depositAmount, 1, DEFAULT_DEPOSIT_CAP);
    withdrawAmount = bound(withdrawAmount, 1, depositAmount);

    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, depositAmount);

    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    vm.prank(user);
    facility.withdraw(intentId, user, user, withdrawAmount);

    assertEq(facility.balanceOf(user, intentId), depositAmount - withdrawAmount, "LP balance incorrect");
    assertEq(facility.totalSupply(intentId), depositAmount - withdrawAmount, "Total supply incorrect");
  }

  function testFuzz_claim_distribution(uint256 deposit1, uint256 deposit2) public {
    deposit1 = bound(deposit1, 1e18, DEFAULT_DEPOSIT_CAP / 2);
    deposit2 = bound(deposit2, 1e18, DEFAULT_DEPOSIT_CAP / 2);

    uint256 intentId = _createDefaultIntent();

    // Users deposit
    _depositToPM(user, deposit1);
    vm.prank(user);
    facility.deposit(intentId, deposit1);

    _depositToPM(user2, deposit2);
    vm.prank(user2);
    facility.deposit(intentId, deposit2);

    // Move to RESOLVING phase and resolve
    // After warp, intent is already RESOLVING (no lock needed)
    vm.warp(block.timestamp + 1 days + 1);
    vm.prank(facilitator);
    facility.resolve(intentId);

    // Both users claim their full LP balance
    vm.prank(user);
    (, uint256[] memory amounts1) = facility.claim(intentId, user, user, deposit1);

    vm.prank(user2);
    (, uint256[] memory amounts2) = facility.claim(intentId, user2, user2, deposit2);

    // Since no swaps occurred, each user gets back their proportional share of the PM tokens
    // User's claim = (userLPTokens / totalLPSupply) * intentAssets
    // With 1:1 LP:deposit ratio and no swaps, users get back their original deposits
    uint256 totalDeposit = deposit1 + deposit2;
    uint256 expectedUser1 = deposit1; // (deposit1 / totalDeposit) * totalDeposit = deposit1
    uint256 expectedUser2 = deposit2;

    // Allow small rounding error
    assertApproxEqAbs(amounts1[0], expectedUser1, 1, "User1 claim amount incorrect");
    assertApproxEqAbs(amounts2[0], expectedUser2, 1, "User2 claim amount incorrect");
  }

  function testFuzz_multipleDepositsAndWithdrawals(uint256[3] memory deposits, uint256[3] memory withdrawals) public {
    uint256 intentId = _createDefaultIntent();

    uint256 totalDeposit;
    for (uint256 i = 0; i < 3; i++) {
      deposits[i] = bound(deposits[i], 1, DEFAULT_DEPOSIT_CAP / 10);
      withdrawals[i] = bound(withdrawals[i], 0, deposits[i]);
    }

    // Perform multiple deposits
    for (uint256 i = 0; i < 3; i++) {
      _depositToPM(user, deposits[i]);
      vm.prank(user);
      facility.deposit(intentId, deposits[i]);
      totalDeposit += deposits[i];
    }

    assertEq(facility.balanceOf(user, intentId), totalDeposit, "Total deposit incorrect");

    // Perform multiple withdrawals
    uint256 totalWithdrawn;
    for (uint256 i = 0; i < 3; i++) {
      if (withdrawals[i] > 0 && totalWithdrawn + withdrawals[i] <= totalDeposit) {
        vm.prank(user);
        facility.withdraw(intentId, user, user, withdrawals[i]);
        totalWithdrawn += withdrawals[i];
      }
    }

    assertEq(facility.balanceOf(user, intentId), totalDeposit - totalWithdrawn, "Final balance incorrect");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      TRANSFER TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_transfer_revertWhenNonTransferable() public {
    // Create intent with transferableIntent = false
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_intentParamsWithDualPM());

    // Deposit to the intent
    _depositToPM(user, 1000e18);
    vm.prank(user);
    facility.deposit(intentId, 1000e18);

    // Try to transfer LP tokens - should revert
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentTransfersLocked.selector, intentId));
    facility.transfer(user2, intentId, 100e18);
  }

  function test_transfer_succeedsWhenTransferable() public {
    // Default intent is transferable
    uint256 intentId = _createDefaultIntent();

    _depositToPM(user, 1000e18);
    vm.prank(user);
    facility.deposit(intentId, 1000e18);

    // Transfer should succeed
    vm.prank(user);
    facility.transfer(user2, intentId, 100e18);

    assertEq(facility.balanceOf(user, intentId), 900e18, "User balance incorrect");
    assertEq(facility.balanceOf(user2, intentId), 100e18, "User2 balance incorrect");
  }

  function test_transfer_revertWhenGuardBlocks() public {
    uint256 intentId = _createDefaultIntent();

    _depositToPM(user, 1000e18);
    vm.prank(user);
    facility.deposit(intentId, 1000e18);

    // Configure transfer guard to block user2 (blocklist)
    vm.prank(owner);
    transferGuard.setAddressStatus(user2, AddressStatus.BLOCKLIST);

    // Try to transfer to blocklisted address
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.TransferBlocked.selector, address(transferGuard), user, user2, 100e18)
    );
    facility.transfer(user2, intentId, 100e18);
  }
}
