// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BorrowOffersHarness} from "test/mock/borrow/BorrowOffersHarness.sol";
import {BorrowOffersHandler} from "test/mock/borrow/BorrowOffersHandler.sol";
import {Offer} from "src/interfaces/borrow/IBorrowOffers.sol";
import {MAX_OFFERS, NULL} from "src/libs/borrow/LibBorrowOffersConstants.sol";

/// @title LibBorrowOffersInvariantTest
/// @author 3F Protocol
/// @notice Invariant suite for the {LibBorrowOffers} data structure (sorted doubly-linked list over
///         a fixed slab with a recycled free-list and a high-water allocator).
/// @dev A {BorrowOffersHandler} drives long, mixed sequences of insert / revoke / consume / warp
///      against a {BorrowOffersHarness}. After every sequence these invariants assert that the
///      structure is internally consistent and corruption-free. They are deliberately self-contained
///      (no economic assumptions): whatever the consume walk does, the list/slab/free-list must stay
///      a valid partition with consistent links.
///
///      Sort order is intentionally NOT asserted here: per the {LibBorrowOffers.insert} note it is a
///      best-effort consumption optimization, not a safety invariant (partial-fill rounding can
///      drift it). Strict ordering on the insert-only path is covered in LibBorrowOffers.t.sol.
///
///      Runs under `FOUNDRY_PROFILE=full` (the default profile excludes `invariant_*`).
contract LibBorrowOffersInvariantTest is StdInvariant, Test {
  BorrowOffersHarness internal harness;
  BorrowOffersHandler internal handler;

  function setUp() public {
    harness = new BorrowOffersHarness();
    harness.init(1 hours);

    handler = new BorrowOffersHandler(harness);

    bytes4[] memory selectors = new bytes4[](7);
    selectors[0] = handler.act_propose.selector;
    selectors[1] = handler.act_revoke.selector;
    selectors[2] = handler.act_consumeSeized.selector;
    selectors[3] = handler.act_consumeShares.selector;
    selectors[4] = handler.act_warp.selector;
    selectors[5] = handler.act_consumeLowRatioPosition.selector;
    selectors[6] = handler.act_consumeLowPrice.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INVARIANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice INV-1: the forward walk (head -> next) visits exactly `count` nodes and terminates.
  /// @dev `_forwardIds` reverts if the walk overruns `MAX_OFFERS` (a cycle), so this also proves the
  ///      active list is acyclic.
  function invariant_forwardWalkMatchesCount() public view {
    uint8[] memory ids = _forwardIds();
    assertEq(ids.length, harness.count(), "INV-1: forward walk length != count");
  }

  /// @notice INV-2: the backward walk (tail -> prev) is the exact reverse of the forward walk, and
  ///         head/tail point at the list ends.
  function invariant_backwardWalkIsReverseOfForward() public view {
    uint8[] memory fwd = _forwardIds();
    uint8[] memory bwd = _backwardIds();
    assertEq(bwd.length, fwd.length, "INV-2: backward length != forward length");
    for (uint256 i; i < fwd.length; ++i) {
      assertEq(bwd[bwd.length - 1 - i], fwd[i], "INV-2: backward not reverse of forward");
    }
    if (fwd.length == 0) {
      assertEq(harness.head(), NULL, "INV-2: non-NULL head when empty");
      assertEq(harness.tail(), NULL, "INV-2: non-NULL tail when empty");
    } else {
      assertEq(harness.head(), fwd[0], "INV-2: head != first");
      assertEq(harness.tail(), fwd[fwd.length - 1], "INV-2: tail != last");
    }
  }

  /// @notice INV-3: doubly-linked pointer consistency along the active list. Each node's `next`
  ///         points to a node whose `prev` points back; the ends are NULL-terminated.
  function invariant_doublyLinkedPointers() public view {
    uint8[] memory ids = _forwardIds();
    for (uint256 i; i < ids.length; ++i) {
      Offer memory o = harness.slabAt(ids[i]);
      if (i == 0) assertEq(o.prev, NULL, "INV-3: head.prev != NULL");
      else assertEq(o.prev, ids[i - 1], "INV-3: prev mismatch");
      if (i == ids.length - 1) assertEq(o.next, NULL, "INV-3: tail.next != NULL");
      else assertEq(o.next, ids[i + 1], "INV-3: next mismatch");
    }
  }

  /// @notice INV-4: the free-list and the live list partition exactly `[0, nextFresh)`. No slot is
  ///         both live and free; together they cover every allocated index and nothing beyond it.
  function invariant_freeListPartitionsSlab() public view {
    uint8[] memory live = _forwardIds();
    uint8[] memory free = _freeIds();

    assertEq(uint256(live.length) + uint256(free.length), harness.nextFresh(), "INV-4: live + free != nextFresh");

    bool[] memory seen = new bool[](MAX_OFFERS);
    for (uint256 i; i < live.length; ++i) {
      assertFalse(seen[live[i]], "INV-4: id appears twice in live list");
      seen[live[i]] = true;
    }
    for (uint256 i; i < free.length; ++i) {
      assertFalse(seen[free[i]], "INV-4: id in both live and free lists");
      seen[free[i]] = true;
    }
    // Coverage: every index below the high-water mark is accounted for exactly once.
    uint8 nf = harness.nextFresh();
    for (uint8 i; i < nf; ++i) {
      assertTrue(seen[i], "INV-4: allocated index missing from both lists");
    }
  }

  /// @notice INV-5: slot markers match list membership, and no live offer is degenerate.
  /// @dev Live offers have a non-zero proposer and both remaining amounts > 0 (consume removes any
  ///      offer the moment a side hits zero). Freed slots are fully zeroed (proposer == 0).
  function invariant_slotMarkers() public view {
    uint8[] memory live = _forwardIds();
    for (uint256 i; i < live.length; ++i) {
      Offer memory o = harness.slabAt(live[i]);
      assertTrue(o.proposer != address(0), "INV-5: live offer has zero proposer");
      assertTrue(o.remainingCollateral > 0, "INV-5: live offer has zero collateral");
      assertTrue(o.remainingDebtShares > 0, "INV-5: live offer has zero debt shares");
    }
    uint8[] memory free = _freeIds();
    for (uint256 i; i < free.length; ++i) {
      assertEq(harness.slabAt(free[i]).proposer, address(0), "INV-5: freed slot has non-zero proposer");
    }
  }

  /// @notice INV-6: hard bounds and head/tail nullity. `count`/`nextFresh` never exceed the slab,
  ///         and head/tail are NULL exactly when the list is empty.
  function invariant_boundsAndNullity() public view {
    assertLe(harness.count(), uint8(MAX_OFFERS), "INV-6: count > MAX_OFFERS");
    assertLe(harness.nextFresh(), uint8(MAX_OFFERS), "INV-6: nextFresh > MAX_OFFERS");
    if (harness.count() == 0) {
      assertEq(harness.head(), NULL, "INV-6: head not NULL when empty");
      assertEq(harness.tail(), NULL, "INV-6: tail not NULL when empty");
    } else {
      assertTrue(harness.head() != NULL, "INV-6: head NULL when non-empty");
      assertTrue(harness.tail() != NULL, "INV-6: tail NULL when non-empty");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       WALK HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Active list head -> next. Reverts on a walk that exceeds `MAX_OFFERS` nodes (a cycle), so
  ///      no invariant can hang on a corrupt structure.
  function _forwardIds() internal view returns (uint8[] memory ids) {
    uint8[] memory tmp = new uint8[](MAX_OFFERS + 1);
    uint256 n;
    uint8 cur = harness.head();
    while (cur != NULL) {
      require(n <= MAX_OFFERS, "forward walk overran MAX_OFFERS (cycle)");
      tmp[n++] = cur;
      cur = harness.slabAt(cur).next;
    }
    ids = _trim(tmp, n);
  }

  /// @dev Active list tail -> prev. Same cycle guard as {_forwardIds}.
  function _backwardIds() internal view returns (uint8[] memory ids) {
    uint8[] memory tmp = new uint8[](MAX_OFFERS + 1);
    uint256 n;
    uint8 cur = harness.tail();
    while (cur != NULL) {
      require(n <= MAX_OFFERS, "backward walk overran MAX_OFFERS (cycle)");
      tmp[n++] = cur;
      cur = harness.slabAt(cur).prev;
    }
    ids = _trim(tmp, n);
  }

  /// @dev Free-list freeHead -> next. Same cycle guard.
  function _freeIds() internal view returns (uint8[] memory ids) {
    uint8[] memory tmp = new uint8[](MAX_OFFERS + 1);
    uint256 n;
    uint8 cur = harness.freeHead();
    while (cur != NULL) {
      require(n <= MAX_OFFERS, "free walk overran MAX_OFFERS (cycle)");
      tmp[n++] = cur;
      cur = harness.slabAt(cur).next;
    }
    ids = _trim(tmp, n);
  }

  function _trim(uint8[] memory tmp, uint256 n) internal pure returns (uint8[] memory ids) {
    ids = new uint8[](n);
    for (uint256 i; i < n; ++i) {
      ids[i] = tmp[i];
    }
  }
}
