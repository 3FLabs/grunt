// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {CapsInvHandlerAbsolute} from "test/mock/facility/CapsInvHandlerAbsolute.sol";

/// @title FacilityAbsoluteCapsInvariantTest
/// @notice Stateful invariants of FacilityAbsoluteCaps under setCap, adjustCap, consume and
///         release (within and past the headroom) on random pool layouts, consumer role changes
///         and stranger calls.
/// forge-config: default.invariant.fail-on-revert = true
contract FacilityAbsoluteCapsInvariantTest is StdInvariant, Test {
  using LibClone for address;

  FacilityAbsoluteCaps internal caps;
  CapsInvHandlerAbsolute internal handler;
  uint16 internal pools;

  uint256 internal constant MIN_CALLS = 8;

  address internal owner = makeAddr("owner");
  address internal manager = makeAddr("manager");
  address internal stranger = makeAddr("stranger");
  address[3] internal consumers = [makeAddr("consumer0"), makeAddr("consumer1"), makeAddr("consumer2")];

  function setUp() public {
    caps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = manager;
    address[] memory initialConsumers = new address[](2);
    initialConsumers[0] = consumers[0];
    initialConsumers[1] = consumers[1];
    caps.initialize(owner, managers, initialConsumers);

    uint128[2][5] memory initial = [
      [uint128(500e18), 1_000e18], // half used
      [uint128(0), 2_000e18], // drained
      [uint128(3_000e18), 3_000e18], // full
      [uint128(5e29), 1e30],
      [uint128(1), 7]
    ];
    for (uint16 i = 0; i < 5; i++) {
      vm.prank(manager);
      caps.setCap(i + 1, initial[i][0], initial[i][1]);
    }

    handler = new CapsInvHandlerAbsolute(caps, owner, manager, stranger, consumers);
    pools = handler.POOLS();

    bytes4[] memory selectors = new bytes4[](8);
    selectors[0] = handler.act_consume.selector;
    selectors[1] = handler.act_release.selector;
    selectors[2] = handler.act_overRelease.selector;
    selectors[3] = handler.act_consumeAny.selector;
    selectors[4] = handler.act_setCap.selector;
    selectors[5] = handler.act_adjustCap.selector;
    selectors[6] = handler.act_setRole.selector;
    selectors[7] = handler.act_stranger.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /// @dev Fails runs where the quoted consumes never moved capacity. Short sequences are skipped
  ///      so shrinking keeps the sequence of the invariant that broke.
  function afterInvariant() public view {
    if (handler.consumeCalls() >= MIN_CALLS) assertGt(handler.consumes(), 0, "act_consume never moved capacity");
    if (handler.releaseCalls() >= MIN_CALLS) assertGt(handler.releases(), 0, "act_release never moved capacity");
    assertGe(handler.hardCapRejections(), handler.overReleaseCalls(), "a release past the headroom was not rejected");
  }

  function invariant_capWithinHardCap() public view {
    for (uint16 pool = 0; pool <= pools; pool++) {
      (uint128 cap, uint128 hardCap) = caps.getCap(pool);
      assertLe(cap, hardCap, "cap above hardCap");
    }
  }

  /// @dev The mirror moves caps only by the prefix-first charge of a successful consume and by
  ///      setCap / adjustCap, so this also checks that nothing outside the ID's pools moves.
  function invariant_capsMatchMirror() public view {
    for (uint16 pool = 0; pool <= pools; pool++) {
      (uint128 cap,) = caps.getCap(pool);
      assertEq(cap, handler.ghostCap(pool), "cap differs from the mirror");
    }
  }

  /// @dev The mirror moves hard caps only on setCap and on adjustCap, which keeps the consumption.
  function invariant_hardCapsMatchMirror() public view {
    for (uint16 pool = 0; pool <= pools; pool++) {
      (, uint128 hardCap) = caps.getCap(pool);
      assertEq(hardCap, handler.ghostHardCap(pool), "hardCap differs from the mirror");
    }
  }

  function invariant_callsMatchSpec() public view {
    assertFalse(handler.outcomeMismatch(), "call outcome or error differs from the mirror");
  }

  function invariant_eventsMatchSpec() public view {
    assertFalse(handler.eventMismatch(), "events differ from one CapConsumed per changed pool or one CapSet");
  }

  function invariant_availableIsConsumable() public {
    assertFalse(handler.quoteMismatch(), "available differs from the summed room");
    uint64[3] memory ids = [uint64(0x1_0002), 0x2_0003_0004_0005, 0x4_0000_0001];
    int24[7] memory multipliers = [int24(0), 1, 6144, type(int24).max, -1, -6144, -type(int24).max];
    uint256 snapshot = vm.snapshotState();
    for (uint256 j = 0; j < multipliers.length; j++) {
      assertEq(caps.available(0, multipliers[j]), 0, "empty cap ID should quote zero");
      for (uint256 i = 0; i < ids.length; i++) {
        uint256 quote = caps.available(ids[i], multipliers[j]);
        assertEq(quote, handler.quoteOf(ids[i], multipliers[j]), "available differs from the summed room");
        vm.prank(consumers[0]);
        caps.consume(ids[i], quote, multipliers[j]);
        vm.revertToState(snapshot);
      }
    }
  }
}
