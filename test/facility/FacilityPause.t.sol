// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibPause} from "src/libs/common/LibPause.sol";

/// @title FacilityPauseTest
/// @notice Tests for Facility pause functionality
contract FacilityPauseTest is FacilityBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        PAUSE TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pause_byOwner() public {
    vm.prank(owner);
    facility.pause();

    (bool isPaused, uint40 pausedUntil,) = facility.facilityConfig();
    assertTrue(isPaused, "Should be paused");
    assertEq(pausedUntil, type(uint40).max, "Should be permanent pause");
  }

  function test_pause_byPauser() public {
    vm.prank(pauser);
    facility.pause();

    (bool isPaused,,) = facility.facilityConfig();
    assertTrue(isPaused, "Should be paused");
  }

  function test_pause_emitsEvent() public {
    vm.prank(owner);
    vm.expectEmit(false, false, false, true);
    emit IFacility.FacilityPausedSet(type(uint40).max);
    facility.pause();
  }

  function test_pause_revertWhenNotAuthorized() public {
    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.pause();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE FOR TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pauseFor_byOwner() public {
    uint256 duration = 1 hours;

    vm.prank(owner);
    facility.pauseFor(duration);

    (bool isPaused, uint40 pausedUntil,) = facility.facilityConfig();
    assertTrue(isPaused, "Should be paused");
    assertEq(pausedUntil, uint40(block.timestamp + duration), "PausedUntil should match duration");
  }

  function test_pauseFor_byPauser() public {
    uint256 duration = 1 days;

    vm.prank(pauser);
    facility.pauseFor(duration);

    (bool isPaused, uint40 pausedUntil,) = facility.facilityConfig();
    assertTrue(isPaused, "Should be paused");
    assertEq(pausedUntil, uint40(block.timestamp + duration), "PausedUntil should match");
  }

  function test_pauseFor_emitsEvent() public {
    uint256 duration = 1 hours;
    uint40 expectedPausedUntil = uint40(block.timestamp + duration);

    vm.prank(owner);
    vm.expectEmit(false, false, false, true);
    emit IFacility.FacilityPausedSet(expectedPausedUntil);
    facility.pauseFor(duration);
  }

  function test_pauseFor_revertWhenNotAuthorized() public {
    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.pauseFor(1 hours);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       UNPAUSE TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_unpause_byOwner() public {
    // First pause
    vm.prank(owner);
    facility.pause();

    // Then unpause
    vm.prank(owner);
    facility.unpause();

    (bool isPaused, uint40 pausedUntil,) = facility.facilityConfig();
    assertFalse(isPaused, "Should not be paused");
    assertEq(pausedUntil, 0, "PausedUntil should be 0");
  }

  function test_unpause_byPauser() public {
    vm.prank(pauser);
    facility.pause();

    vm.prank(pauser);
    facility.unpause();

    (bool isPaused,,) = facility.facilityConfig();
    assertFalse(isPaused, "Should not be paused");
  }

  function test_unpause_emitsEvent() public {
    vm.prank(owner);
    facility.pause();

    vm.prank(owner);
    vm.expectEmit(false, false, false, true);
    emit IFacility.FacilityPausedSet(0);
    facility.unpause();
  }

  function test_unpause_revertWhenNotAuthorized() public {
    vm.prank(owner);
    facility.pause();

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.unpause();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   OPERATIONS WHEN PAUSED                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_revertsWhenPaused() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);

    vm.prank(pauser);
    facility.pause();

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.deposit(intentId, DEFAULT_AMOUNT);
  }

  function test_withdraw_revertsWhenPaused() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);

    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    vm.prank(pauser);
    facility.pause();

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.withdraw(intentId, user, user, DEFAULT_AMOUNT);
  }

  function test_claim_revertsWhenPaused() public {
    // _createIntentWithDeposits already warps time to make intent RESOLVING
    uint256 intentId = _createIntentWithDeposits(DEFAULT_AMOUNT);

    // Resolve the intent (requires FACILITATOR_ROLE)
    vm.prank(facilitator);
    facility.resolve(intentId);

    vm.prank(pauser);
    facility.pause();

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.claim(intentId, user, user, DEFAULT_AMOUNT);
  }

  function test_createIntent_revertsWhenPaused() public {
    vm.prank(pauser);
    facility.pause();

    vm.prank(owner);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.createIntent(_defaultIntentProperties());
  }

  function test_operationsWorkAfterUnpause() public {
    uint256 intentId = _createDefaultIntent();
    _depositToPM(user, DEFAULT_AMOUNT);

    // Pause
    vm.prank(pauser);
    facility.pause();

    // Unpause
    vm.prank(pauser);
    facility.unpause();

    // Operations should work now
    vm.prank(user);
    facility.deposit(intentId, DEFAULT_AMOUNT);

    assertEq(facility.balanceOf(user, intentId), DEFAULT_AMOUNT, "Deposit should succeed after unpause");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_pauseFor_duration(uint256 duration) public {
    duration = bound(duration, 1, 365 days);

    vm.prank(owner);
    facility.pauseFor(duration);

    (bool isPaused, uint40 pausedUntil,) = facility.facilityConfig();
    assertTrue(isPaused, "Should be paused");
    assertEq(pausedUntil, uint40(block.timestamp + duration), "PausedUntil should match");
  }

  function testFuzz_pauseFor_expiresCorrectly(uint256 duration, uint256 timePassed) public {
    duration = bound(duration, 1, 365 days);
    timePassed = bound(timePassed, 0, 365 days);

    vm.prank(owner);
    facility.pauseFor(duration);

    vm.warp(block.timestamp + timePassed);

    (bool isPaused,,) = facility.facilityConfig();

    if (timePassed > duration) {
      assertFalse(isPaused, "Should not be paused after duration");
    } else {
      assertTrue(isPaused, "Should still be paused before duration");
    }
  }

  function testFuzz_pauseUnpauseCycle(uint8 cycles) public {
    cycles = uint8(bound(cycles, 1, 10));

    for (uint256 i = 0; i < cycles; i++) {
      // Pause
      vm.prank(owner);
      facility.pause();

      (bool isPaused,,) = facility.facilityConfig();
      assertTrue(isPaused, "Should be paused");

      // Unpause
      vm.prank(owner);
      facility.unpause();

      (isPaused,,) = facility.facilityConfig();
      assertFalse(isPaused, "Should not be paused");
    }
  }
}
