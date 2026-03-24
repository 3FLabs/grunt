// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPause} from "src/libs/common/LibPause.sol";
import {LibPauseWrapper} from "test/mock/libs/LibPauseWrapper.sol";

/// @title LibPauseTest
/// @notice Unit and fuzz tests for LibPause library
contract LibPauseTest is Test {
  using LibPause for uint40;

  LibPauseWrapper wrapper;

  function setUp() public {
    wrapper = new LibPauseWrapper();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONSTANTS TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constants_PermanentPause() public pure {
    assertEq(LibPause.PERMANENT_PAUSE, type(uint40).max);
  }

  function test_constants_NotPaused() public pure {
    assertEq(LibPause.NOT_PAUSED, 0);
  }

  function test_constants_PermanentPauseIsPaused() public {
    uint40 pauseState = LibPause.PERMANENT_PAUSE;
    assertTrue(pauseState.paused());
  }

  function test_constants_NotPausedIsNotPaused() public {
    vm.warp(1); // Ensure block.timestamp > 0
    uint40 pauseState = LibPause.NOT_PAUSED;
    assertFalse(pauseState.paused());
  }

  function testFuzz_constants_PermanentPauseAlwaysPaused(uint256 warpTo) public {
    // Bound to uint40.max - 1 since paused() checks block.timestamp < self
    // At exactly type(uint40).max the pause would expire, but that timestamp is ~35,000 years away
    warpTo = bound(warpTo, 0, type(uint40).max - 1);
    vm.warp(warpTo);

    uint40 pauseState = LibPause.PERMANENT_PAUSE;
    assertTrue(pauseState.paused());
  }

  function testFuzz_constants_NotPausedAlwaysNotPaused(uint256 warpTo) public {
    warpTo = bound(warpTo, 1, type(uint64).max);
    vm.warp(warpTo);

    uint40 pauseState = LibPause.NOT_PAUSED;
    assertFalse(pauseState.paused());
  }

  function testFuzz_constants_PermanentPauseGreaterThanNotPaused(uint256 warpTo) public pure {
    assertGt(LibPause.PERMANENT_PAUSE, LibPause.NOT_PAUSED);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSED TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_paused_ZeroIsNotPaused() public {
    vm.warp(1);
    uint40 pauseState = 0;
    assertFalse(pauseState.paused());
  }

  function test_paused_FutureTimestampIsPaused() public {
    uint40 pauseState = uint40(block.timestamp + 1000);
    assertTrue(pauseState.paused());
  }

  function test_paused_CurrentTimestampIsNotPaused() public {
    uint40 pauseState = uint40(block.timestamp);
    assertFalse(pauseState.paused());
  }

  function test_paused_PastTimestampIsNotPaused() public {
    vm.warp(1000);
    uint40 pauseState = uint40(block.timestamp - 1);
    assertFalse(pauseState.paused());
  }

  function test_paused_ExpiresAfterTimestamp() public {
    uint40 pauseState = uint40(block.timestamp + 100);
    assertTrue(pauseState.paused());

    vm.warp(block.timestamp + 99);
    assertTrue(pauseState.paused());

    vm.warp(block.timestamp + 1);
    assertFalse(pauseState.paused());
  }

  function testFuzz_paused_FutureTimestampIsPaused(uint40 delta) public {
    vm.assume(delta > 0);
    vm.assume(uint256(block.timestamp) + uint256(delta) <= type(uint40).max);

    uint40 pauseState = uint40(block.timestamp + delta);
    assertTrue(pauseState.paused());
  }

  function testFuzz_paused_PastTimestampIsNotPaused(uint40 pauseUntil, uint256 warpTo) public {
    vm.assume(pauseUntil > 0);
    warpTo = bound(warpTo, uint256(pauseUntil) + 1, type(uint64).max);

    vm.warp(warpTo);
    assertFalse(pauseUntil.paused());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    PAUSE_FOR TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pauseFor_ZeroDurationReturnsNotPaused() public {
    uint40 result = wrapper.pauseFor(0);
    assertEq(result, LibPause.NOT_PAUSED);
  }

  function test_pauseFor_ReturnsCorrectTimestamp() public {
    uint256 duration = 1000;
    uint40 result = LibPause.pauseFor(duration);
    assertEq(result, uint40(block.timestamp + duration));
  }

  function test_pauseFor_ResultIsPaused() public {
    uint40 pauseState = LibPause.pauseFor(1000);
    assertTrue(pauseState.paused());
  }

  function test_pauseFor_ExpiresAfterDuration() public {
    uint256 duration = 1000;
    uint40 pauseState = LibPause.pauseFor(duration);

    assertTrue(pauseState.paused());

    vm.warp(block.timestamp + duration - 1);
    assertTrue(pauseState.paused());

    vm.warp(block.timestamp + 1);
    assertFalse(pauseState.paused());
  }

  function test_pauseFor_ExactDuration() public {
    uint256 startTime = block.timestamp;
    uint256 duration = 3600;
    uint40 pauseState = LibPause.pauseFor(duration);

    // Paused at T + duration - 1 (last second of pause)
    vm.warp(startTime + duration - 1);
    assertTrue(pauseState.paused(), "Should be paused at T + duration - 1");

    // Not paused at T + duration (exactly duration seconds have elapsed)
    vm.warp(startTime + duration);
    assertFalse(pauseState.paused(), "Should not be paused at T + duration");
  }

  function test_pauseFor_CapsAtPermanentPause() public {
    // Use a value that will overflow uint40 but not cause arithmetic overflow
    uint256 hugeValue = uint256(type(uint40).max) + 1;
    uint40 result = LibPause.pauseFor(hugeValue);
    assertEq(result, LibPause.PERMANENT_PAUSE);
  }

  function test_pauseFor_CapsWhenOverflow() public {
    vm.warp(type(uint40).max - 100);
    uint256 duration = 200;
    uint40 result = LibPause.pauseFor(duration);
    assertEq(result, LibPause.PERMANENT_PAUSE);
  }

  function testFuzz_pauseFor_ReturnsCorrectTimestamp(uint256 duration) public {
    duration = bound(duration, 1, type(uint40).max - block.timestamp);

    uint40 result = LibPause.pauseFor(duration);
    assertEq(result, uint40(block.timestamp + duration));
  }

  function testFuzz_pauseFor_CapsAtPermanentPause(uint256 duration) public {
    // Duration must cause overflow of uint40 but not overflow uint256 addition
    duration = bound(duration, uint256(type(uint40).max) - block.timestamp + 1, type(uint128).max);

    uint40 result = LibPause.pauseFor(duration);
    assertEq(result, LibPause.PERMANENT_PAUSE);
  }

  function testFuzz_pauseFor_ResultIsPaused(uint256 duration) public {
    duration = bound(duration, 1, type(uint128).max);

    uint40 pauseState = LibPause.pauseFor(duration);
    assertTrue(pauseState.paused());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INVARIANT TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_invariant_PausedStateTransitions(uint256 duration, uint256 timeElapsed) public {
    duration = bound(duration, 1, type(uint40).max / 2);
    timeElapsed = bound(timeElapsed, 0, type(uint40).max);

    uint40 pauseState = LibPause.pauseFor(duration);
    uint256 pauseUntil = block.timestamp + duration;

    if (timeElapsed < duration) {
      vm.warp(block.timestamp + timeElapsed);
      assertTrue(pauseState.paused(), "Should be paused within duration");
    } else {
      vm.warp(pauseUntil);
      assertFalse(pauseState.paused(), "Should not be paused after duration");
    }
  }

  function testFuzz_invariant_PauseForNeverExceedsPermanent(uint256 duration, uint256 warpTo) public {
    // Bound warpTo to reasonable values to avoid timestamp overflow
    warpTo = bound(warpTo, 0, type(uint40).max);
    vm.warp(warpTo);

    // Bound duration to avoid arithmetic overflow in the library
    // The library handles overflow by capping, but we need to avoid overflow in the addition
    duration = bound(duration, 1, type(uint40).max);

    uint40 result = LibPause.pauseFor(duration);
    assertLe(result, LibPause.PERMANENT_PAUSE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   EDGE CASE TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_edge_MinDuration() public {
    uint40 result = LibPause.pauseFor(1);
    assertEq(result, uint40(block.timestamp + 1));
    assertTrue(result.paused());
  }

  function test_edge_MaxUint40Duration() public {
    uint40 result = LibPause.pauseFor(type(uint40).max);
    assertEq(result, LibPause.PERMANENT_PAUSE);
  }

  function test_edge_TimestampAtZero() public {
    vm.warp(0);

    uint40 pauseState = LibPause.pauseFor(100);
    assertEq(pauseState, 100);
    assertTrue(pauseState.paused());

    vm.warp(100);
    assertFalse(pauseState.paused());
  }

  function test_edge_TimestampAtMaxUint40() public {
    vm.warp(type(uint40).max);

    // pauseFor with any duration should cap at PERMANENT_PAUSE
    uint40 result = LibPause.pauseFor(1);
    assertEq(result, LibPause.PERMANENT_PAUSE);
  }

  function test_edge_PauseUnpauseCycle() public {
    vm.warp(1); // Ensure block.timestamp > 0

    // Start unpaused
    uint40 state = LibPause.NOT_PAUSED;
    assertFalse(state.paused());

    // Pause permanently
    state = LibPause.PERMANENT_PAUSE;
    assertTrue(state.paused());

    // Unpause
    state = LibPause.NOT_PAUSED;
    assertFalse(state.paused());

    // Pause for duration
    state = LibPause.pauseFor(100);
    assertTrue(state.paused());

    // Wait for expiration
    vm.warp(block.timestamp + 100);
    assertFalse(state.paused());
  }
}
