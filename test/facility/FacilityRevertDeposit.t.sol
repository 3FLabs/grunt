// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";

/// @title FacilityRevertDepositTest
/// @notice Tests for Facility.revertDeposit (compliance-gated deposit reversal)
contract FacilityRevertDepositTest is FacilityBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ACCESS CONTROL                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_revertDeposit_byOwner() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    vm.prank(owner);
    facility.revertDeposit(intentId, user);

    assertEq(facility.balanceOf(user, intentId), 0, "User shares should be 0");
    assertEq(facility.totalSupply(intentId), 0, "Total supply should be 0");
  }

  function test_revertDeposit_byComplianceRole() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    vm.prank(pauser); // pauser has COMPLIANCE_ROLE
    facility.revertDeposit(intentId, user);

    assertEq(facility.balanceOf(user, intentId), 0, "User shares should be 0");
  }

  function test_revertDeposit_revertWhenNotAuthorized() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.revertDeposit(intentId, user);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      REVERT MECHANICS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_revertDeposit_returnsFullDepositAsset() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);

    uint256 pmBalanceBefore = positionManager.balanceOf(user);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);
    assertEq(positionManager.balanceOf(user), pmBalanceBefore - DEFAULT_AMOUNT, "PM balance should decrease");

    vm.prank(owner);
    facility.revertDeposit(intentId, user);

    assertEq(positionManager.balanceOf(user), pmBalanceBefore, "PM balance should be restored");
  }

  function test_revertDeposit_noOpWhenZeroBalance() public {
    uint256 intentId = _createDefaultIntent();

    // user has no deposit — should not revert, just no-op
    vm.prank(owner);
    facility.revertDeposit(intentId, user);

    assertEq(facility.balanceOf(user, intentId), 0, "Balance should remain 0");
  }

  function test_revertDeposit_partialRevert_multipleUsers() public {
    uint256 intentId = _createDefaultIntent();
    uint256 deposit1 = 3000e18;
    uint256 deposit2 = 7000e18;

    _depositToPM(user, deposit1);
    vm.prank(user);
    facility.deposit(intentId, deposit1);

    _depositToPM(user2, deposit2);
    vm.prank(user2);
    facility.deposit(intentId, deposit2);

    // Revert only user1's deposit
    vm.prank(owner);
    facility.revertDeposit(intentId, user);

    assertEq(facility.balanceOf(user, intentId), 0, "User 1 shares should be 0");
    assertEq(facility.balanceOf(user2, intentId), deposit2, "User 2 shares should be unchanged");
    assertEq(facility.totalSupply(intentId), deposit2, "Total supply should only be user 2's deposit");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    RESOLVING / RESOLVED GUARD                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_revertDeposit_revertWhenResolved() public {
    uint256 intentId = _createIntentWithDeposits(DEFAULT_AMOUNT);

    // Resolve the intent
    vm.prank(facilitator);
    facility.resolve(intentId);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AlreadyResolving.selector, intentId));
    facility.revertDeposit(intentId, user);
  }

  function test_revertDeposit_revertWhenDepositAssetBalanceBelowTotalSupply() public {
    // Create intent with debtToken as deposit asset so repay can reduce its balance
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_intentParamsWithTargetPM());

    // Deposit debtToken
    _mintDebt(user, DEFAULT_AMOUNT);
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    // Move to resolving phase
    vm.warp(block.timestamp + 1 days + 1);

    // Set up request (uses debtToken as its asset) and repay to move debtToken out
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    vm.prank(facilitator);
    facility.repay(intentId, DEFAULT_AMOUNT);

    // Now deposit asset (debtToken) balance is 0, which is < totalSupply
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.AlreadyResolving.selector, intentId));
    facility.revertDeposit(intentId, user);
  }

  function test_revertDeposit_worksInResolvingPhaseIfBalanceSufficient() public {
    // Intent in resolving phase but no funds have been moved — deposit asset balance == totalSupply
    uint256 intentId = _createIntentWithDeposits(DEFAULT_AMOUNT);

    // Still in resolving phase but balance is intact
    vm.prank(owner);
    facility.revertDeposit(intentId, user);

    assertEq(facility.balanceOf(user, intentId), 0, "Shares should be burned");
    assertEq(facility.totalSupply(intentId), 0, "Total supply should be 0");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_revertDeposit_returnsExactAmount(uint256 amount) public {
    amount = bound(amount, 1, DEFAULT_DEPOSIT_CAP);

    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, amount);

    vm.prank(user);
    facility.deposit(intentId, amount);

    uint256 pmBalanceBefore = positionManager.balanceOf(user);

    vm.prank(owner);
    facility.revertDeposit(intentId, user);

    assertEq(positionManager.balanceOf(user), pmBalanceBefore + amount, "Should get back exact amount");
    assertEq(facility.balanceOf(user, intentId), 0, "Shares should be 0");
    assertEq(facility.totalSupply(intentId), 0, "Total supply should be 0");
  }

  function testFuzz_revertDeposit_multipleUsersIndependent(uint256 amount1, uint256 amount2) public {
    amount1 = bound(amount1, 1, DEFAULT_DEPOSIT_CAP / 2);
    amount2 = bound(amount2, 1, DEFAULT_DEPOSIT_CAP / 2);

    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, amount1);
    _depositToPM(user2, amount2);

    vm.prank(user);
    facility.deposit(intentId, amount1);
    vm.prank(user2);
    facility.deposit(intentId, amount2);

    // Revert user1 only
    vm.prank(owner);
    facility.revertDeposit(intentId, user);

    assertEq(facility.balanceOf(user, intentId), 0, "User 1 shares should be 0");
    assertEq(facility.balanceOf(user2, intentId), amount2, "User 2 shares unchanged");
    assertEq(facility.totalSupply(intentId), amount2, "Total supply should be user2 only");

    // Revert user2
    vm.prank(owner);
    facility.revertDeposit(intentId, user2);

    assertEq(facility.balanceOf(user2, intentId), 0, "User 2 shares should be 0");
    assertEq(facility.totalSupply(intentId), 0, "Total supply should be 0");
  }
}
