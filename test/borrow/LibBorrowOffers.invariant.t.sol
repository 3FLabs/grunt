// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BorrowOffersHarness} from "test/mock/borrow/BorrowOffersHarness.sol";
import {BorrowOffersHandler} from "test/mock/borrow/BorrowOffersHandler.sol";
import {Offer} from "src/interfaces/borrow/IBorrowOffers.sol";
import {MAX_OFFERS} from "src/libs/borrow/LibBorrowOffersConstants.sol";

/// @title LibBorrowOffersInvariantTest
/// @author 3F Protocol
/// @notice Invariant suite for the {LibBorrowOffers} data structure (fixed slab with a liveness
///         bitmap; `liveBits` is the single source of truth for which slots hold live offers).
/// @dev A {BorrowOffersHandler} drives long, mixed sequences of insert / revoke / consume / warp
///      against a {BorrowOffersHarness}. After every sequence these invariants assert that the
///      bitmap and the slab are in exact agreement and corruption-free. They are deliberately
///      self-contained (no economic assumptions): whatever the consume walk does, every set bit
///      must mark a live, non-degenerate offer and every cleared bit a fully-zeroed slot.
///
///      Consume-time ordering is intentionally NOT asserted here: the walk sorts the book by
///      effective price in memory at consume time (nothing about order is stored), and the
///      ascending-price drain is covered deterministically in LibBorrowOffers.t.sol.
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

  /// @notice INV-1: no bits are set at or beyond `MAX_OFFERS` (ids stay within the slab).
  function invariant_noBitsBeyondSlab() public view {
    assertEq(uint256(harness.liveBits()) >> MAX_OFFERS, 0, "INV-1: live bit beyond MAX_OFFERS");
  }

  /// @notice INV-2: every set bit marks a live, non-degenerate offer (non-zero proposer, both
  ///         remaining amounts > 0; consume removes an offer the moment a side hits zero).
  function invariant_setBitsAreLiveOffers() public view {
    uint256 bits = harness.liveBits();
    for (uint8 id; id < MAX_OFFERS; ++id) {
      if (bits & (uint256(1) << id) == 0) continue;
      Offer memory offer = harness.slabAt(id);
      assertTrue(offer.proposer != address(0), "INV-2: live offer has zero proposer");
      assertTrue(offer.remainingCollateral > 0, "INV-2: live offer has zero collateral");
      assertTrue(offer.remainingDebtShares > 0, "INV-2: live offer has zero debt shares");
    }
  }

  /// @notice INV-3: every cleared bit marks a fully-zeroed slab slot (freed slots are `delete`d,
  ///         so a stale slot can never shadow a future allocation).
  function invariant_clearedBitsAreZeroedSlots() public view {
    uint256 bits = harness.liveBits();
    for (uint8 id; id < MAX_OFFERS; ++id) {
      if (bits & (uint256(1) << id) != 0) continue;
      Offer memory slot = harness.slabAt(id);
      assertEq(slot.proposer, address(0), "INV-3: freed slot has non-zero proposer");
      assertEq(slot.activeAt, 0, "INV-3: freed slot has non-zero activeAt");
      assertEq(slot.expiresAt, 0, "INV-3: freed slot has non-zero expiresAt");
      assertEq(slot.remainingCollateral, 0, "INV-3: freed slot has non-zero collateral");
      assertEq(slot.remainingDebtShares, 0, "INV-3: freed slot has non-zero debt shares");
    }
  }

  /// @notice INV-4: the derived views agree with the bitmap: `count` is its population count and
  ///         `listOffers` returns exactly the live offers in ascending id order.
  function invariant_viewsMatchBitmap() public view {
    uint256 bits = harness.liveBits();
    Offer[] memory listed = harness.listOffers();
    uint256 live;
    for (uint8 id; id < MAX_OFFERS; ++id) {
      if (bits & (uint256(1) << id) == 0) continue;
      Offer memory offer = harness.slabAt(id);
      assertEq(listed[live].proposer, offer.proposer, "INV-4: listOffers order/content mismatch");
      assertEq(listed[live].remainingCollateral, offer.remainingCollateral, "INV-4: listOffers amounts mismatch");
      ++live;
    }
    assertEq(listed.length, live, "INV-4: listOffers length != set bits");
    assertEq(harness.count(), live, "INV-4: count != set bits");
    assertLe(live, MAX_OFFERS, "INV-4: count > MAX_OFFERS");
  }
}
