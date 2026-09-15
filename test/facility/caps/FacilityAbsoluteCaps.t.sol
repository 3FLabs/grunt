// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCapsMath} from "src/libs/common/LibCapsMath.sol";

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

  uint32 constant ID = 1;
  uint32 constant OTHER_ID = 2;
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
    vm.expectEmit(true, true, true, true, address(caps));
    emit IFacilityCaps.CapConsumed(ID, 1000e18, 0, HARD_CAP);
    _consume(1000e18, 0);
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
