// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityBaseTest} from "./FacilityBase.t.sol";

import {Vm} from "forge-std/Vm.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";

/// @title FacilitySharedCapsFuzzTest
/// @notice Fuzzed facility flows on EXTERNAL words pointing at FacilityAbsoluteCaps pools
contract FacilitySharedCapsFuzzTest is FacilityBaseTest {
  using LibClone for address;

  FacilityAbsoluteCaps public caps;

  uint16 constant POOL_ID = 1;
  uint16 constant OTHER_POOL_ID = 2;
  uint64 constant TWO_POOLS = uint64(POOL_ID) | (uint64(OTHER_POOL_ID) << 16);
  uint256 constant ONE = 4096;
  uint256 constant MAX_AMOUNT = 1e30;
  uint256 constant MAX_CHUNKS = 6;
  uint256 constant BIG = type(uint128).max / 2;

  struct RoundTrip {
    uint256 amount;
    int256 multiplier;
    bool integer;
    bool twoPools;
    uint256 depositCount;
    uint256 releaseCount;
    uint256 seed;
    uint256 cap;
    uint256 headroom;
    bool revertTail;
    bool resolving;
  }

  function setUp() public override {
    super.setUp();

    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    caps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    caps.initialize(owner, managers, consumers);

    vm.prank(owner);
    capsWhitelist.setAllowed(address(caps), true);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _abs(int24 multiplier) internal pure returns (uint256) {
    return uint256(multiplier < 0 ? -int256(multiplier) : int256(multiplier));
  }

  function _up(uint256 amount, int24 multiplier) internal pure returns (uint256) {
    uint256 product = amount * _abs(multiplier);
    return product / ONE + (product % ONE == 0 ? 0 : 1);
  }

  function _down(uint256 amount, int24 multiplier) internal pure returns (uint256) {
    return amount * _abs(multiplier) / ONE;
  }

  /// @dev Capacity moved by `amount` at `multiplier`: rounded up to consume, down to release
  function _charge(uint256 amount, int24 multiplier) internal pure returns (uint256) {
    return multiplier < 0 ? _down(amount, multiplier) : _up(amount, multiplier);
  }

  function _signed(int256 raw, bool negative) internal pure returns (int24 multiplier) {
    multiplier = int24(bound(raw, 1, type(int24).max));
    if (negative) multiplier = -multiplier;
  }

  function _capId(bool twoPools) internal pure returns (uint64) {
    return twoPools ? TWO_POOLS : POOL_ID;
  }

  function _setPool(uint16 poolId, uint256 cap, uint256 hardCap) internal {
    vm.prank(owner);
    caps.setCap(poolId, uint128(cap), uint128(hardCap));
  }

  /// @dev Spreads `cap` and `headroom` over the layout's pools
  function _setPools(bool twoPools, uint256 cap, uint256 headroom, uint256 seed) internal {
    uint256 cap1 = twoPools ? bound(seed, 0, cap) : cap;
    uint256 room1 = twoPools ? bound(uint256(keccak256(abi.encode(seed))), 0, headroom) : headroom;
    _setPool(POOL_ID, cap1, cap1 + room1);
    if (twoPools) _setPool(OTHER_POOL_ID, cap - cap1, cap - cap1 + headroom - room1);
  }

  /// @dev Pools for the event tests: the first one takes `firstRoom` of the charge, the second the rest
  function _setEventPools(bool twoPools, bool negative, uint256 firstRoom) internal {
    if (!twoPools) return _setPool(POOL_ID, negative ? 1 : BIG, BIG);
    _setPool(POOL_ID, negative ? 0 : firstRoom, firstRoom);
    _setPool(OTHER_POOL_ID, negative ? 1 : BIG, BIG);
  }

  function _poolTotal() internal view returns (uint256) {
    (uint128 cap1,) = caps.getCap(POOL_ID);
    (uint128 cap2,) = caps.getCap(OTHER_POOL_ID);
    return uint256(cap1) + cap2;
  }

  /// @dev Pool total after moving `amount` at `multiplier` (consume if positive, release if negative)
  function _after(uint256 before, uint256 amount, int24 multiplier) internal pure returns (uint256) {
    return multiplier < 0 ? before + _down(amount, multiplier) : before - _up(amount, multiplier);
  }

  function _createIntent(uint64 capId, int24 multiplier) internal returns (uint256 intentId, uint256 word) {
    word = LibCaps.encodeExternal(address(caps), capId, multiplier);
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositCap = word;
    vm.prank(owner);
    intentId = facility.createIntent(props);
  }

  function _deposit(uint256 intentId, address depositor, uint256 amount) internal {
    _mintDebt(depositor, amount);
    vm.prank(depositor);
    facility.deposit(intentId, amount);
  }

  function _resolveStart(uint256 intentId) internal view returns (uint40) {
    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    return props.resolveStart;
  }

  /// @dev Splits `total` into 1 to MAX_CHUNKS non-zero parts
  function _chunks(uint256 total, uint256 count, uint256 seed) internal pure returns (uint256[] memory parts) {
    count = bound(count, 1, total < MAX_CHUNKS ? total : MAX_CHUNKS);
    parts = new uint256[](count);
    uint256 left = total;
    for (uint256 i = 0; i + 1 < count; i++) {
      parts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, left - (count - 1 - i));
      left -= parts[i];
    }
    parts[count - 1] = left;
  }

  /// @dev Queues the CapConsumed events of `amount` at `multiplier`, walking the pools from id1, and
  ///      starts recording logs for _capConsumedCount
  function _expectCapConsumed(bool twoPools, uint256 amount, int24 multiplier) internal returns (uint256 count) {
    uint16[2] memory poolIds = [POOL_ID, OTHER_POOL_ID];
    uint256[2] memory moved;
    uint256[2] memory newCaps;
    uint256 left = _charge(amount, multiplier);
    for (uint256 i = 0; i < (twoPools ? 2 : 1); i++) {
      (uint128 cap, uint128 hardCap) = caps.getCap(poolIds[i]);
      uint256 room = multiplier < 0 ? hardCap - cap : cap;
      moved[i] = left < room ? left : room;
      newCaps[i] = multiplier < 0 ? cap + moved[i] : cap - moved[i];
      left -= moved[i];
    }
    assertEq(left, 0, "Pools should absorb the charge");
    for (uint256 i = 0; i < 2; i++) {
      if (moved[i] == 0) continue;
      count++;
      vm.expectEmit(true, true, true, true, address(caps));
      emit IFacilityCaps.CapConsumed(poolIds[i], amount, multiplier, moved[i], uint128(newCaps[i]));
    }
    vm.recordLogs();
  }

  function _capConsumedCount() internal returns (uint256 count) {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(caps) && logs[i].topics[0] == IFacilityCaps.CapConsumed.selector) count++;
    }
  }

  /// @dev Deposits `p.amount` in chunks, then withdraws it in chunks with an optional revertDeposit tail
  function _roundTrip(RoundTrip memory p, int24 multiplier) internal {
    p.amount = bound(p.amount, 1, MAX_AMOUNT);
    uint256[] memory deposits = _chunks(p.amount, p.depositCount, p.seed);
    uint256 tail = p.revertTail ? bound(uint256(keccak256(abi.encode(p.seed, "tail"))), 1, p.amount) : 0;
    uint256[] memory withdrawals =
      p.amount > tail ? _chunks(p.amount - tail, p.releaseCount, p.seed >> 1) : new uint256[](0);
    uint256 ops = deposits.length + withdrawals.length + (tail > 0 ? 1 : 0);

    uint256 depositCharge;
    for (uint256 i = 0; i < deposits.length; i++) {
      depositCharge += _charge(deposits[i], multiplier);
    }
    // positive: full pools that absorb every deposit, negative: room for every deposit and the rounding of the exits
    if (multiplier > 0) _setPools(p.twoPools, bound(p.cap, depositCharge, BIG), 0, p.seed);
    else _setPools(p.twoPools, bound(p.cap, ops, BIG), bound(p.headroom, depositCharge, BIG), p.seed);

    (uint256 intentId, uint256 word) = _createIntent(_capId(p.twoPools), multiplier);
    uint256 start = _poolTotal();

    for (uint256 i = 0; i < deposits.length; i++) {
      uint256 before = _poolTotal();
      _deposit(intentId, user, deposits[i]);
      assertEq(_poolTotal(), _after(before, deposits[i], multiplier), "Deposit should move the rounded charge");
    }
    for (uint256 i = 0; i < withdrawals.length; i++) {
      uint256 before = _poolTotal();
      vm.prank(user);
      facility.withdraw(intentId, user, user, withdrawals[i]);
      assertEq(_poolTotal(), _after(before, withdrawals[i], -multiplier), "Withdrawal should move the rounded charge");
    }
    if (tail > 0) {
      if (p.resolving) vm.warp(_resolveStart(intentId));
      uint256 before = _poolTotal();
      vm.prank(pauser);
      facility.revertDeposit(intentId, user, user);
      assertEq(_poolTotal(), _after(before, tail, -multiplier), "Reverted deposit should move the rounded charge");
    }

    uint256 end = _poolTotal();
    assertLe(end, start, "Round trip should not create capacity");
    assertLt(start - end, ops, "Dust should stay below one unit per operation");
    if (_abs(multiplier) % ONE == 0) assertEq(end, start, "Integer multipliers should round trip exactly");
    assertEq(debtToken.balanceOf(user), p.amount, "Depositor should get the full deposit back");
    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.depositCap, word, "Flows should not write an EXTERNAL word");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ROUND TRIPS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_roundTrip_positiveMultiplier(RoundTrip memory p) public {
    int24 multiplier = p.integer
      ? int24(bound(p.multiplier, 1, 2047)) * int24(int256(ONE))
      : int24(bound(p.multiplier, 1, type(int24).max));
    _roundTrip(p, multiplier);
  }

  function testFuzz_roundTrip_negativeMultiplier(RoundTrip memory p) public {
    int24 multiplier = p.integer
      ? int24(bound(p.multiplier, 1, 2047)) * int24(int256(ONE))
      : int24(bound(p.multiplier, 1, type(int24).max));
    _roundTrip(p, -multiplier);
  }

  function test_createIntent_revertOnZeroMultiplier() public {
    // a zero multiplier would leave the intent uncapped: MAX_ABSOLUTE is the way to say no cap
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositCap = LibCaps.encodeExternal(address(caps), POOL_ID, 0);
    vm.prank(owner);
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    facility.createIntent(props);
  }

  function test_withdraw_negativeFractional_revertOnRoundingDust() public {
    _setPool(POOL_ID, 0, 5000e18);
    (uint256 intentId,) = _createIntent(POOL_ID, -6144);

    _deposit(intentId, user, 1);
    (uint128 cap,) = caps.getCap(POOL_ID);
    assertEq(cap, 1, "1 wei at -1.5x should release 1");

    // withdrawing it consumes 2
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.withdraw(intentId, user, user, 1);
  }

  function testFuzz_deposit_availableIsExactBound(uint256 cap, uint256 seed, int256 rawMultiplier, bool twoPools)
    public
  {
    int24 multiplier = _signed(rawMultiplier, false);
    cap = bound(cap, 0, MAX_AMOUNT);
    _setPools(twoPools, cap, 0, seed);
    uint64 capId = _capId(twoPools);
    (uint256 intentId,) = _createIntent(capId, multiplier);

    uint256 available = caps.available(capId, multiplier);
    assertEq(available, cap * ONE / _abs(multiplier), "Quote should be the floored depositable amount");

    _mintDebt(user, available + 1);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, capId));
    facility.deposit(intentId, available + 1);

    if (available == 0) return;
    vm.prank(user);
    facility.deposit(intentId, available);
    assertEq(_poolTotal(), cap - _up(available, multiplier), "Quoted deposit should consume its rounded charge");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_skipsPoolWithoutRoom() public {
    _setPool(POOL_ID, 0, 1000e18);
    _setPool(OTHER_POOL_ID, 5000e18, 5000e18);
    (uint256 intentId,) = _createIntent(TWO_POOLS, 6144);
    _mintDebt(user, 1000e18);

    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(OTHER_POOL_ID, 1000e18, 6144, 1500e18, 3500e18);
    vm.recordLogs();
    vm.prank(user);
    facility.deposit(intentId, 1000e18);
    assertEq(_capConsumedCount(), 1, "Drained first pool should not emit");
  }

  function testFuzz_deposit_emitsCapConsumed(
    uint256 amount,
    int256 rawMultiplier,
    bool negative,
    bool twoPools,
    uint256 firstRoom
  ) public {
    int24 multiplier = _signed(rawMultiplier, negative);
    amount = bound(amount, 1, MAX_AMOUNT);
    _setEventPools(twoPools, negative, bound(firstRoom, 0, _charge(amount, multiplier)));
    (uint256 intentId,) = _createIntent(_capId(twoPools), multiplier);
    _mintDebt(user, amount);

    uint256 count = _expectCapConsumed(twoPools, amount, multiplier);
    vm.prank(user);
    facility.deposit(intentId, amount);
    assertEq(_capConsumedCount(), count, "Only pools that moved should emit");
  }

  function testFuzz_withdraw_emitsCapConsumed(
    uint256 amount,
    uint256 withdrawn,
    int256 rawMultiplier,
    bool negative,
    bool twoPools,
    uint256 firstRoom
  ) public {
    int24 multiplier = _signed(rawMultiplier, negative);
    amount = bound(amount, 1, MAX_AMOUNT);
    withdrawn = bound(withdrawn, 1, amount);
    _setEventPools(twoPools, negative, bound(firstRoom, 0, _charge(amount, multiplier)));
    (uint256 intentId,) = _createIntent(_capId(twoPools), multiplier);
    _deposit(intentId, user, amount);

    uint256 count = _expectCapConsumed(twoPools, withdrawn, -multiplier);
    vm.prank(user);
    facility.withdraw(intentId, user, user, withdrawn);
    assertEq(_capConsumedCount(), count, "Only pools that moved should emit");
  }

  function testFuzz_revertDeposit_emitsCapConsumed(
    uint256 amount,
    int256 rawMultiplier,
    bool negative,
    bool twoPools,
    uint256 firstRoom,
    bool resolving
  ) public {
    int24 multiplier = _signed(rawMultiplier, negative);
    amount = bound(amount, 1, MAX_AMOUNT);
    _setEventPools(twoPools, negative, bound(firstRoom, 0, _charge(amount, multiplier)));
    (uint256 intentId,) = _createIntent(_capId(twoPools), multiplier);
    _deposit(intentId, user, amount);
    if (resolving) vm.warp(_resolveStart(intentId));

    uint256 count = _expectCapConsumed(twoPools, amount, -multiplier);
    vm.prank(pauser);
    facility.revertDeposit(intentId, user, user);
    assertEq(_capConsumedCount(), count, "Only pools that moved should emit");
  }
}
