// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {CapsInvHandlerDynamic} from "test/mock/facility/CapsInvHandlerDynamic.sol";

/// @title FacilityDynamicCapsInvariantTest
/// @notice Stateful invariants of FacilityDynamicCaps under warps, consumes with random
///         multipliers on several IDs and setCap with past, current and future origins.
/// forge-config: default.invariant.fail-on-revert = true
contract FacilityDynamicCapsInvariantTest is StdInvariant, Test {
  using LibClone for address;

  FacilityDynamicCaps internal caps;
  CapsInvHandlerDynamic internal handler;

  address internal owner = makeAddr("owner");
  address internal manager = makeAddr("manager");
  address internal consumer = makeAddr("consumer");
  uint64[4] internal ids = [uint64(1), 2, 3, type(uint64).max];

  uint256 internal constant START = 1_700_000_000;
  uint256 internal constant MIN_CALLS = 8;

  function setUp() public {
    vm.warp(START);
    caps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = manager;
    address[] memory consumers = new address[](1);
    consumers[0] = consumer;
    caps.initialize(owner, managers, consumers);

    vm.startPrank(manager);
    caps.setCap(ids[0], 1_000_000e18, 1 days, 0);
    caps.setCap(ids[1], 5e24, 7 days, uint64(START - 3 days));
    caps.setCap(ids[2], 1e6, 1 hours, uint64(START + 1 hours));
    vm.stopPrank();

    handler = new CapsInvHandlerDynamic(caps, manager, consumer, ids);

    bytes4[] memory selectors = new bytes4[](4);
    selectors[0] = handler.act_warp.selector;
    selectors[1] = handler.act_consume.selector;
    selectors[2] = handler.act_consumeAny.selector;
    selectors[3] = handler.act_setCap.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /// @dev Fails runs where the quoted consumes never moved an origin. Short sequences are skipped
  ///      so shrinking keeps the sequence of the invariant that broke.
  function afterInvariant() public view {
    if (handler.consumeCalls() >= MIN_CALLS) assertGt(handler.consumes(), 0, "act_consume never moved an origin");
  }

  function invariant_remainingWithinRecovery() public view {
    for (uint256 i = 0; i < ids.length; i++) {
      (uint128 recovery,,) = caps.getCap(ids[i]);
      assertLe(caps.remaining(ids[i]), recovery, "remaining above recovery");
    }
  }

  /// @dev The mirror moves an origin only on setCap and on a consume with a non-zero
  ///      consumption, to now - floor(left * recoveryTime / recovery).
  function invariant_curvesMatchMirror() public view {
    for (uint256 i = 0; i < ids.length; i++) {
      (uint128 recovery, uint64 recoveryTime, uint64 originTime) = caps.getCap(ids[i]);
      CapsInvHandlerDynamic.Curve memory curve = handler.ghost(ids[i]);
      assertEq(recovery, curve.recovery, "recovery differs from the mirror");
      assertEq(recoveryTime, curve.recoveryTime, "recoveryTime differs from the mirror");
      assertEq(originTime, curve.originTime, "originTime differs from the mirror");
      assertEq(caps.remaining(ids[i]), handler.remainingOf(ids[i]), "remaining differs from the curve");
    }
  }

  function invariant_originNeverMovesBackwards() public view {
    assertFalse(handler.originMovedBack(), "consume moved the origin backwards");
  }

  /// @dev Rounding the origin in favor of the cap forfeits at most one second of recovery.
  function invariant_consumeForfeitsAtMostOneSecond() public view {
    assertFalse(handler.roundingOutOfBounds(), "consume left more than the difference or forfeited over a second");
  }

  function invariant_noopConsumesKeepState() public view {
    assertFalse(handler.noopChangedState(), "no-op consume changed state or emitted");
  }

  function invariant_callsMatchSpec() public view {
    assertFalse(handler.outcomeMismatch(), "call outcome or error differs from the mirror");
  }

  /// @dev CapConsumed carries the move and the remaining capacity after the origin rounding.
  function invariant_eventsMatchSpec() public view {
    assertFalse(handler.eventMismatch(), "events differ from one rounded CapConsumed or one CapSet");
  }

  /// @dev Consumption since the last setCap stays within the unrounded capacity at that setCap
  ///      plus the recovery accrued since, both sides scaled by recoveryTime.
  function invariant_throughputBounded() public view {
    for (uint256 i = 0; i < ids.length; i++) {
      (uint128 recovery, uint64 recoveryTime,) = caps.getCap(ids[i]);
      uint256 accrued = uint256(recovery) * (block.timestamp - handler.setTime(ids[i]));
      assertLe(
        handler.consumed(ids[i]) * recoveryTime, handler.startCredit(ids[i]) + accrued, "throughput above recovery"
      );
    }
  }

  function invariant_availableIsConsumable() public {
    assertFalse(handler.quoteMismatch(), "available differs from the curve");
    int24[6] memory multipliers = [int24(1), 4096, 6144, type(int24).max, 0, -4096];
    uint256 snapshot = vm.snapshotState();
    for (uint256 i = 0; i < ids.length; i++) {
      for (uint256 j = 0; j < multipliers.length; j++) {
        uint256 quote = caps.available(ids[i], multipliers[j]);
        assertEq(quote, handler.quoteOf(ids[i], multipliers[j]), "available differs from the curve");
        vm.prank(consumer);
        caps.consume(ids[i], quote, multipliers[j]);
        vm.revertToState(snapshot);
      }
    }
  }
}
