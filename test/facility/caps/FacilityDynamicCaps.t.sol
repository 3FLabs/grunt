// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test, Vm} from "forge-std/Test.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCapsMath} from "src/libs/common/LibCapsMath.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";

/// @title FacilityDynamicCapsTest
/// @notice Unit tests for the time-weighted FacilityDynamicCaps contract
contract FacilityDynamicCapsTest is Test {
  using LibClone for address;

  FacilityDynamicCaps public caps;
  FacilityDynamicCaps public implementation;

  address owner = makeAddr("owner");
  address manager = makeAddr("manager");
  address consumer = makeAddr("consumer");
  address stranger = makeAddr("stranger");

  uint64 constant ID = 1;
  uint64 constant OTHER_ID = 2;
  uint128 constant RECOVERY = 1_000_000e18;
  uint64 constant RECOVERY_TIME = 24 hours;
  uint256 constant START = 1_700_000_000;

  // Q12.12 multipliers
  int24 constant MULT_1X = 4096;
  int24 constant MULT_1_5X = 6144;
  int24 constant MULT_2X = 8192;

  uint256 constant CAPS_MANAGER_ROLE = 1 << 0;
  uint256 constant CAPS_CONSUMER_ROLE = 1 << 1;

  function setUp() public {
    vm.warp(START);
    implementation = new FacilityDynamicCaps();
    caps = FacilityDynamicCaps(address(implementation).clone());
    address[] memory managers = new address[](1);
    managers[0] = manager;
    address[] memory consumers = new address[](1);
    consumers[0] = consumer;
    caps.initialize(owner, managers, consumers);

    _setCap(RECOVERY, RECOVERY_TIME, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _setCap(uint128 recovery, uint64 recoveryTime, uint64 originTime) internal {
    vm.prank(manager);
    caps.setCap(ID, recovery, recoveryTime, originTime);
  }

  function _consume(uint256 amount, int24 multiplier) internal {
    vm.prank(consumer);
    caps.consume(ID, amount, multiplier);
  }

  function _origin() internal view returns (uint64 originTime) {
    (,, originTime) = caps.getCap(ID);
  }

  /// @dev Largest capacity a single consumption can forfeit through origin rounding.
  function _maxForfeit(uint128 recovery, uint64 recoveryTime) internal pure returns (uint256) {
    return FixedPointMathLib.divUp(recovery, recoveryTime);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_validate_acceptsAnyId() public view {
    caps.validate(0, MULT_1X);
    caps.validate(ID, -MULT_1X);
    caps.validate(type(uint64).max, 0);
  }

  function test_validate_revertOnMinMultiplier() public {
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    caps.validate(ID, type(int24).min);
  }

  function test_initialize_setsOwnerAndRoles() public view {
    assertEq(caps.owner(), owner, "Owner should be set");
    assertTrue(caps.hasAllRoles(manager, CAPS_MANAGER_ROLE), "Manager role should be granted");
    assertTrue(caps.hasAllRoles(consumer, CAPS_CONSUMER_ROLE), "Consumer role should be granted");
    assertFalse(caps.hasAnyRole(manager, CAPS_CONSUMER_ROLE), "Manager should not consume");
    assertFalse(caps.hasAnyRole(consumer, CAPS_MANAGER_ROLE), "Consumer should not manage");
  }

  function test_initialize_revertOnReinit() public {
    address[] memory none = new address[](0);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    caps.initialize(owner, none, none);
  }

  function test_initialize_revertOnZeroOwner() public {
    FacilityDynamicCaps fresh = FacilityDynamicCaps(address(implementation).clone());
    address[] memory none = new address[](0);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    fresh.initialize(address(0), none, none);
  }

  function test_initialize_revertOnImplementation() public {
    address[] memory none = new address[](0);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    implementation.initialize(owner, none, none);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           SET CAP                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setCap_storesAndEmits() public {
    vm.expectEmit(true, true, true, true, address(caps));
    emit FacilityDynamicCaps.CapSet(OTHER_ID, 5e18, 1 hours, uint64(START - 10));
    vm.prank(manager);
    caps.setCap(OTHER_ID, 5e18, 1 hours, uint64(START - 10));

    (uint128 recovery, uint64 recoveryTime, uint64 originTime) = caps.getCap(OTHER_ID);
    assertEq(recovery, 5e18, "Recovery should be stored");
    assertEq(recoveryTime, 1 hours, "Recovery time should be stored");
    assertEq(originTime, START - 10, "Origin should be stored");
  }

  function test_setCap_writesPrecomputedSlot() public {
    vm.prank(manager);
    caps.setCap(OTHER_ID, 5e18, 1 hours, uint64(START - 10));

    bytes32 base = keccak256("facility.dynamic.caps.storage");
    bytes32 slot = keccak256(abi.encode(uint256(OTHER_ID), base));
    uint256 packed = uint256(5e18) | (uint256(1 hours) << 128) | (uint256(START - 10) << 192);
    assertEq(vm.load(address(caps), slot), bytes32(packed), "Cap data should live at the precomputed slot");
  }

  function test_setCap_revertOnZeroRecoveryTime() public {
    vm.prank(manager);
    vm.expectRevert(FacilityDynamicCaps.InvalidRecoveryTime.selector);
    caps.setCap(ID, RECOVERY, 0, 0);
  }

  function test_setCap_revertOnUnauthorized() public {
    vm.prank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.setCap(ID, RECOVERY, RECOVERY_TIME, 0);

    // the consumer role does not manage
    vm.prank(consumer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.setCap(ID, RECOVERY, RECOVERY_TIME, 0);

    // the owner does not manage without the role either
    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.setCap(ID, RECOVERY, RECOVERY_TIME, 0);
  }

  function test_setCap_overwritesConsumedState() public {
    _consume(600_000e18, MULT_1X);
    assertEq(caps.remaining(ID), 400_000e18, "Consumption should apply");

    _setCap(RECOVERY, RECOVERY_TIME, 0);
    assertEq(caps.remaining(ID), RECOVERY, "Set cap should reset the curve");
  }

  function test_setCap_zeroRecoveryClosesCap() public {
    _setCap(0, RECOVERY_TIME, 0);
    assertEq(caps.remaining(ID), 0, "Closed cap should have no capacity");
    assertEq(caps.available(ID, MULT_1X), 0, "Closed cap should quote zero");

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, 1, MULT_1X);

    // a zero consumption is a no-op
    _consume(0, MULT_1X);
    assertEq(_origin(), 0, "Zero consumption should not touch the origin");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          REMAINING                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_remaining_unsetIdIsZero() public view {
    assertEq(caps.remaining(OTHER_ID), 0, "Unset cap should have no capacity");
    assertEq(caps.available(OTHER_ID, MULT_1X), 0, "Unset cap should quote zero");
  }

  function test_remaining_zeroOriginIsFull() public view {
    assertEq(caps.remaining(ID), RECOVERY, "Zero origin should be fully recovered");
  }

  function test_remaining_atOriginIsZero() public {
    _setCap(RECOVERY, RECOVERY_TIME, uint64(START));
    assertEq(caps.remaining(ID), 0, "Capacity should be zero at the origin");
  }

  function test_remaining_futureOriginIsZero() public {
    _setCap(RECOVERY, RECOVERY_TIME, uint64(START + 1 hours));
    assertEq(caps.remaining(ID), 0, "Capacity should be zero before the origin");

    vm.warp(START + 1 hours + 6 hours);
    assertEq(caps.remaining(ID), RECOVERY / 4, "Capacity should recover from the future origin");
  }

  function test_remaining_linearThenFlat() public {
    _setCap(RECOVERY, RECOVERY_TIME, uint64(START));

    vm.warp(START + 6 hours);
    assertEq(caps.remaining(ID), RECOVERY / 4, "Quarter time should give a quarter capacity");

    vm.warp(START + 12 hours);
    assertEq(caps.remaining(ID), RECOVERY / 2, "Half time should give half capacity");

    vm.warp(START + 24 hours);
    assertEq(caps.remaining(ID), RECOVERY, "Full time should give full capacity");

    vm.warp(START + 10 days);
    assertEq(caps.remaining(ID), RECOVERY, "Capacity should not exceed recovery");
  }

  function test_remaining_roundsDown() public {
    _setCap(10, 3, uint64(START));
    vm.warp(START + 1);
    assertEq(caps.remaining(ID), 3, "10 * 1 / 3 should round down to 3");
    vm.warp(START + 2);
    assertEq(caps.remaining(ID), 6, "10 * 2 / 3 should round down to 6");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          AVAILABLE                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_available_dividesByMultiplier() public view {
    assertEq(caps.available(ID, MULT_1X), RECOVERY, "1x should quote the full capacity");
    assertEq(caps.available(ID, MULT_2X), RECOVERY / 2, "2x should quote half");
    assertEq(caps.available(ID, MULT_1_5X), uint256(RECOVERY) * 2 / 3, "1.5x should quote two thirds");
  }

  function test_available_unboundedForZeroOrNegative() public view {
    assertEq(caps.available(ID, 0), type(uint256).max, "Zero multiplier should be unbounded");
    assertEq(caps.available(ID, -MULT_1X), type(uint256).max, "Negative multiplier should be unbounded");
    assertEq(caps.available(OTHER_ID, -MULT_1X), type(uint256).max, "Unset cap should still be unbounded");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           CONSUME                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_movesOriginToRemaining() public {
    // 1m per 24h with 500k consumed: the origin sits 12h in the past
    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(ID, 500_000e18, MULT_1X, 500_000e18);
    _consume(500_000e18, MULT_1X);

    assertEq(_origin(), START - 12 hours, "Origin should move to now minus 12h");
    assertEq(caps.remaining(ID), 500_000e18, "Half the capacity should remain");

    (uint128 recovery, uint64 recoveryTime,) = caps.getCap(ID);
    assertEq(recovery, RECOVERY, "Recovery should not change");
    assertEq(recoveryTime, RECOVERY_TIME, "Recovery time should not change");
  }

  function test_consume_appliesMultiplier() public {
    // 400k at 1.5x consumes 600k, leaving 400k: origin 9.6h in the past
    _consume(400_000e18, MULT_1_5X);
    assertEq(caps.remaining(ID), 400_000e18, "Consumption should be amount x multiplier");
    assertEq(_origin(), START - 9 hours - 36 minutes, "Origin should reflect the remaining capacity");
  }

  function test_consume_roundsConsumptionUp() public {
    _setCap(10, RECOVERY_TIME, 0);
    // 1 wei at 1.5x rounds up to 2
    _consume(1, MULT_1_5X);
    assertLe(caps.remaining(ID), 8, "Consumption should round up against the cap");
  }

  function test_consume_allPinsOriginToNow() public {
    _consume(RECOVERY, MULT_1X);
    assertEq(_origin(), START, "Origin should be now once empty");
    assertEq(caps.remaining(ID), 0, "Nothing should remain");

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, 1, MULT_1X);
  }

  function test_consume_revertOnInsufficientCap() public {
    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, RECOVERY + 1, MULT_1X);

    // 2x halves what can be consumed
    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, RECOVERY / 2 + 1, MULT_2X);

    assertEq(_origin(), 0, "Failed consumption should not touch the origin");
  }

  function test_consume_revertOnUnauthorized() public {
    vm.prank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.consume(ID, 1, MULT_1X);

    vm.prank(manager);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.consume(ID, 1, MULT_1X);

    // gating applies before the no-op shortcut
    vm.prank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.consume(ID, 1, -MULT_1X);
  }

  function test_consume_unsetIdRevertsUnlessZero() public {
    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, OTHER_ID));
    caps.consume(OTHER_ID, 1, MULT_1X);

    vm.recordLogs();
    vm.prank(consumer);
    caps.consume(OTHER_ID, 0, MULT_1X);
    assertEq(vm.getRecordedLogs().length, 0, "Zero consumption should not emit");
    (,, uint64 originTime) = caps.getCap(OTHER_ID);
    assertEq(originTime, 0, "Zero consumption should not touch an unset cap");
  }

  function test_consume_zeroConsumptionKeepsFutureOrigin() public {
    _setCap(RECOVERY, RECOVERY_TIME, uint64(START + 7 days));

    vm.recordLogs();
    _consume(0, MULT_1X);
    assertEq(vm.getRecordedLogs().length, 0, "Zero consumption should not emit");
    assertEq(_origin(), START + 7 days, "Zero consumption should not cancel a future origin");
    assertEq(caps.remaining(ID), 0, "Cap should stay locked");

    // the origin never moves backwards once consumption starts either
    vm.warp(START + 7 days + 12 hours);
    _consume(1, MULT_1X);
    assertGe(_origin(), START + 7 days, "Origin should never move backwards");
  }

  function test_consume_zeroOrNegativeMultiplierIsNoop() public {
    _consume(500_000e18, MULT_1X);
    uint64 originBefore = _origin();

    vm.recordLogs();
    _consume(type(uint256).max, -MULT_1X);
    _consume(type(uint256).max, 0);
    _consume(1, type(int24).min);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    assertEq(logs.length, 0, "No-op consumption should not emit");
    assertEq(_origin(), originBefore, "No-op consumption should not move the origin");
    assertEq(caps.remaining(ID), 500_000e18, "No-op consumption should not change the capacity");
  }

  function test_consume_recoversAfterConsumption() public {
    _consume(RECOVERY, MULT_1X);

    vm.warp(START + 6 hours);
    assertEq(caps.remaining(ID), RECOVERY / 4, "Quarter of the capacity should recover in 6h");

    vm.warp(START + 24 hours);
    assertEq(caps.remaining(ID), RECOVERY, "Full capacity should recover in 24h");

    _consume(RECOVERY, MULT_1X);
    assertEq(_origin(), START + 24 hours, "Origin should follow the second consumption");
  }

  function test_consume_sequenceAcrossTime() public {
    _consume(300_000e18, MULT_1X);
    assertEq(caps.remaining(ID), 700_000e18, "First consumption should apply");

    // 6h recovers 250k, capped at 1m
    vm.warp(START + 6 hours);
    assertEq(caps.remaining(ID), 950_000e18, "Capacity should recover between consumptions");

    _consume(950_000e18, MULT_1X);
    assertEq(caps.remaining(ID), 0, "Second consumption should empty the cap");
    assertEq(_origin(), START + 6 hours, "Origin should be now once empty");

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, 1, MULT_1X);

    vm.warp(START + 6 hours + 1 hours);
    _consume(RECOVERY / 24, MULT_1X);
    assertEq(caps.remaining(ID), 0, "One hour of recovery should be consumable");
  }

  function test_consume_futureOrigin() public {
    _setCap(RECOVERY, RECOVERY_TIME, uint64(START + 1 hours));
    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, 1, MULT_1X);

    vm.warp(START + 1 hours + 12 hours);
    _consume(RECOVERY / 2, MULT_1X);
    assertEq(caps.remaining(ID), 0, "Half a day of recovery should be consumable");
    assertEq(_origin(), START + 13 hours, "Origin should be now once empty");
  }

  function test_consume_idsAreIndependent() public {
    vm.prank(manager);
    caps.setCap(OTHER_ID, 10e18, 1 hours, 0);

    _consume(RECOVERY, MULT_1X);
    assertEq(caps.remaining(ID), 0, "First cap should be consumed");
    assertEq(caps.remaining(OTHER_ID), 10e18, "Second cap should be untouched");

    vm.prank(consumer);
    caps.consume(OTHER_ID, 4e18, MULT_1X);
    assertEq(caps.remaining(OTHER_ID), 6e18, "Second cap should be consumed");
    assertEq(caps.remaining(ID), 0, "First cap should be untouched");
  }

  function test_consume_forfeitsAtMostOneSecondOfRecovery() public {
    // 1e18 per day, so one second of recovery is about 1.16e13
    _setCap(1e18, 1 days, 0);
    _consume(1, MULT_1X);
    uint256 left = caps.remaining(ID);
    assertLe(left, 1e18 - 1, "Rounding should favor the cap");
    assertGe(left, 1e18 - 1 - _maxForfeit(1e18, 1 days), "Rounding should forfeit at most one second");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            FUZZ                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_remaining_matchesCurve(uint128 recovery, uint64 recoveryTime, uint64 originTime, uint64 now_)
    public
  {
    recoveryTime = uint64(bound(recoveryTime, 1, type(uint64).max));
    _setCap(recovery, recoveryTime, originTime);
    vm.warp(now_);

    uint256 expected;
    if (now_ > originTime) {
      uint256 elapsed = now_ - originTime;
      expected = elapsed >= recoveryTime ? recovery : FixedPointMathLib.mulDiv(recovery, elapsed, recoveryTime);
    }
    assertEq(caps.remaining(ID), expected, "Remaining should follow the curve");
    assertLe(caps.remaining(ID), recovery, "Remaining should never exceed recovery");
  }

  function testFuzz_consume_roundsInFavorOfCap(
    uint128 recovery,
    uint64 recoveryTime,
    uint64 originShift,
    uint256 amount,
    int24 multiplier
  ) public {
    recoveryTime = uint64(bound(recoveryTime, 1, 100 * 365 days));
    multiplier = int24(bound(multiplier, 1, type(int24).max));
    originShift = uint64(bound(originShift, 0, START));
    _setCap(recovery, recoveryTime, uint64(START - originShift));

    uint256 current = caps.remaining(ID);
    amount = bound(amount, 0, LibCapsMath.depositable(current, multiplier));
    uint256 consumption = LibCapsMath.consumption(amount, multiplier);

    _consume(amount, multiplier);

    uint256 left = current - consumption;
    uint256 after_ = caps.remaining(ID);
    assertLe(after_, left, "Remaining should never exceed the exact difference");
    assertGe(after_ + _maxForfeit(recovery, recoveryTime), left, "Rounding should forfeit at most one second");
    assertLe(_origin(), START, "Origin should never be in the future after a consumption");
    assertGe(_origin(), START - originShift, "Origin should never move backwards");
  }

  function testFuzz_consume_quoteIsConsumableAndTight(
    uint128 recovery,
    uint64 recoveryTime,
    uint64 originShift,
    int24 multiplier
  ) public {
    recoveryTime = uint64(bound(recoveryTime, 1, 100 * 365 days));
    multiplier = int24(bound(multiplier, 1, type(int24).max));
    originShift = uint64(bound(originShift, 0, START));
    _setCap(recovery, recoveryTime, uint64(START - originShift));

    uint256 quote = caps.available(ID, multiplier);
    uint256 current = caps.remaining(ID);

    // one more than the quote does not fit
    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, quote + 1, multiplier);

    // the quote itself always fits
    _consume(quote, multiplier);
    assertLe(caps.remaining(ID), current - LibCapsMath.consumption(quote, multiplier), "Quote should be consumable");
  }

  function testFuzz_consume_noopForZeroOrNegative(uint256 amount, int24 multiplier, uint64 originShift) public {
    multiplier = int24(bound(multiplier, type(int24).min, 0));
    originShift = uint64(bound(originShift, 0, START));
    _setCap(RECOVERY, RECOVERY_TIME, uint64(START - originShift));

    uint256 before = caps.remaining(ID);
    vm.recordLogs();
    _consume(amount, multiplier);
    assertEq(vm.getRecordedLogs().length, 0, "No-op consumption should not emit");
    assertEq(caps.remaining(ID), before, "No-op consumption should not change the capacity");
    assertEq(_origin(), START - originShift, "No-op consumption should not move the origin");
  }

  /// @dev Total throughput over any window is bounded by the starting capacity plus the recovery
  ///      accrued over the window, whatever the sequence of consumptions and waits.
  function testFuzz_consume_throughputIsBounded(uint128 recovery, uint64 recoveryTime, uint256 seed) public {
    recoveryTime = uint64(bound(recoveryTime, 1, 30 days));
    _setCap(recovery, recoveryTime, 0);

    uint256 consumed;
    uint256 elapsed;
    uint256 start = caps.remaining(ID);
    for (uint256 i = 0; i < 16; i++) {
      uint256 r = uint256(keccak256(abi.encode(seed, i)));
      uint256 wait = r % (2 * uint256(recoveryTime));
      vm.warp(block.timestamp + wait);
      elapsed += wait;

      uint256 current = caps.remaining(ID);
      assertLe(current, recovery, "Remaining should never exceed recovery");
      uint256 amount = (r >> 128) % (current + 1);
      _consume(amount, MULT_1X);
      consumed += amount;
    }

    uint256 accrued = FixedPointMathLib.mulDivUp(recovery, elapsed, recoveryTime);
    assertLe(consumed, start + accrued, "Throughput should be bounded by the recovery rate");
  }
}
