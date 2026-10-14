// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCapsMath} from "src/libs/common/LibCapsMath.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";

/// @title FacilityAbsoluteCapsTest
/// @notice Unit tests for the shared pool FacilityAbsoluteCaps contract
contract FacilityAbsoluteCapsTest is Test {
  using LibClone for address;

  FacilityAbsoluteCaps public caps;
  FacilityAbsoluteCaps public implementation;

  address owner = makeAddr("owner");
  address manager = makeAddr("manager");
  address consumer = makeAddr("consumer");
  address stranger = makeAddr("stranger");

  uint16 constant ID = 1;
  uint16 constant OTHER_ID = 2;
  uint16 constant THIRD_ID = 3;
  uint128 constant HARD_CAP = 10_000e18;

  // Q12.12 multipliers
  int24 constant MULT_1X = 4096;
  int24 constant MULT_1_5X = 6144;
  int24 constant MULT_2X = 8192;

  uint256 constant CAPS_MANAGER_ROLE = 1 << 0;
  uint256 constant CAPS_CONSUMER_ROLE = 1 << 1;

  function setUp() public {
    implementation = new FacilityAbsoluteCaps();
    caps = FacilityAbsoluteCaps(address(implementation).clone());
    address[] memory managers = new address[](1);
    managers[0] = manager;
    address[] memory consumers = new address[](1);
    consumers[0] = consumer;
    caps.initialize(owner, managers, consumers);

    _setCap(HARD_CAP, HARD_CAP);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _setCap(uint128 cap, uint128 hardCap) internal {
    vm.prank(manager);
    caps.setCap(ID, cap, hardCap);
  }

  function _consume(uint256 amount, int24 multiplier) internal {
    vm.prank(consumer);
    caps.consume(ID, amount, multiplier);
  }

  function _cap() internal view returns (uint128 cap) {
    (cap,) = caps.getCap(ID);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
    FacilityAbsoluteCaps fresh = FacilityAbsoluteCaps(address(implementation).clone());
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
    emit FacilityAbsoluteCaps.CapSet(OTHER_ID, 3e18, 5e18);
    vm.prank(manager);
    caps.setCap(OTHER_ID, 3e18, 5e18);

    (uint128 cap, uint128 hardCap) = caps.getCap(OTHER_ID);
    assertEq(cap, 3e18, "Cap should be stored");
    assertEq(hardCap, 5e18, "Hard cap should be stored");
  }

  function test_setCap_writesPrecomputedSlot() public {
    vm.prank(manager);
    caps.setCap(OTHER_ID, 3e18, 5e18);

    bytes32 base = keccak256("facility.caps.storage");
    bytes32 slot = keccak256(abi.encode(uint256(OTHER_ID), base));
    uint256 packed = uint256(3e18) | (uint256(5e18) << 128);
    assertEq(vm.load(address(caps), slot), bytes32(packed), "Cap data should live at the precomputed slot");
  }

  function test_setCap_revertOnCapAboveHardCap() public {
    vm.prank(manager);
    vm.expectRevert(FacilityAbsoluteCaps.CapAboveHardCap.selector);
    caps.setCap(ID, HARD_CAP + 1, HARD_CAP);
  }

  function test_setCap_revertOnZeroId() public {
    vm.prank(manager);
    vm.expectRevert(FacilityAbsoluteCaps.InvalidCapId.selector);
    caps.setCap(0, HARD_CAP, HARD_CAP);
  }

  function test_setCap_revertOnUnauthorized() public {
    vm.prank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.setCap(ID, HARD_CAP, HARD_CAP);

    vm.prank(consumer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.setCap(ID, HARD_CAP, HARD_CAP);

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.setCap(ID, HARD_CAP, HARD_CAP);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          AVAILABLE                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_available_positiveDividesCap() public {
    _setCap(3000e18, HARD_CAP);
    assertEq(caps.available(ID, MULT_1X), 3000e18, "1x should quote the cap");
    assertEq(caps.available(ID, MULT_2X), 1500e18, "2x should quote half the cap");
    assertEq(caps.available(ID, MULT_1_5X), 2000e18, "1.5x should quote two thirds of the cap");
    assertEq(caps.available(ID, 0), type(uint256).max, "Zero multiplier should be unbounded");
  }

  function test_available_negativeDividesHeadroom() public {
    _setCap(3000e18, HARD_CAP);
    assertEq(caps.available(ID, -MULT_1X), 7000e18, "-1x should quote the headroom");
    assertEq(caps.available(ID, -MULT_2X), 3500e18, "-2x should quote half the headroom");
    assertEq(caps.available(OTHER_ID, -MULT_1X), 0, "Unset cap should have no headroom");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           CONSUME                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_positiveDecrementsAndEmits() public {
    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(ID, 1000e18, MULT_1_5X, HARD_CAP - 1500e18);
    _consume(1000e18, MULT_1_5X);
    assertEq(_cap(), HARD_CAP - 1500e18, "Cap should shrink by amount x multiplier");

    // 1 wei x 1.5 rounds up to 2
    _consume(1, MULT_1_5X);
    assertEq(_cap(), HARD_CAP - 1500e18 - 2, "Consumption should round up");
  }

  function test_consume_zeroMultiplierKeepsCap() public {
    vm.recordLogs();
    _consume(1000e18, 0);
    assertEq(vm.getRecordedLogs().length, 0, "Nothing consumed should emit nothing");
    assertEq(_cap(), HARD_CAP, "Zero multiplier should consume nothing");
  }

  function test_consume_revertOnInsufficientCap() public {
    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, HARD_CAP + 1, MULT_1X);

    _consume(HARD_CAP, MULT_1X);
    assertEq(_cap(), 0, "Cap should be fully consumed");

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
    caps.consume(ID, 1, MULT_1X);
  }

  function test_consume_negativeReleasesAndEmits() public {
    _setCap(0, HARD_CAP);

    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(ID, 1000e18, -MULT_1_5X, 1500e18);
    _consume(1000e18, -MULT_1_5X);
    assertEq(_cap(), 1500e18, "Cap should grow by amount x |multiplier|");

    // 1 wei x 1.5 rounds down to 1
    _consume(1, -MULT_1_5X);
    assertEq(_cap(), 1500e18 + 1, "Release should round down");
  }

  function test_consume_revertOnHardCapExceeded() public {
    _setCap(HARD_CAP - 1000e18, HARD_CAP);

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, ID));
    caps.consume(ID, 1000e18 + 1, -MULT_1X);

    _consume(1000e18, -MULT_1X);
    assertEq(_cap(), HARD_CAP, "Release up to the hard cap should succeed");
  }

  function test_consume_revertOnUnauthorized() public {
    vm.prank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.consume(ID, 1, MULT_1X);

    vm.prank(manager);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.consume(ID, 1, MULT_1X);
  }

  function test_consume_unsetId() public {
    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, OTHER_ID));
    caps.consume(OTHER_ID, 1, MULT_1X);

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, OTHER_ID));
    caps.consume(OTHER_ID, 1, -MULT_1X);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MULTI POOL                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _ids(uint16 id1, uint16 id2, uint16 id3, uint16 id4) internal pure returns (uint64) {
    return uint64(id1) | (uint64(id2) << 16) | (uint64(id3) << 32) | (uint64(id4) << 48);
  }

  function _setPool(uint16 id, uint128 cap, uint128 hardCap) internal {
    vm.prank(manager);
    caps.setCap(id, cap, hardCap);
  }

  function _poolCap(uint16 id) internal view returns (uint128 cap) {
    (cap,) = caps.getCap(id);
  }

  function test_consume_multiPool_spillsOver() public {
    _setPool(OTHER_ID, 5000e18, HARD_CAP);

    // OTHER_ID first: drained, the rest spills to ID
    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(OTHER_ID, 6000e18, MULT_1X, 0);
    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(ID, 6000e18, MULT_1X, HARD_CAP - 1000e18);
    vm.prank(consumer);
    caps.consume(_ids(OTHER_ID, ID, 0, 0), 6000e18, MULT_1X);

    assertEq(_poolCap(OTHER_ID), 0, "First pool should be drained");
    assertEq(_poolCap(ID), HARD_CAP - 1000e18, "Second pool should take the rest");
  }

  function test_consume_multiPool_stopsOnceCovered() public {
    _setPool(OTHER_ID, 5000e18, HARD_CAP);

    vm.recordLogs();
    vm.prank(consumer);
    caps.consume(_ids(ID, OTHER_ID, 0, 0), 1000e18, MULT_1_5X);

    assertEq(vm.getRecordedLogs().length, 1, "Only the first pool should be touched");
    assertEq(_poolCap(ID), HARD_CAP - 1500e18, "First pool should cover the consumption");
    assertEq(_poolCap(OTHER_ID), 5000e18, "Second pool should be untouched");
  }

  function test_consume_multiPool_skipsEmptySlotsAndDrainedPools() public {
    _setPool(OTHER_ID, 0, HARD_CAP);
    _setPool(THIRD_ID, HARD_CAP, HARD_CAP);

    vm.prank(consumer);
    caps.consume(_ids(0, OTHER_ID, 0, THIRD_ID), 1000e18, MULT_1X);
    assertEq(_poolCap(OTHER_ID), 0, "Drained pool should stay drained");
    assertEq(_poolCap(THIRD_ID), HARD_CAP - 1000e18, "Fourth slot should cover the consumption");
    assertEq(_poolCap(ID), HARD_CAP, "Unreferenced pool should not change");
  }

  function test_consume_multiPool_revertsWhenPoolsTogetherFallShort() public {
    _setPool(ID, 1000e18, HARD_CAP);
    _setPool(OTHER_ID, 500e18, HARD_CAP);
    uint64 ids = _ids(ID, OTHER_ID, 0, 0);

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ids));
    caps.consume(ids, 1500e18 + 1, MULT_1X);
    assertEq(_poolCap(ID), 1000e18, "First pool should be rolled back");

    vm.prank(consumer);
    caps.consume(ids, 1500e18, MULT_1X);
    assertEq(_poolCap(ID), 0, "First pool should be drained");
    assertEq(_poolCap(OTHER_ID), 0, "Second pool should be drained");
  }

  function test_release_multiPool_refillsInReverseOrder() public {
    _setPool(ID, HARD_CAP - 1000e18, HARD_CAP);
    _setPool(OTHER_ID, 0, 5000e18);

    // OTHER_ID is last: refilled to its hard cap first, the rest goes back to ID
    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(OTHER_ID, 5500e18, -MULT_1X, 5000e18);
    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(ID, 5500e18, -MULT_1X, HARD_CAP - 500e18);
    vm.prank(consumer);
    caps.consume(_ids(ID, OTHER_ID, 0, 0), 5500e18, -MULT_1X);
  }

  function test_release_multiPool_revertsWhenHeadroomFallsShort() public {
    _setPool(ID, HARD_CAP - 1000e18, HARD_CAP);
    _setPool(OTHER_ID, 0, 500e18);
    uint64 ids = _ids(ID, OTHER_ID, 0, 0);

    vm.prank(consumer);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, ids));
    caps.consume(ids, 1500e18 + 1, -MULT_1X);
    assertEq(_poolCap(OTHER_ID), 0, "Last pool should be rolled back");
  }

  function test_consume_multiPool_roundTripRestoresPools() public {
    _setPool(ID, 1000e18, HARD_CAP);
    _setPool(OTHER_ID, 2000e18, 2000e18);
    uint64 ids = _ids(ID, OTHER_ID, 0, 0);

    vm.prank(consumer);
    caps.consume(ids, 2000e18, MULT_1_5X);
    assertEq(_poolCap(ID), 0, "First pool should be drained");
    assertEq(_poolCap(OTHER_ID), 0, "Second pool should take the rest");

    vm.prank(consumer);
    caps.consume(ids, 1000e18, -MULT_1_5X);
    assertEq(_poolCap(OTHER_ID), 1500e18, "Last pool should be refilled first");
    assertEq(_poolCap(ID), 0, "First pool should wait for the last to be refilled");

    vm.prank(consumer);
    caps.consume(ids, 1000e18, -MULT_1_5X);
    assertEq(_poolCap(OTHER_ID), 2000e18, "Last pool should be back to its hard cap");
    assertEq(_poolCap(ID), 1000e18, "First pool should be restored");
  }

  function test_validate_acceptsContiguousDistinctIds() public view {
    caps.validate(_ids(ID, 0, 0, 0), MULT_1X);
    caps.validate(_ids(ID, OTHER_ID, 0, 0), MULT_1X);
    caps.validate(_ids(4, 3, 2, 1), MULT_1X);
    caps.validate(type(uint64).max - 0x0001_0002_0003_0000, MULT_1X);
  }

  function test_validate_revertOnMinMultiplier() public {
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    caps.validate(ID, type(int24).min);
    caps.validate(ID, type(int24).min + 1);
  }

  function test_validate_revertOnInvalidIds() public {
    uint64[7] memory badIds = [
      _ids(0, 0, 0, 0), // no pool
      _ids(0, ID, 0, 0), // id1 missing
      _ids(ID, 0, OTHER_ID, 0), // gap
      _ids(ID, OTHER_ID, 0, THIRD_ID), // gap before id4
      _ids(ID, ID, 0, 0), // repeat
      _ids(ID, OTHER_ID, ID, 0), // repeat, not adjacent
      _ids(ID, OTHER_ID, THIRD_ID, THIRD_ID) // repeat in the last slot
    ];
    for (uint256 i = 0; i < badIds.length; i++) {
      vm.expectRevert(FacilityAbsoluteCaps.InvalidCapId.selector);
      caps.validate(badIds[i], MULT_1X);
    }
  }

  function testFuzz_validate_id(uint64 id) public {
    uint16[4] memory pools;
    uint256 count = 0;
    while (count < 4 && uint16(id >> (count * 16)) != 0) {
      pools[count] = uint16(id >> (count * 16));
      count++;
    }
    bool valid = count != 0 && (count == 4 || id >> (count * 16) == 0);
    for (uint256 i = 0; i < count; i++) {
      for (uint256 j = i + 1; j < count; j++) {
        if (pools[i] == pools[j]) valid = false;
      }
    }
    if (!valid) vm.expectRevert(FacilityAbsoluteCaps.InvalidCapId.selector);
    caps.validate(id, MULT_1X);
  }

  function test_consume_revertOnZeroId() public {
    vm.prank(consumer);
    vm.expectRevert(FacilityAbsoluteCaps.InvalidCapId.selector);
    caps.consume(0, 1, MULT_1X);
  }

  function test_available_multiPool_quotesSum() public {
    _setPool(ID, 3000e18, HARD_CAP);
    _setPool(OTHER_ID, 1000e18, 2000e18);
    uint64 ids = _ids(ID, 0, OTHER_ID, 0);

    assertEq(caps.available(ids, MULT_1X), 4000e18, "Should quote the summed capacity");
    assertEq(caps.available(ids, MULT_2X), 2000e18, "Multiplier should apply to the sum");
    assertEq(caps.available(ids, -MULT_1X), 8000e18, "Should quote the summed headroom");
    assertEq(caps.available(ids, 0), type(uint256).max, "Zero multiplier should be unbounded");
    assertEq(caps.available(0, MULT_1X), 0, "Empty cap ID should quote zero");
  }

  function testFuzz_consume_multiPool_quoteIsConsumableAndTight(
    uint128[4] memory poolCaps,
    uint128[4] memory hardCaps,
    int24 multiplier
  ) public {
    vm.assume(multiplier != 0 && multiplier != type(int24).min);
    for (uint16 i = 0; i < 4; i++) {
      hardCaps[i] = uint128(bound(hardCaps[i], poolCaps[i], type(uint128).max));
      _setPool(i + 1, poolCaps[i], hardCaps[i]);
    }
    uint64 ids = _ids(1, 2, 3, 4);

    uint256 quote = caps.available(ids, multiplier);
    if (multiplier > 0 && quote < type(uint256).max) {
      vm.prank(consumer);
      vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ids));
      caps.consume(ids, quote + 1, multiplier);
    }

    vm.prank(consumer);
    caps.consume(ids, quote, multiplier);
    for (uint16 i = 1; i <= 4; i++) {
      (uint128 cap, uint128 hardCap) = caps.getCap(i);
      assertLe(cap, hardCap, "Pools should stay within their hard caps");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            FUZZ                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_consume_quoteIsConsumableAndTight(uint128 cap, uint128 hardCap, int24 multiplier) public {
    hardCap = uint128(bound(hardCap, cap, type(uint128).max));
    vm.assume(multiplier != 0 && multiplier != type(int24).min);
    _setCap(cap, hardCap);

    uint256 quote = caps.available(ID, multiplier);

    // consumption rounds up, so one more than a positive quote never fits; release rounds down,
    // so a negative quote is consumable but not necessarily the largest such amount
    if (multiplier > 0) {
      vm.prank(consumer);
      vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ID));
      caps.consume(ID, quote + 1, multiplier);
    }

    _consume(quote, multiplier);
    if (multiplier > 0) {
      assertEq(_cap(), cap - LibCapsMath.consumption(quote, multiplier), "Quote should be consumable");
    } else {
      assertEq(_cap(), cap + LibCapsMath.release(quote, multiplier), "Quote should be releasable");
      assertLe(_cap(), hardCap, "Release should stay within the hard cap");
    }
  }

  function testFuzz_consume_roundTripNeverCreatesCapacity(uint128 hardCap, uint256 amount, int24 multiplier) public {
    multiplier = int24(bound(multiplier, 1, type(int24).max));
    hardCap = uint128(bound(hardCap, 1, type(uint128).max));
    _setCap(hardCap, hardCap);
    amount = bound(amount, 0, LibCapsMath.depositable(hardCap, multiplier));

    _consume(amount, multiplier);
    uint128 consumed = _cap();
    _consume(amount, -multiplier);

    assertLe(_cap(), hardCap, "Round trip should never exceed the starting cap");
    assertGe(_cap(), consumed, "Release should never lower the cap");
    assertLe(hardCap - _cap(), 1, "Round trip should lose at most one unit to rounding");
  }
}
