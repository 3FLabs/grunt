// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {BorrowOffersHarness} from "test/mock/borrow/BorrowOffersHarness.sol";
import {LibBorrowOffers} from "src/libs/borrow/LibBorrowOffers.sol";
import {LibBorrowErrors} from "src/libs/borrow/LibBorrowErrors.sol";
import {Offer} from "src/interfaces/borrow/IBorrowOffers.sol";
import {MAX_OFFERS, NULL} from "src/libs/borrow/LibBorrowOffersConstants.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";

/// @title LibBorrowOffersTest
/// @author 3F Protocol
/// @notice Direct, Morpho-independent tests of the {LibBorrowOffers} data structure via
///         {BorrowOffersHarness}: one massive sequential lifecycle test that drives the slab +
///         doubly-linked list + free-list through fill / drain / revoke-in-the-middle / recycle /
///         consume / expire, plus targeted fuzz tests for sort-order, slot recycling and
///         consume-safety. Structural integrity is asserted after every mutation.
/// @dev The companion {LibBorrowOffersInvariantTest} runs the same structural assertions over
///      fuzzer-generated operation sequences; this file pins down deterministic, high-coverage
///      scenarios that a bounded invariant run might not reliably hit (e.g. exactly filling the
///      slab, then revoking head/tail/middle, then recycling all freed slots).
contract LibBorrowOffersTest is Test {
  BorrowOffersHarness internal h;

  uint40 internal constant TIMELOCK = 1 hours;

  // Fixed favorable market snapshot (see BorrowOffersHandler for the rationale): unit price, 1:1
  // share:asset totals (exact conversions), and a position ratio (4) above every offer ratio so
  // profitable offers are also strictly de-risking and the list genuinely drains under consume.
  uint256 internal constant PRICE = ORACLE_PRICE_SCALE;
  uint256 internal constant TOTAL_BORROW_ASSETS = 1e27;
  uint256 internal constant TOTAL_BORROW_SHARES = 1e27;
  uint256 internal constant POSITION_COLLATERAL = 4e24;
  uint256 internal constant POSITION_BORROW_SHARES = 1e24;

  function setUp() public {
    h = new BorrowOffersHarness();
    h.init(TIMELOCK);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  MASSIVE LIFECYCLE TEST                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Single end-to-end run that stresses every transition of the data structure: fill to
  ///         capacity, reject overflow, unlink at head/tail/middle, recycle freed slots in the
  ///         middle, consume (partial + full + multi-offer), prune on expiry, fully drain, then
  ///         recycle again. The structure is asserted consistent (and, where applicable, sorted)
  ///         after every step.
  function test_dataStructure_massiveLifecycle() public {
    uint40 t0 = uint40(block.timestamp);
    uint40 active = t0 + TIMELOCK;
    uint40 expiry = active + 30 days;

    // --- Phase 1: fill the slab to MAX_OFFERS with varied (all < position-ratio) ratios. ---
    for (uint256 i; i < MAX_OFFERS; ++i) {
      uint128 debtShares = 1e18;
      // collateral 1.1e18 .. 2.65e18 => ratio 1.1 .. 2.65, all strictly below the position ratio (4).
      uint128 collateral = uint128(1.1e18 + i * 5e16);
      h.insert(address(uint160(0xAAAA + i)), active, expiry, collateral, debtShares);
      _assertStructure();
    }
    assertEq(harnessCount(), uint8(MAX_OFFERS), "slab filled");
    assertEq(h.nextFresh(), uint8(MAX_OFFERS), "all slots fresh-allocated");
    _assertSorted();

    // --- Phase 2: a further insert reverts (slab full). ---
    vm.expectRevert(LibBorrowErrors.TooManyOffers.selector);
    h.insert(address(0xBEEF), active, expiry, 2e18, 1e18);

    // --- Phase 3: unlink at the head, the tail, and several middle positions. ---
    uint8[] memory order = _forwardIds();
    h.removeOffer(order[0]); // head
    _assertStructure();
    h.removeOffer(order[order.length - 1]); // tail
    _assertStructure();
    h.removeOffer(order[order.length / 2]); // middle
    _assertStructure();
    order = _forwardIds();
    h.removeOffer(order[3]); // near-head middle
    _assertStructure();
    h.removeOffer(order[order.length - 4]); // near-tail middle
    _assertStructure();
    assertEq(harnessCount(), uint8(MAX_OFFERS) - 5, "five unlinked");
    assertEq(h.nextFresh(), uint8(MAX_OFFERS), "high-water mark unchanged by removals");

    // --- Phase 4: recreate in the middle; these must recycle freed slab slots (no fresh growth). ---
    for (uint256 i; i < 5; ++i) {
      uint128 collateral = uint128(1.5e18 + i * 1e17);
      uint8 id = h.insert(address(uint160(0xCCCC + i)), active, expiry, collateral, 1e18);
      assertTrue(id < MAX_OFFERS, "recycled id within slab");
      _assertStructure();
    }
    assertEq(harnessCount(), uint8(MAX_OFFERS), "refilled to capacity");
    assertEq(h.nextFresh(), uint8(MAX_OFFERS), "no fresh growth: slots were recycled");
    _assertSorted();

    // --- Phase 5: activate, then consume a moderate target (partial + full fills, some removals). ---
    vm.warp(active + 1);
    uint8 before = harnessCount();
    (uint256 seized, uint256 repaid) = h.consume(_input(2e18, 0));
    assertGt(seized, 0, "collateral seized");
    assertGt(repaid, 0, "shares repaid");
    assertLt(harnessCount(), before, "consume removed at least one offer");
    _assertStructure();

    // --- Phase 6: warp past expiry; a large consume prunes every remaining (now expired) offer. ---
    vm.warp(expiry + 1);
    h.consume(_input(POSITION_COLLATERAL, 0));
    _assertStructure();
    assertEq(harnessCount(), 0, "all expired offers pruned");
    assertEq(h.head(), NULL, "empty head");
    assertEq(h.tail(), NULL, "empty tail");

    // --- Phase 7: after a full drain, inserts recycle and the structure remains valid. ---
    uint40 active2 = uint40(block.timestamp) + TIMELOCK;
    uint8 recycled = h.insert(address(0xD00D), active2, active2 + 1 days, 2e18, 1e18);
    assertTrue(recycled < MAX_OFFERS, "recycled after full drain");
    _assertStructure();
    assertEq(harnessCount(), 1, "one live offer again");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       DORMANT WINDOW                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A never-initialized harness reproduces the post-upgrade / pre-initializeV2 dormant
  ///         window: the offer namespace is all-zero, so `count == 0` but `head == 0` (a real slab
  ///         index, NOT the NULL sentinel). Every reader must degrade gracefully (empty / zero)
  ///         instead of panicking or looping on the zeroed slab.
  function test_dormantWindow_allReadersSafe() public {
    BorrowOffersHarness fresh = new BorrowOffersHarness(); // no init(): storage entirely zero
    assertEq(fresh.count(), 0, "count zero");
    assertEq(fresh.head(), 0, "head is 0 (not NULL) in the dormant window");

    // listOffers (and the external offers() view) must return an empty array, not Panic(0x32).
    assertEq(fresh.listOffers().length, 0, "listOffers empty");

    // consume / previewConsume short-circuit on count==0.
    LibBorrowOffers.ConsumeInput memory inp = _input(1e18, 0);
    (uint256 ps, uint256 pd) = fresh.previewConsume(inp);
    assertEq(ps, 0, "preview seize 0");
    assertEq(pd, 0, "preview shares 0");
    (uint256 cs, uint256 cd) = fresh.consume(inp);
    assertEq(cs, 0, "consume seize 0");
    assertEq(cd, 0, "consume shares 0");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         FUZZ TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Inserting offers in arbitrary order keeps the list sorted (descending debt/collateral)
  ///         and structurally consistent. Sort order is a guaranteed property on the insert-only
  ///         path (consume can later drift it, which is why the invariant suite omits it).
  function testFuzz_insertOnly_maintainsSortAndStructure(uint96[12] memory collSeeds, uint96[12] memory shareSeeds)
    public
  {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    for (uint256 i; i < collSeeds.length; ++i) {
      uint128 debtShares = uint128(_bound(shareSeeds[i], 1, 1e21));
      uint128 collateral = uint128(_bound(collSeeds[i], uint256(debtShares) + 1, uint256(debtShares) * 5));
      h.insert(address(uint160(0x100 + i)), active, expiry, collateral, debtShares);
      _assertStructure();
      _assertSorted();
    }
    assertEq(harnessCount(), uint8(collSeeds.length), "all inserted");
  }

  /// @notice A long, fuzzer-seeded interleaving of inserts and removals never leaks a slab slot:
  ///         the high-water mark stays bounded, freed slots are recycled, and live + free always
  ///         partition `[0, nextFresh)`.
  function testFuzz_allocFreeRecycling(uint256 seed) public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 1 days;
    for (uint256 i; i < 80; ++i) {
      seed = uint256(keccak256(abi.encode(seed, i)));
      if (seed % 3 == 0 && harnessCount() > 0) {
        h.removeOffer(_liveIdAt(uint8(seed % harnessCount())));
      } else if (harnessCount() < MAX_OFFERS) {
        uint128 debtShares = uint128(_bound(seed, 1, 1e21));
        uint128 collateral =
          uint128(_bound(uint256(keccak256(abi.encode(seed, "c"))), uint256(debtShares) + 1, uint256(debtShares) * 5));
        h.insert(address(uint160(seed | 1)), active, expiry, collateral, debtShares);
      }
      _assertStructure();
    }
  }

  /// @notice Consuming an arbitrary target against a built-up list never corrupts the structure, and
  ///         `previewConsume` predicts the realized `(seized, repaid)` exactly.
  function testFuzz_consumeNeverCorrupts(
    uint96[10] memory collSeeds,
    uint96[10] memory shareSeeds,
    uint256 targetSeed,
    bool seizeMode
  ) public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    for (uint256 i; i < collSeeds.length; ++i) {
      uint128 debtShares = uint128(_bound(shareSeeds[i], 1, 1e20));
      // ratio (1, 3] so every offer is profitable and strictly de-risking (position ratio 4).
      uint128 collateral = uint128(_bound(collSeeds[i], uint256(debtShares) + 1, uint256(debtShares) * 3));
      h.insert(address(uint160(0x200 + i)), active, expiry, collateral, debtShares);
    }
    vm.warp(active + 1); // activate

    LibBorrowOffers.ConsumeInput memory inp =
      seizeMode ? _input(_bound(targetSeed, 1, 5e21), 0) : _input(0, _bound(targetSeed, 1, 2e21));

    // previewConsume is a view: it predicts the result for the exact current state.
    (uint256 predSeized, uint256 predShares) = h.previewConsume(inp);
    (uint256 actSeized, uint256 actShares) = h.consume(inp);

    assertEq(actSeized, predSeized, "preview seized != actual");
    assertEq(actShares, predShares, "preview shares != actual");
    _assertStructure();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                STRUCTURAL ASSERTION HELPERS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Full structural integrity check (mirrors {LibBorrowOffersInvariantTest}'s invariants):
  ///      forward/backward walks agree with `count`, pointers are consistent, the free-list and live
  ///      list partition `[0, nextFresh)`, slot markers match membership, and bounds hold.
  function _assertStructure() internal view {
    uint8[] memory fwd = _forwardIds();
    uint8[] memory bwd = _backwardIds();
    uint8[] memory free = _freeIds();

    // counts
    assertEq(fwd.length, harnessCount(), "count != forward length");
    assertEq(bwd.length, fwd.length, "backward length != forward length");
    assertEq(uint256(fwd.length) + uint256(free.length), h.nextFresh(), "live + free != nextFresh");
    assertLe(harnessCount(), uint8(MAX_OFFERS), "count > MAX_OFFERS");
    assertLe(h.nextFresh(), uint8(MAX_OFFERS), "nextFresh > MAX_OFFERS");

    // head/tail nullity + ends
    if (fwd.length == 0) {
      assertEq(h.head(), NULL, "head not NULL when empty");
      assertEq(h.tail(), NULL, "tail not NULL when empty");
    } else {
      assertEq(h.head(), fwd[0], "head != first");
      assertEq(h.tail(), fwd[fwd.length - 1], "tail != last");
    }

    // pointer consistency + backward is reverse of forward
    for (uint256 i; i < fwd.length; ++i) {
      Offer memory o = h.slabAt(fwd[i]);
      if (i == 0) assertEq(o.prev, NULL, "head.prev != NULL");
      else assertEq(o.prev, fwd[i - 1], "prev mismatch");
      if (i == fwd.length - 1) assertEq(o.next, NULL, "tail.next != NULL");
      else assertEq(o.next, fwd[i + 1], "next mismatch");
      assertEq(bwd[bwd.length - 1 - i], fwd[i], "backward not reverse of forward");

      // live markers + no degenerate live offer
      assertTrue(o.proposer != address(0), "live offer zero proposer");
      assertTrue(o.remainingCollateral > 0 && o.remainingDebtShares > 0, "degenerate live offer");
    }

    // partition: disjoint + covers [0, nextFresh)
    bool[] memory seen = new bool[](MAX_OFFERS);
    for (uint256 i; i < fwd.length; ++i) {
      assertFalse(seen[fwd[i]], "id twice in live list");
      seen[fwd[i]] = true;
    }
    for (uint256 i; i < free.length; ++i) {
      assertFalse(seen[free[i]], "id in both live and free");
      seen[free[i]] = true;
      assertEq(h.slabAt(free[i]).proposer, address(0), "freed slot non-zero proposer");
    }
    uint8 nf = h.nextFresh();
    for (uint8 i; i < nf; ++i) {
      assertTrue(seen[i], "allocated index missing from both lists");
    }
  }

  /// @dev Asserts the active list is sorted by descending `debtShares / collateral` (ascending
  ///      price): each node's ratio is >= the next node's. Cross-multiplied to avoid division;
  ///      products are uint128 * uint128 < 2**256.
  function _assertSorted() internal view {
    uint8[] memory ids = _forwardIds();
    for (uint256 i; i + 1 < ids.length; ++i) {
      Offer memory a = h.slabAt(ids[i]);
      Offer memory b = h.slabAt(ids[i + 1]);
      assertGe(
        uint256(a.remainingDebtShares) * b.remainingCollateral,
        uint256(b.remainingDebtShares) * a.remainingCollateral,
        "list not sorted by descending debt/collateral"
      );
    }
  }

  function harnessCount() internal view returns (uint8) {
    return h.count();
  }

  function _forwardIds() internal view returns (uint8[] memory ids) {
    uint8[] memory tmp = new uint8[](MAX_OFFERS + 1);
    uint256 n;
    uint8 cur = h.head();
    while (cur != NULL) {
      require(n <= MAX_OFFERS, "forward walk overran (cycle)");
      tmp[n++] = cur;
      cur = h.slabAt(cur).next;
    }
    ids = _trim(tmp, n);
  }

  function _backwardIds() internal view returns (uint8[] memory ids) {
    uint8[] memory tmp = new uint8[](MAX_OFFERS + 1);
    uint256 n;
    uint8 cur = h.tail();
    while (cur != NULL) {
      require(n <= MAX_OFFERS, "backward walk overran (cycle)");
      tmp[n++] = cur;
      cur = h.slabAt(cur).prev;
    }
    ids = _trim(tmp, n);
  }

  function _freeIds() internal view returns (uint8[] memory ids) {
    uint8[] memory tmp = new uint8[](MAX_OFFERS + 1);
    uint256 n;
    uint8 cur = h.freeHead();
    while (cur != NULL) {
      require(n <= MAX_OFFERS, "free walk overran (cycle)");
      tmp[n++] = cur;
      cur = h.slabAt(cur).next;
    }
    ids = _trim(tmp, n);
  }

  function _liveIdAt(uint8 nth) internal view returns (uint8 cur) {
    cur = h.head();
    for (uint8 k; k < nth; ++k) {
      cur = h.slabAt(cur).next;
    }
  }

  function _trim(uint8[] memory tmp, uint256 n) internal pure returns (uint8[] memory ids) {
    ids = new uint8[](n);
    for (uint256 i; i < n; ++i) {
      ids[i] = tmp[i];
    }
  }

  function _input(uint256 seizedTarget, uint256 repaidSharesTarget)
    internal
    pure
    returns (LibBorrowOffers.ConsumeInput memory)
  {
    return LibBorrowOffers.ConsumeInput({
      seizedTarget: seizedTarget,
      repaidSharesTarget: repaidSharesTarget,
      price: PRICE,
      totalBorrowAssets: TOTAL_BORROW_ASSETS,
      totalBorrowShares: TOTAL_BORROW_SHARES,
      positionCollateral: POSITION_COLLATERAL,
      positionBorrowShares: POSITION_BORROW_SHARES
    });
  }
}
