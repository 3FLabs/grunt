// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BorrowOffersHarness} from "test/mock/borrow/BorrowOffersHarness.sol";
import {LibBorrowOffers} from "src/libs/borrow/LibBorrowOffers.sol";
import {LibBorrowErrors} from "src/libs/borrow/LibBorrowErrors.sol";
import {IBorrowOffers, Offer} from "src/interfaces/borrow/IBorrowOffers.sol";
import {MAX_OFFERS} from "src/libs/borrow/LibBorrowOffersConstants.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";

/// @title LibBorrowOffersTest
/// @author 3F Protocol
/// @notice Direct, Morpho-independent tests of the {LibBorrowOffers} data structure via
///         {BorrowOffersHarness}: one massive sequential lifecycle test that drives the slab +
///         liveness bitmap through fill / drain / revoke / lowest-id-recycle / consume / expire,
///         plus targeted tests for the sorted-at-consume walk (ascending-price drain, Skip vs
///         Stop), fill-math regressions (position-clamp rescale, zero-collateral Skip,
///         expired-slab self-heal) and preview/consume equivalence fuzz. Structural integrity
///         (bitmap <=> slab agreement) is asserted after every mutation.
/// @dev The companion {LibBorrowOffersInvariantTest} runs the same structural assertions over
///      fuzzer-generated operation sequences; this file pins down deterministic, high-coverage
///      scenarios that a bounded invariant run might not reliably hit (e.g. exactly filling the
///      slab, then revoking and recycling specific ids).
contract LibBorrowOffersTest is Test {
  BorrowOffersHarness internal h;

  /// @dev Fixed veto window applied to every inserted offer (the timelock configuration itself
  ///      lives on the shared registry; the library only stores the book).
  uint40 internal constant TIMELOCK = 1 hours;

  // Fixed favorable market snapshot (see BorrowOffersHandler for the rationale): unit price, 1:1
  // share:asset totals (exact conversions), and a position ratio (4) above every offer ratio so
  // profitable offers are also strictly de-risking and the book genuinely drains under consume.
  uint256 internal constant PRICE = ORACLE_PRICE_SCALE;
  uint256 internal constant TOTAL_BORROW_ASSETS = 1e27;
  uint256 internal constant TOTAL_BORROW_SHARES = 1e27;
  uint256 internal constant POSITION_COLLATERAL = 4e24;
  uint256 internal constant POSITION_BORROW_SHARES = 1e24;

  function setUp() public {
    h = new BorrowOffersHarness();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  MASSIVE LIFECYCLE TEST                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Single end-to-end run that stresses every transition of the data structure: fill to
  ///         capacity (ids assigned lowest-first), reject overflow, remove low/middle/high ids,
  ///         recycle freed ids lowest-first, consume (cheapest offers drain first), prune on
  ///         expiry, fully drain, then recycle again. The structure is asserted consistent after
  ///         every step.
  function test_dataStructure_massiveLifecycle() public {
    uint40 t0 = uint40(block.timestamp);
    uint40 active = t0 + TIMELOCK;
    uint40 expiry = active + 30 days;

    // --- Phase 1: fill the slab to MAX_OFFERS; allocation hands out ids 0, 1, 2, ... in order. ---
    for (uint256 i; i < MAX_OFFERS; ++i) {
      uint128 debtShares = 1e18;
      // collateral 1.1e18 .. 2.65e18 => ratio 1.1 .. 2.65, all strictly below the position ratio
      // (4), so every offer is profitable and strictly de-risking. Higher id => higher ratio =>
      // pricier in shares-per-collateral terms... cheaper for the owner; the consume walk visits
      // the LOWEST-collateral (lowest bonus) offer first.
      uint128 collateral = uint128(1.1e18 + i * 5e16);
      uint8 id = h.insert(address(uint160(0xAAAA + i)), active, expiry, collateral, debtShares);
      assertEq(id, uint8(i), "lowest free id allocated");
      _assertStructure();
    }
    assertEq(h.count(), MAX_OFFERS, "slab filled");
    assertEq(h.liveBits(), type(uint32).max, "all bits set");

    // --- Phase 2: a further insert reverts (slab full). ---
    vm.expectRevert(LibBorrowErrors.TooManyOffers.selector);
    h.insert(address(0xBEEF), active, expiry, 2e18, 1e18);

    // --- Phase 3: remove at the low end, the high end, and several middle ids. ---
    h.removeOffer(0);
    _assertStructure();
    h.removeOffer(uint8(MAX_OFFERS - 1));
    _assertStructure();
    h.removeOffer(16);
    _assertStructure();
    h.removeOffer(3);
    _assertStructure();
    h.removeOffer(27);
    _assertStructure();
    assertEq(h.count(), MAX_OFFERS - 5, "five removed");
    // A removed id is no longer removable.
    vm.expectRevert(LibBorrowErrors.OfferNotFound.selector);
    h.removeOffer(16);

    // --- Phase 4: recreate; each insert must recycle the LOWEST freed id (0, 3, 16, 27, 31). ---
    uint8[5] memory expectedIds = [0, 3, 16, 27, uint8(MAX_OFFERS - 1)];
    for (uint256 i; i < 5; ++i) {
      uint128 collateral = uint128(1.5e18 + i * 1e17);
      uint8 id = h.insert(address(uint160(0xCCCC + i)), active, expiry, collateral, 1e18);
      assertEq(id, expectedIds[i], "lowest freed id recycled");
      _assertStructure();
    }
    assertEq(h.count(), MAX_OFFERS, "refilled to capacity");

    // --- Phase 5: activate, then consume a moderate target. The walk is sorted by effective
    //     price at consume time, so the id-1 offer (collateral 1.15e18, the cheapest live one now
    //     that the original id-0 was replaced by a 1.5e18 offer) drains first, then id 2
    //     (1.2e18) partially, and no other offer is touched. ---
    vm.warp(active + 1);
    (uint256 seized, uint256 repaid) = h.consume(_input(2e18, 0));
    assertEq(seized, 2e18, "seize target met exactly");
    assertGt(repaid, 0, "shares repaid");
    assertFalse(h.isLive(1), "cheapest offer exhausted and removed");
    assertEq(h.slabAt(2).remainingCollateral, 1.2e18 - (2e18 - 1.15e18), "second-cheapest partially filled");
    // The partial fill's debt shares round up: ceil(0.85e18 * 1e18 / 1.2e18).
    uint256 partialFillShares = (uint256(0.85e18) * 1e18 + 1.2e18 - 1) / 1.2e18;
    assertEq(h.slabAt(2).remainingDebtShares, 1e18 - partialFillShares, "partial fill decremented debt shares");
    assertEq(h.count(), MAX_OFFERS - 1, "exactly one offer removed");
    _assertStructure();

    // --- Phase 6: warp past expiry; a large consume prunes every remaining (now expired) offer. ---
    vm.warp(expiry + 1);
    (seized, repaid) = h.consume(_input(POSITION_COLLATERAL, 0));
    assertEq(seized, 0, "nothing consumable after expiry");
    _assertStructure();
    assertEq(h.count(), 0, "all expired offers pruned");
    assertEq(h.liveBits(), 0, "bitmap empty");

    // --- Phase 7: after a full drain, inserts start over at id 0 and the structure stays valid. ---
    uint40 active2 = uint40(block.timestamp) + TIMELOCK;
    uint8 recycled = h.insert(address(0xD00D), active2, active2 + 1 days, 2e18, 1e18);
    assertEq(recycled, 0, "allocation restarts at the lowest id");
    _assertStructure();
    assertEq(h.count(), 1, "one live offer again");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       DORMANT WINDOW                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A freshly-deployed harness has an all-zero offer namespace (the state of an existing
  ///         version-1 proxy right after the beacon upgrade, before any offer is proposed). With
  ///         the liveness bitmap this state is structurally an empty book (`liveBits == 0`), so
  ///         every reader must degrade gracefully (empty / zero) with no initialization step.
  function test_dormantWindow_allReadersSafe() public {
    BorrowOffersHarness fresh = new BorrowOffersHarness(); // storage entirely zero
    assertEq(fresh.count(), 0, "count zero");
    assertEq(fresh.liveBits(), 0, "no live bits");

    assertEq(fresh.listOffers().length, 0, "listOffers empty");

    LibBorrowOffers.ConsumeInput memory inp = _input(1e18, 0);
    (uint256 ps, uint256 pd) = fresh.previewConsume(inp);
    assertEq(ps, 0, "preview seize 0");
    assertEq(pd, 0, "preview shares 0");
    (uint256 cs, uint256 cd) = fresh.consume(inp);
    assertEq(cs, 0, "consume seize 0");
    assertEq(cd, 0, "consume shares 0");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      BITMAP GEOMETRY                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice `liveBits` is a `uint32`, so the slab cap must fit it (the natspec contract on
  ///         {MAX_OFFERS}).
  function test_maxOffersFitsBitmapWidth() public pure {
    assertLe(MAX_OFFERS, 32, "MAX_OFFERS must fit the uint32 liveBits bitmap");
  }

  function test_removeOffer_revertsOutOfRangeAndNonLive() public {
    // Out-of-range id.
    vm.expectRevert(LibBorrowErrors.OfferNotFound.selector);
    h.removeOffer(uint8(MAX_OFFERS));
    vm.expectRevert(LibBorrowErrors.OfferNotFound.selector);
    h.removeOffer(type(uint8).max);
    // In-range but never-allocated id.
    vm.expectRevert(LibBorrowErrors.OfferNotFound.selector);
    h.removeOffer(0);
  }

  function test_removeOffer_clearsSlotCompletely() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint8 id = h.insert(address(0xAAAA), active, active + 1 days, 2e18, 1e18);
    h.removeOffer(id);
    assertFalse(h.isLive(id), "bit cleared");
    Offer memory slot = h.slabAt(id);
    assertEq(slot.proposer, address(0), "proposer zeroed");
    assertEq(slot.activeAt, 0, "activeAt zeroed");
    assertEq(slot.expiresAt, 0, "expiresAt zeroed");
    assertEq(slot.remainingCollateral, 0, "collateral zeroed");
    assertEq(slot.remainingDebtShares, 0, "debt shares zeroed");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  SORTED-AT-CONSUME WALK                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The consume walk drains offers in ascending effective-price order regardless of the
  ///         order (and slab ids) they were inserted with. Asserted via the OfferConsumed event
  ///         sequence and the exact per-offer fills.
  function test_consume_drainsAscendingPrice() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    // Insert shuffled: collateral (price) per id: id0=1.8, id1=1.2, id2=2.2, id3=1.5 (shares 1e18
    // each, unit price => whole-offer price == collateral). Ascending price: id1, id3, id0, id2.
    h.insert(address(0xA0), active, expiry, 1.8e18, 1e18);
    h.insert(address(0xA1), active, expiry, 1.2e18, 1e18);
    h.insert(address(0xA2), active, expiry, 2.2e18, 1e18);
    h.insert(address(0xA3), active, expiry, 1.5e18, 1e18);
    vm.warp(active + 1);

    // Target spans the three cheapest (1.2 + 1.5 + 1.8 = 4.5e18) and half of the priciest.
    vm.recordLogs();
    (uint256 seized,) = h.consume(_input(5.6e18, 0));
    assertEq(seized, 5.6e18, "target met");

    // Full event check: ids in ascending price order, exact fill values, exhausted flags. The
    // partial fill charges ceil(1.1e18 * 1e18 / 2.2e18) = 0.5e18 debt shares.
    uint8[4] memory expectedOrder = [1, 3, 0, 2];
    uint128[4] memory expectedColl = [uint128(1.2e18), 1.5e18, 1.8e18, 1.1e18];
    uint128[4] memory expectedShares = [uint128(1e18), 1e18, 1e18, 0.5e18];
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 n;
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] != IBorrowOffers.OfferConsumed.selector) continue;
      assertEq(uint256(logs[i].topics[1]), expectedOrder[n], "consumed in ascending price order");
      (uint128 collFilled, uint128 sharesFilled, bool exhausted) = abi.decode(logs[i].data, (uint128, uint128, bool));
      assertEq(collFilled, expectedColl[n], "event collateral fill");
      assertEq(sharesFilled, expectedShares[n], "event debt-share fill");
      assertEq(exhausted, n < 3, "event exhausted flag");
      ++n;
    }
    assertEq(n, 4, "four offers touched");

    // The three cheapest are exhausted; the priciest is partially filled with the remainder, on
    // BOTH sides of the write-back (collateral and debt shares).
    assertFalse(h.isLive(1), "cheapest exhausted");
    assertFalse(h.isLive(3), "second exhausted");
    assertFalse(h.isLive(0), "third exhausted");
    assertEq(h.slabAt(2).remainingCollateral, 2.2e18 - 1.1e18, "priciest partially filled");
    assertEq(h.slabAt(2).remainingDebtShares, 1e18 - 0.5e18, "partial fill decremented debt shares");
    _assertStructure();
  }

  /// @notice A below-floor (but still profitable) offer at the cheap end of the book is skipped,
  ///         not consumed and not pruned, and does NOT block a pricier offer that clears the floor.
  function test_consume_skipsBelowFloor_consumesPricier() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    // Offer A: price 1.005 (0.5% bonus, below the 1% floor). Offer B: price 1.5 (50% bonus).
    // A sorts first (cheapest); the walk must skip it and still consume B.
    uint8 a = h.insert(address(0xA0), active, expiry, 1.005e18, 1e18);
    uint8 b = h.insert(address(0xB0), active, expiry, 1.5e18, 1e18);
    vm.warp(active + 1);

    LibBorrowOffers.ConsumeInput memory inp = _input(POSITION_COLLATERAL, 0);
    inp.minOfferBonusBps = 100; // 1% consume-time floor
    (uint256 seized,) = h.consume(inp);

    assertEq(seized, 1.5e18, "only the above-floor offer consumed");
    assertTrue(h.isLive(a), "below-floor offer left in the book");
    assertEq(h.slabAt(a).remainingCollateral, 1.005e18, "below-floor offer untouched");
    assertFalse(h.isLive(b), "above-floor offer exhausted");
    _assertStructure();
  }

  /// @notice An over-max-price offer (one whose fill would not strictly lower the LTV) STOPS the
  ///         walk: with the walk sorted ascending in price, nothing later can qualify, so pricier
  ///         offers after it are untouched even when the target has room left.
  function test_consume_stopsAtOverPrice_nothingLaterConsumed() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    // Position ratio 4 => strict de-risking admits only prices strictly below ~4. Offers at 2
    // (ok), 5 and 6 (both over). The walk must consume the first and stop at the second.
    uint8 ok = h.insert(address(0xA0), active, expiry, 2e18, 1e18);
    uint8 over1 = h.insert(address(0xB0), active, expiry, 5e18, 1e18);
    uint8 over2 = h.insert(address(0xC0), active, expiry, 6e18, 1e18);
    vm.warp(active + 1);

    (uint256 seized,) = h.consume(_input(POSITION_COLLATERAL, 0));

    assertEq(seized, 2e18, "only the in-price offer consumed");
    assertFalse(h.isLive(ok), "in-price offer exhausted");
    assertTrue(h.isLive(over1), "over-price offer untouched (Stop)");
    assertEq(h.slabAt(over1).remainingCollateral, 5e18, "over-price offer amounts unchanged");
    assertTrue(h.isLive(over2), "nothing after the Stop consumed");
    assertEq(h.slabAt(over2).remainingCollateral, 6e18, "later offer amounts unchanged");
    _assertStructure();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   FILL-MATH REGRESSIONS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice When the position-shares clamp binds mid-walk in seizedAssets mode, the seized
  ///         collateral is RESCALED down to the offer's fixed ratio: the liquidator does not keep
  ///         the full collateral chunk for fewer shares. Two identical offers of (48e18 collateral,
  ///         40e18 debt shares) against a position owing 70e18 shares: the first fills whole, the
  ///         second is clamped to the remaining 30e18 shares and its collateral rescales to
  ///         30e18 * 48 / 40 = 36e18, for totals (84e18, 70e18) rather than (96e18, 70e18).
  function test_consume_positionClampRescalesCollateral_seizedAssetsMode() public {
    LibBorrowOffers.ConsumeInput memory inp = _clampScenario();
    inp.seizedTarget = 96e18;

    (uint256 seized, uint256 repaid) = h.consume(inp);

    assertEq(seized, 84e18, "collateral rescaled to the offer ratio (48e18 + 36e18)");
    assertEq(repaid, 70e18, "whole position debt repaid");
    _assertClampScenarioWriteBack();
  }

  /// @notice Same rescale in repaidShares mode: a share target above the position's debt (80e18 vs
  ///         70e18) clamps to the position and the second offer's collateral rescales, for totals
  ///         (84e18, 70e18).
  function test_consume_positionClampRescalesCollateral_repaidSharesMode() public {
    LibBorrowOffers.ConsumeInput memory inp = _clampScenario();
    inp.repaidSharesTarget = 80e18;

    (uint256 seized, uint256 repaid) = h.consume(inp);

    assertEq(seized, 84e18, "collateral rescaled to the offer ratio (48e18 + 36e18)");
    assertEq(repaid, 70e18, "repayment clamped to the position's shares");
    _assertClampScenarioWriteBack();
  }

  /// @dev Books the two-offer position-clamp scenario (offers active, targets left to the caller)
  ///      and returns the matching consume input.
  function _clampScenario() internal returns (LibBorrowOffers.ConsumeInput memory inp) {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    h.insert(address(0xA0), active, expiry, 48e18, 40e18);
    h.insert(address(0xA1), active, expiry, 48e18, 40e18);
    vm.warp(active + 1);

    inp = _input(0, 0); // caller sets exactly one target
    inp.positionCollateral = 280e18; // ratio 4, above the offers' 1.2: fills are de-risking
    inp.positionBorrowShares = 70e18;
  }

  /// @dev Asserts the write-back of the clamp scenario: first offer exhausted, second decremented
  ///      by the rescaled fill (36e18 collateral, 30e18 shares) on BOTH sides.
  function _assertClampScenarioWriteBack() internal view {
    assertFalse(h.isLive(0), "first offer exhausted");
    assertTrue(h.isLive(1), "second offer only partially filled");
    assertEq(h.slabAt(1).remainingCollateral, 12e18, "rescaled collateral fill written back");
    assertEq(h.slabAt(1).remainingDebtShares, 10e18, "clamped share fill written back");
    _assertStructure();
  }

  /// @notice In repaidShares mode, an offer whose ratio floors the remaining share target to zero
  ///         collateral is SKIPPED (not a walk-stopping condition): a later, pricier offer carries
  ///         more collateral per debt share and can still produce a non-zero fill for the same
  ///         target.
  function test_consume_zeroCollateralFillSkips_laterOfferConsumed() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    // Offer A asks 9.5e14 shares per collateral wei and sorts first (cheapest); for the
    // 9e14-share target its collateral floors to zero (9e14 * 1 / 9.5e14 = 0). Offer B asks
    // 8.5e14 shares per collateral wei: floor(9e14 * 10 / 8.5e15) = 1 collateral wei for
    // ceil(1 * 8.5e15 / 10) = 8.5e14 shares.
    uint8 a = h.insert(address(0xA0), active, expiry, 1, 9.5e14);
    uint8 b = h.insert(address(0xB0), active, expiry, 10, 8.5e15);
    vm.warp(active + 1);

    LibBorrowOffers.ConsumeInput memory inp = LibBorrowOffers.ConsumeInput({
      seizedTarget: 0,
      repaidSharesTarget: 9e14,
      price: 1e9 * ORACLE_PRICE_SCALE, // 1 collateral wei is worth 1e9 loan wei
      totalBorrowAssets: 1e12,
      totalBorrowShares: 1e18,
      positionCollateral: 100,
      positionBorrowShares: 8e16,
      minOfferBonusBps: 500
    });
    (uint256 seized, uint256 repaid) = h.consume(inp);

    assertEq(seized, 1, "later offer filled for one collateral wei");
    assertEq(repaid, 8.5e14, "share fill at the later offer's ratio");
    assertTrue(h.isLive(a), "zero-fill offer left in the book");
    assertEq(h.slabAt(a).remainingCollateral, 1, "zero-fill offer untouched");
    assertTrue(h.isLive(b), "later offer partially filled");
    assertEq(h.slabAt(b).remainingCollateral, 9, "later offer collateral decremented");
    assertEq(h.slabAt(b).remainingDebtShares, 8.5e15 - 8.5e14, "later offer debt shares decremented");
    _assertStructure();
  }

  /// @notice In seizedAssets mode, an offer whose position-shares clamp RESCALES its collateral
  ///         down to zero is SKIPPED (not consumed, not a walk-stopping condition) and left fully
  ///         untouched: a later, pricier offer carries more collateral per debt share and can
  ///         still fill against the same tiny position. Offer A (1 collateral, 10 debt shares)
  ///         sorts first (10 debt shares per collateral unit vs B's 0.8); against a position owing
  ///         only 5 shares the clamp binds on A (10 > 5) and floor(5 * 1 / 10) = 0 collateral.
  function test_consume_clampRescaleToZeroSkips_laterOfferConsumed() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    uint8 a = h.insert(address(0xA0), active, expiry, 1, 10);
    uint8 b = h.insert(address(0xB0), active, expiry, 10, 8);
    vm.warp(active + 1);

    LibBorrowOffers.ConsumeInput memory inp = _input(10, 0); // seizedAssets mode, target 10 >= 1
    inp.positionCollateral = 40; // ratio 8, above B's 1.25: B's fill is strictly de-risking
    inp.positionBorrowShares = 5; // below A's 10 debt shares, so the clamp binds on A

    (uint256 seized, uint256 repaid) = h.consume(inp);

    // B's fill: fillShares = ceil(10 * 8 / 10) = 8 clamps to the position's 5 shares and the
    // collateral rescales to floor(5 * 10 / 8) = 6 (seizedValue 6 > repaidDebtValue 5 at unit
    // price and 1:1 totals: profitable, and fullMulDiv(6, 5, 5) = 6 < 40: strictly de-risking).
    assertEq(seized, 6, "later offer filled at the rescaled collateral");
    assertEq(repaid, 5, "repayment clamped to the position's shares");
    assertTrue(h.isLive(a), "zero-rescale offer left in the book");
    assertEq(h.slabAt(a).remainingCollateral, 1, "zero-rescale offer collateral untouched");
    assertEq(h.slabAt(a).remainingDebtShares, 10, "zero-rescale offer debt shares untouched");
    assertTrue(h.isLive(b), "later offer partially filled");
    assertEq(h.slabAt(b).remainingCollateral, 4, "later offer collateral decremented");
    assertEq(h.slabAt(b).remainingDebtShares, 3, "later offer debt shares decremented");
    _assertStructure();
  }

  /// @notice A slab full of EXPIRED offers self-heals: the allocator prunes expired slots before
  ///         allocating, so a new insert succeeds (recycling the lowest pruned id) instead of
  ///         reverting {TooManyOffers}, and every pruned slot is fully zeroed with `liveBits` in
  ///         agreement.
  function test_insert_prunesExpiredSlab_insteadOfTooManyOffers() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    for (uint256 i; i < MAX_OFFERS; ++i) {
      h.insert(address(uint160(0xAAAA + i)), active, expiry, uint128(1.1e18 + i * 1e16), 1e18);
    }
    assertEq(h.count(), MAX_OFFERS, "slab filled");

    // While the book is unexpired, a full slab still rejects new offers.
    vm.expectRevert(LibBorrowErrors.TooManyOffers.selector);
    h.insert(address(0xBEEF), active, expiry, 2e18, 1e18);

    // Past expiry the whole book is dead weight: the next insert prunes it and allocates id 0.
    vm.warp(expiry);
    uint40 active2 = uint40(block.timestamp) + TIMELOCK;
    uint8 id = h.insert(address(0xD00D), active2, active2 + 1 days, 2e18, 1e18);

    assertEq(id, 0, "lowest pruned id recycled");
    assertEq(h.count(), 1, "only the new offer is live");
    assertEq(h.liveBits(), 1, "bitmap holds exactly bit 0");
    assertEq(h.slabAt(0).proposer, address(0xD00D), "new offer stored in slot 0");
    for (uint8 slot = 1; slot < MAX_OFFERS; ++slot) {
      Offer memory pruned = h.slabAt(slot);
      assertEq(pruned.proposer, address(0), "pruned slot proposer zeroed");
      assertEq(pruned.activeAt, 0, "pruned slot activeAt zeroed");
      assertEq(pruned.expiresAt, 0, "pruned slot expiry zeroed");
      assertEq(pruned.remainingCollateral, 0, "pruned slot collateral zeroed");
      assertEq(pruned.remainingDebtShares, 0, "pruned slot debt shares zeroed");
    }
    _assertStructure();
  }

  /// @notice A slab full of merely-ACTIVE offers (activeAt passed, expiresAt far in the future) is
  ///         NOT pruned by the allocator: the next insert reverts {TooManyOffers} and every offer
  ///         is left exactly as stored. The allocator's prune condition is expiry, never
  ///         activation; a live, consumable book must not be destroyed by a new proposal.
  function test_insert_fullActiveSlab_revertsWithoutPruning() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 30 days;
    for (uint256 i; i < MAX_OFFERS; ++i) {
      h.insert(address(uint160(0xAAAA + i)), active, expiry, uint128(1.1e18 + i * 1e16), 1e18);
    }
    assertEq(h.count(), MAX_OFFERS, "slab filled");

    // Past activation, well before expiry: every offer is merely active, none is prunable.
    vm.warp(active + 1);
    uint40 active2 = uint40(block.timestamp) + TIMELOCK;
    vm.expectRevert(LibBorrowErrors.TooManyOffers.selector);
    h.insert(address(0xBEEF), active2, active2 + 1 days, 2e18, 1e18);

    // The rejected insert pruned nothing: count, bitmap and every offer's fields are untouched.
    assertEq(h.count(), MAX_OFFERS, "no active offer pruned");
    assertEq(h.liveBits(), type(uint32).max, "all bits still set");
    for (uint8 id; id < MAX_OFFERS; ++id) {
      Offer memory offer = h.slabAt(id);
      assertEq(offer.proposer, address(uint160(0xAAAA + id)), "active offer proposer untouched");
      assertEq(offer.activeAt, active, "active offer activeAt untouched");
      assertEq(offer.expiresAt, expiry, "active offer expiry untouched");
      assertEq(offer.remainingCollateral, uint128(1.1e18 + uint256(id) * 1e16), "active offer collateral untouched");
      assertEq(offer.remainingDebtShares, 1e18, "active offer debt shares untouched");
    }
    _assertStructure();
  }

  /// @notice Mixed-book recycle: with the slab full and exactly ONE offer past its expiry, the
  ///         next insert prunes and recycles exactly that id (no {TooManyOffers}), the book is
  ///         back at capacity, and the 31 still-live offers are untouched.
  function test_insert_recyclesOnlyExpiredSlot_othersUntouched() public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 longExpiry = active + 30 days;
    uint40 shortExpiry = active + 1 days;
    uint8 shortId = 7;
    for (uint256 i; i < MAX_OFFERS; ++i) {
      uint40 expiry = i == shortId ? shortExpiry : longExpiry;
      h.insert(address(uint160(0xAAAA + i)), active, expiry, uint128(1.1e18 + i * 1e16), 1e18);
    }
    assertEq(h.count(), MAX_OFFERS, "slab filled");

    // Past the short expiry only: the other offers are live (and merely active, so not prunable).
    vm.warp(shortExpiry);
    uint40 active2 = uint40(block.timestamp) + TIMELOCK;
    uint8 id = h.insert(address(0xD00D), active2, active2 + 1 days, 2e18, 1e18);

    assertEq(id, shortId, "exactly the expired slot recycled");
    assertEq(h.count(), MAX_OFFERS, "book back at capacity");
    assertEq(h.liveBits(), type(uint32).max, "all bits set again");
    assertEq(h.slabAt(shortId).proposer, address(0xD00D), "new offer stored in the recycled slot");
    for (uint8 slot; slot < MAX_OFFERS; ++slot) {
      if (slot == shortId) continue;
      Offer memory offer = h.slabAt(slot);
      assertEq(offer.proposer, address(uint160(0xAAAA + slot)), "live offer proposer untouched");
      assertEq(offer.activeAt, active, "live offer activeAt untouched");
      assertEq(offer.expiresAt, longExpiry, "live offer expiry untouched");
      assertEq(offer.remainingCollateral, uint128(1.1e18 + uint256(slot) * 1e16), "live offer collateral untouched");
      assertEq(offer.remainingDebtShares, 1e18, "live offer debt shares untouched");
    }
    _assertStructure();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         FUZZ TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A long, fuzzer-seeded interleaving of inserts and removals keeps the bitmap and the
  ///         slab in exact agreement, always allocates the lowest free id, and never exceeds the
  ///         cap.
  function testFuzz_allocFreeRecycling(uint256 seed) public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    uint40 expiry = active + 1 days;
    for (uint256 i; i < 80; ++i) {
      seed = uint256(keccak256(abi.encode(seed, i)));
      if (seed % 3 == 0 && h.count() > 0) {
        h.removeOffer(_liveIdAt(uint8(seed % h.count())));
      } else if (h.count() < MAX_OFFERS) {
        uint128 debtShares = uint128(_bound(seed, 1, 1e21));
        uint128 collateral =
          uint128(_bound(uint256(keccak256(abi.encode(seed, "c"))), uint256(debtShares) + 1, uint256(debtShares) * 5));
        uint8 id = h.insert(address(uint160(seed | 1)), active, expiry, collateral, debtShares);
        assertEq(id, _lowestFreeIdBefore(id), "lowest free id allocated");
      }
      _assertStructure();
    }
  }

  /// @notice KEY equivalence fuzz: for random mixed books (profitable, below-floor, unprofitable,
  ///         over-price, expired, inactive offers) and a random target, `previewConsume` predicts
  ///         the realized `(seized, repaid)` exactly, the walk never overshoots the target, and the
  ///         post-consume storage is consistent (expired pruned, inactive untouched, every live
  ///         slot in agreement with the bitmap).
  function testFuzz_previewEqualsConsume_writeBackConsistent(
    uint96[12] memory collSeeds,
    uint96[12] memory shareSeeds,
    uint8[12] memory kindSeeds,
    uint256 targetSeed,
    bool seizeMode,
    uint256 floorSeed
  ) public {
    uint40 active = uint40(block.timestamp) + TIMELOCK;
    for (uint256 i; i < collSeeds.length; ++i) {
      uint128 debtShares = uint128(_bound(shareSeeds[i], 1, 1e20));
      uint256 kind = kindSeeds[i] % 5;
      uint128 collateral;
      uint40 activeAt = active;
      uint40 expiresAt = active + 30 days;
      if (kind == 0) {
        // Profitable and de-risking: ratio (1, 3].
        collateral = uint128(_bound(collSeeds[i], uint256(debtShares) + 1, uint256(debtShares) * 3));
      } else if (kind == 1) {
        // Unprofitable: ratio (0, 1].
        collateral = uint128(_bound(collSeeds[i], 1, uint256(debtShares)));
      } else if (kind == 2) {
        // Over max price: ratio (4, 6] (position ratio is 4).
        collateral = uint128(_bound(collSeeds[i], uint256(debtShares) * 4 + 1, uint256(debtShares) * 6));
      } else if (kind == 3) {
        // Expires the second it becomes active: expired by consume time.
        collateral = uint128(_bound(collSeeds[i], uint256(debtShares) + 1, uint256(debtShares) * 3));
        expiresAt = active + 1;
      } else {
        // Not yet active at consume time.
        collateral = uint128(_bound(collSeeds[i], uint256(debtShares) + 1, uint256(debtShares) * 3));
        activeAt = active + 60 days;
        expiresAt = active + 90 days;
      }
      h.insert(address(uint160(0x200 + i)), activeAt, expiresAt, collateral, debtShares);
    }
    vm.warp(active + 2); // kind-3 offers are expired, kind-4 not yet active

    LibBorrowOffers.ConsumeInput memory inp =
      seizeMode ? _input(_bound(targetSeed, 1, 5e21), 0) : _input(0, _bound(targetSeed, 1, 2e21));
    inp.minOfferBonusBps = _bound(floorSeed, 0, 1_000);

    // Snapshot the pre-consume book.
    Offer[] memory before = new Offer[](MAX_OFFERS);
    bool[] memory liveBefore = new bool[](MAX_OFFERS);
    for (uint8 id; id < MAX_OFFERS; ++id) {
      before[id] = h.slabAt(id);
      liveBefore[id] = h.isLive(id);
    }

    // previewConsume is a view: it must predict the consume result for the exact same state.
    (uint256 predSeized, uint256 predShares) = h.previewConsume(inp);
    vm.recordLogs();
    (uint256 actSeized, uint256 actShares) = h.consume(inp);
    assertEq(actSeized, predSeized, "preview seized != actual");
    assertEq(actShares, predShares, "preview shares != actual");

    // The walk never overshoots the liquidator target.
    if (seizeMode) assertLe(actSeized, inp.seizedTarget, "seize target overshot");
    else assertLe(actShares, inp.repaidSharesTarget, "share target overshot");

    // The OfferConsumed events are the walk's own account of its fills: they must sum to the
    // returned totals, fire in ascending-price order (on the pre-consume amounts), and match the
    // post-consume storage exactly (partial fills decrement BOTH sides; an exhausted offer had one
    // side filled completely and its slot deleted).
    _assertConsumedEventsMatchState(before, actSeized, actShares);

    // Post-consume storage consistency, offer by offer.
    uint256 seizedAccounted;
    for (uint8 id; id < MAX_OFFERS; ++id) {
      Offer memory afterOffer = h.slabAt(id);
      if (!liveBefore[id]) continue;
      if (block.timestamp >= before[id].expiresAt) {
        // Expired: pruned by the consume write-back.
        assertFalse(h.isLive(id), "expired offer not pruned");
      } else if (block.timestamp < before[id].activeAt) {
        // Inactive: untouched.
        assertTrue(h.isLive(id), "inactive offer must stay");
        assertEq(afterOffer.remainingCollateral, before[id].remainingCollateral, "inactive offer mutated");
      } else if (h.isLive(id)) {
        // Still live: untouched or partially filled, never zeroed on either side.
        assertLe(afterOffer.remainingCollateral, before[id].remainingCollateral, "collateral grew");
        assertLe(afterOffer.remainingDebtShares, before[id].remainingDebtShares, "debt shares grew");
        assertGt(afterOffer.remainingCollateral, 0, "live offer with zero collateral");
        assertGt(afterOffer.remainingDebtShares, 0, "live offer with zero debt shares");
        seizedAccounted += before[id].remainingCollateral - afterOffer.remainingCollateral;
      } else {
        // Consumed to exhaustion: at most its whole remaining collateral was seized.
        seizedAccounted += before[id].remainingCollateral;
      }
    }
    assertLe(actSeized, seizedAccounted, "seized more than the touched offers held");
    _assertStructure();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                STRUCTURAL ASSERTION HELPERS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Decodes the recorded OfferConsumed events and asserts they agree with the pre-consume
  ///      snapshot, the post-consume storage and the returned totals (see the fuzz call site).
  function _assertConsumedEventsMatchState(Offer[] memory before, uint256 actSeized, uint256 actShares) internal {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 sumColl;
    uint256 sumShares;
    uint256 prevId = type(uint256).max; // sentinel: no previous consumed offer yet
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] != IBorrowOffers.OfferConsumed.selector) continue;
      uint256 id = uint256(logs[i].topics[1]);
      (uint128 collFilled, uint128 sharesFilled, bool exhausted) = abi.decode(logs[i].data, (uint128, uint128, bool));
      sumColl += collFilled;
      sumShares += sharesFilled;
      assertGt(collFilled, 0, "event with zero collateral fill");
      assertGt(sharesFilled, 0, "event with zero share fill");

      // Per-fill price invariant: the liquidator never pays fewer debt shares per collateral unit
      // than the offer's fixed ratio (share fills round up; the position-shares clamp rescales the
      // collateral down, never the shares).
      assertGe(
        uint256(sharesFilled) * before[id].remainingCollateral,
        uint256(collFilled) * before[id].remainingDebtShares,
        "fill price below the offer's fixed ratio"
      );

      // Ascending-price order: descending debtShares/collateral on the pre-consume amounts.
      if (prevId != type(uint256).max) {
        assertGe(
          uint256(before[prevId].remainingDebtShares) * before[id].remainingCollateral,
          uint256(before[id].remainingDebtShares) * before[prevId].remainingCollateral,
          "events not in ascending price order"
        );
      }
      prevId = id;

      Offer memory afterOffer = h.slabAt(uint8(id));
      if (exhausted) {
        assertFalse(h.isLive(uint8(id)), "exhausted offer still live");
        assertLe(collFilled, before[id].remainingCollateral, "fill exceeds offered collateral");
        assertLe(sharesFilled, before[id].remainingDebtShares, "fill exceeds offered debt shares");
        assertTrue(
          collFilled == before[id].remainingCollateral || sharesFilled == before[id].remainingDebtShares,
          "exhausted offer had neither side filled completely"
        );
      } else {
        assertTrue(h.isLive(uint8(id)), "partially-filled offer not live");
        assertEq(
          before[id].remainingCollateral - afterOffer.remainingCollateral, collFilled, "collateral write-back != fill"
        );
        assertEq(
          before[id].remainingDebtShares - afterOffer.remainingDebtShares, sharesFilled, "debt-share write-back != fill"
        );
      }
    }
    assertEq(sumColl, actSeized, "event fills do not sum to seized total");
    assertEq(sumShares, actShares, "event fills do not sum to repaid total");
  }

  /// @dev Full structural integrity check (mirrors {LibBorrowOffersInvariantTest}'s invariants):
  ///      the bitmap and the slab agree slot by slot (bit set <=> live, non-degenerate offer; bit
  ///      clear <=> fully zeroed slot), no bits beyond `MAX_OFFERS`, and `count`/`listOffers`
  ///      match the bitmap population.
  function _assertStructure() internal view {
    uint256 bits = h.liveBits();
    assertEq(bits >> MAX_OFFERS, 0, "bits set beyond MAX_OFFERS");

    uint256 live;
    for (uint8 id; id < MAX_OFFERS; ++id) {
      Offer memory slot = h.slabAt(id);
      if (bits & (uint256(1) << id) != 0) {
        ++live;
        assertTrue(slot.proposer != address(0), "live offer zero proposer");
        assertTrue(slot.remainingCollateral > 0 && slot.remainingDebtShares > 0, "degenerate live offer");
      } else {
        assertEq(slot.proposer, address(0), "freed slot non-zero proposer");
        assertEq(slot.remainingCollateral, 0, "freed slot non-zero collateral");
        assertEq(slot.remainingDebtShares, 0, "freed slot non-zero debt shares");
        assertEq(slot.activeAt, 0, "freed slot non-zero activeAt");
        assertEq(slot.expiresAt, 0, "freed slot non-zero expiresAt");
      }
    }
    assertEq(h.count(), live, "count != live slots");
    assertEq(h.listOffers().length, live, "listOffers length != live slots");
  }

  /// @dev Returns the nth (0-based, ascending id) live slab id.
  function _liveIdAt(uint8 nth) internal view returns (uint8) {
    uint256 seen;
    for (uint8 id; id < MAX_OFFERS; ++id) {
      if (!h.isLive(id)) continue;
      if (seen == nth) return id;
      ++seen;
    }
    revert("nth live offer out of range");
  }

  /// @dev Recomputes the lowest id that was free before `justAllocated` was handed out (i.e. no
  ///      smaller id may be free now).
  function _lowestFreeIdBefore(uint8 justAllocated) internal view returns (uint8) {
    for (uint8 id; id < justAllocated; ++id) {
      if (!h.isLive(id)) return id; // a smaller free id existed: the allocator misbehaved
    }
    return justAllocated;
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
      positionBorrowShares: POSITION_BORROW_SHARES,
      // These data-structure tests exercise the book/consume mechanics with the bonus floor
      // disabled (0) unless a test sets it explicitly; the floor's end-to-end behavior is covered
      // in MorphoBorrowPositionOffers.t.sol.
      minOfferBonusBps: 0
    });
  }
}
