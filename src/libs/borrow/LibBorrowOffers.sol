// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SharesMathLib} from "./SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {LibBorrowErrors} from "./LibBorrowErrors.sol";
import {IBorrowOffers, Offer} from "../../interfaces/borrow/IBorrowOffers.sol";
import {MAX_OFFERS, NULL, BORROW_OFFERS_STORAGE_SLOT} from "./LibBorrowOffersConstants.sol";

/// @title LibBorrowOffers
/// @author 3F Protocol
/// @notice Storage, data structure, timelock, fill math and the consume walk for the offer-based
///         pre-liquidation feature of {MorphoBorrowPosition}.
/// @dev All functions are `internal`, so they are inlined into {MorphoBorrowPosition}: `msg.sender`,
///      `block.timestamp` and emitted events are exactly as if the code lived in the contract. The
///      library owns its own ERC-7201 namespace (`"borrow.offers.main"`), kept separate from the
///      existing market/LTV storage so the upgrade is storage-safe.
///
///      Core invariants (binding, re-checked per consumed chunk; see
///      BORROW_POSITION_OFFER_LIQUIDATION_SPEC.md §4 / §10):
///      - I1 (profitability): each fill seizes collateral worth strictly more than the debt value
///        it repays (`v > d`).
///      - I2 (strict de-risking): each fill strictly lowers the position LTV, i.e. `v*B < d*V`,
///        equivalently `fullMulDiv(v, B, d) < V`, where `B`/`V` are the running debt/collateral
///        values *before* the fill.
///      Conservative rounding (debt value up, seized value down, `B` up, `V` down) makes both
///      checks strict in the protocol's favour and is load-bearing for Morpho's own health check at
///      the knife edge (see §11.4).
library LibBorrowOffers {
  using FixedPointMathLib for uint256;
  using SharesMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Offer container, stored at {BORROW_OFFERS_STORAGE_SLOT}.
  /// @dev Layout (slot 0 packs to 160 bits; the fixed-size `slab` array starts at slot 1):
  ///      `offerTimelock`(40) + `pendingTimelock`(40) + `pendingTimelockAt`(40) + `head`(8) +
  ///      `tail`(8) + `freeHead`(8) + `count`(8) + `nextFresh`(8).
  ///
  ///      Slab allocation uses a high-water mark (`nextFresh`) plus a recycled free-list
  ///      (`freeHead`, threaded through `Offer.next`). This is a deliberate, gas-favourable
  ///      deviation from a fully pre-threaded free-list: it avoids ~`MAX_OFFERS` cold SSTOREs at
  ///      initialization while keeping ids inside `uint8`. A slab slot is in exactly one state at a
  ///      time: live (reachable from `head` via `next`), free (reachable from `freeHead` via
  ///      `next`), or never-allocated (index `>= nextFresh`).
  struct BorrowOffersStorage {
    // --- timelock (itself timelocked; see {promoteTimelock} / {effectiveTimelock}) ---
    uint40 offerTimelock; // current effective timelock; 0 only in the pre-initializeV2 window
    uint40 pendingTimelock; // scheduled next value (meaningful only when pendingTimelockAt != 0)
    uint40 pendingTimelockAt; // when pendingTimelock becomes effective; 0 == no pending change
    // --- list / slab bookkeeping ---
    uint8 head; // most owner-favorable consumable offer; NULL when empty
    uint8 tail; // least owner-favorable; enables O(1) append during sorted insert
    uint8 freeHead; // head of the recycled free-list; NULL when none recycled
    uint8 count; // number of live offers
    uint8 nextFresh; // next never-allocated slab index (high-water mark)
    Offer[MAX_OFFERS] slab; // ids are slab indices (uint8)
  }

  /// @notice Read-once market/position snapshot threaded through the consume / preview walk.
  /// @dev Exactly one of `seizedTarget` / `repaidSharesTarget` is non-zero (the liquidator's
  ///      target, in offer-native units). The rest is the state captured at walk entry; no Morpho
  ///      state changes mid-walk, so these stay valid for every fill.
  struct ConsumeInput {
    uint256 seizedTarget; // collateral-seize target (0 => repaidShares mode)
    uint256 repaidSharesTarget; // debt-share-repay target (0 => seizedAssets mode)
    uint256 price; // oracle price (ORACLE_PRICE_SCALE-scaled)
    uint256 totalBorrowAssets; // market total borrow assets (post-accrual)
    uint256 totalBorrowShares; // market total borrow shares (post-accrual)
    uint256 positionCollateral; // position collateral at entry
    uint256 positionBorrowShares; // position borrow shares at entry
  }

  /// @dev Per-offer decision returned by {_computeFill}.
  ///      - Consume: fill `(fillCollateral, fillDebtShares)` is profitable and strictly de-risking.
  ///      - Skip: offer is unprofitable / unfillable for this target; advance, leave it in the list
  ///        (or prune it if it is a degenerate zero-remaining slot).
  ///      - Stop: offer is over the max price, or the liquidator target is met / no capacity; since
  ///        the list is sorted ascending in price and not consuming freezes the LTV, nothing later
  ///        can qualify, so the walk halts.
  enum FillAction {
    Skip,
    Stop,
    Consume
  }

  /// @dev Returns the offer storage pointer (ERC-7201 fixed slot).
  function borrowOffersStorage() internal pure returns (BorrowOffersStorage storage s) {
    assembly ("memory-safe") {
      s.slot := BORROW_OFFERS_STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the list/slab bookkeeping for a fresh offer setup.
  /// @dev Leaves `offerTimelock` untouched (set by the caller). With the high-water-mark allocator,
  ///      all slots start as never-allocated, so only the head/tail/free/counters need resetting.
  function initFreeList(BorrowOffersStorage storage s) internal {
    s.head = NULL;
    s.tail = NULL;
    s.freeHead = NULL;
    s.count = 0;
    s.nextFresh = 0;
    s.pendingTimelock = 0;
    s.pendingTimelockAt = 0;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          TIMELOCK                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the effective timelock without writing (promotes a due pending value in the
  ///         computation only).
  function effectiveTimelock(BorrowOffersStorage storage s) internal view returns (uint40) {
    if (s.pendingTimelockAt != 0 && block.timestamp >= s.pendingTimelockAt) return s.pendingTimelock;
    return s.offerTimelock;
  }

  /// @notice Promotes a due pending timelock into `offerTimelock` (clearing the pending slots) and
  ///         returns the now-effective timelock.
  /// @dev Called by state-changing entrypoints ({proposeOffer}, {setOfferTimelock}) so a scheduled
  ///      change lands lazily on the next write. Pure views use {effectiveTimelock} instead.
  function promoteTimelock(BorrowOffersStorage storage s) internal returns (uint40 tl) {
    if (s.pendingTimelockAt != 0 && block.timestamp >= s.pendingTimelockAt) {
      tl = s.pendingTimelock;
      s.offerTimelock = tl;
      s.pendingTimelock = 0;
      s.pendingTimelockAt = 0;
    } else {
      tl = s.offerTimelock;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INSERT / REMOVE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Allocates a slab slot, stores the offer and splices it into the sorted active list,
  ///         then emits {IBorrowOffers.OfferProposed}.
  /// @dev Sort key: descending `debtShares / collateral` (equivalently ascending price `I`), so the
  ///      head is the most owner-favorable offer. The order is a best-effort consumption
  ///      optimization, not a safety invariant: the price `I` also depends on the live oracle price
  ///      and accrued interest (common to all offers) and on partial-fill rounding, so the list can
  ///      drift marginally out of order. Safety comes solely from the per-fill I1/I2 checks.
  /// @return id The slab id assigned.
  function insert(
    BorrowOffersStorage storage s,
    address proposer,
    uint40 activeAt,
    uint40 expiresAt,
    uint128 collateral,
    uint128 debtShares
  ) internal returns (uint8 id) {
    id = _alloc(s);

    // Find the first existing offer with a strictly smaller ratio and insert the new offer before
    // it. Ratio compare without division: existing >= new  <=>  cDebt * collateral >= debtShares *
    // cColl. Walk while existing >= new; stop at the first existing strictly smaller than new.
    // Products are uint128 * uint128 < 2**256, so no overflow.
    uint8 cursor = s.head;
    uint8 prev = NULL;
    while (cursor != NULL) {
      Offer storage cursorOffer = s.slab[cursor];
      if (uint256(cursorOffer.remainingDebtShares) * collateral < uint256(debtShares) * cursorOffer.remainingCollateral)
      {
        break;
      }
      prev = cursor;
      cursor = cursorOffer.next;
    }

    Offer storage newOffer = s.slab[id];
    newOffer.proposer = proposer;
    newOffer.activeAt = activeAt;
    newOffer.expiresAt = expiresAt;
    newOffer.remainingCollateral = collateral;
    newOffer.remainingDebtShares = debtShares;
    newOffer.prev = prev;
    newOffer.next = cursor;

    if (prev == NULL) s.head = id;
    else s.slab[prev].next = id;
    if (cursor == NULL) s.tail = id;
    else s.slab[cursor].prev = id;

    emit IBorrowOffers.OfferProposed(id, proposer, collateral, debtShares, activeAt, expiresAt);
  }

  /// @notice Removes a live offer by id (used by `revokeOffers`).
  /// @dev Reverts {LibBorrowErrors.OfferNotFound} for an out-of-range id or a non-live slot
  ///      (`proposer == address(0)`, which marks a freed / never-allocated slab slot). A live offer
  ///      always has a non-zero proposer.
  function removeOffer(BorrowOffersStorage storage s, uint8 id) internal {
    if (id >= MAX_OFFERS) revert LibBorrowErrors.OfferNotFound();
    if (s.slab[id].proposer == address(0)) revert LibBorrowErrors.OfferNotFound();
    _unlinkAndFree(s, id);
  }

  /// @dev Allocates a slab slot: recycle from the free-list first, else take the next never-used
  ///      index, else revert {LibBorrowErrors.TooManyOffers}. Increments the live count.
  function _alloc(BorrowOffersStorage storage s) private returns (uint8 id) {
    uint8 recycledId = s.freeHead;
    if (recycledId != NULL) {
      id = recycledId;
      s.freeHead = s.slab[recycledId].next;
    } else {
      uint8 freshId = s.nextFresh;
      if (freshId >= MAX_OFFERS) revert LibBorrowErrors.TooManyOffers();
      id = freshId;
      s.nextFresh = freshId + 1;
    }
    s.count += 1;
  }

  /// @dev Unlinks `id` from the active list, clears its slot and pushes it onto the free-list.
  ///      Clearing the slot (a) zeroes `proposer` so the slot reads as non-live and (b) refunds gas.
  function _unlinkAndFree(BorrowOffersStorage storage s, uint8 id) private {
    Offer storage offer = s.slab[id];
    uint8 prevId = offer.prev;
    uint8 nextId = offer.next;

    if (prevId == NULL) s.head = nextId;
    else s.slab[prevId].next = nextId;
    if (nextId == NULL) s.tail = prevId;
    else s.slab[nextId].prev = prevId;

    s.count -= 1;

    offer.proposer = address(0);
    offer.activeAt = 0;
    offer.expiresAt = 0;
    offer.remainingCollateral = 0;
    offer.remainingDebtShares = 0;
    offer.prev = NULL;
    offer.next = s.freeHead; // thread the free-list through `next`
    s.freeHead = id;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSUME                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Walks the sorted list from the head, consuming profitable, strictly-de-risking chunks
  ///         until the liquidator target is met or a stop condition fires.
  /// @dev Effects-before-interaction: all offer mutations (decrements, unlinks, prunes) are applied
  ///      here, before the caller performs the single Morpho `repay`. A reentrant `preLiquidate`
  ///      (via `onPreLiquidate`) therefore observes already-decremented offers and cannot
  ///      double-consume an authorization.
  ///
  ///      Stop conditions (any one halts the walk): liquidator target met; position collateral
  ///      exhausted; position debt exhausted; end of list; head-of-remaining over the max price.
  /// @return totalSeized Total collateral to seize (offer-native units).
  /// @return totalDebtShares Total borrow shares to repay (offer-native units).
  function consume(BorrowOffersStorage storage s, ConsumeInput memory inp)
    internal
    returns (uint256 totalSeized, uint256 totalDebtShares)
  {
    // No live offers: return (0, 0) so the caller reverts NoConsumableOffer. This guard is also
    // what makes the post-upgrade window safe (spec section 12.3): a proxy that has not yet run
    // `initializeV2` has an all-zero offer namespace, so `head == 0` (a valid slab index) rather
    // than the NULL sentinel; without this guard the walk would process the zeroed slab[0], treat
    // it as expired, and underflow `count` in _unlinkAndFree. `count` is the source of truth for
    // live offers, so `count == 0` cleanly captures both the genuinely-empty and the uninitialized
    // state.
    if (s.count == 0) return (0, 0);

    uint8 current = s.head;
    while (current != NULL) {
      Offer storage offer = s.slab[current];
      uint8 next = offer.next; // capture before any unlink mutates the links

      // EXPIRED: opportunistically prune and continue.
      if (block.timestamp >= offer.expiresAt) {
        _unlinkAndFree(s, current);
        current = next;
        continue;
      }
      // NOT YET ACTIVE: skip, leave in the list (its veto window has not elapsed).
      if (block.timestamp < offer.activeAt) {
        current = next;
        continue;
      }

      uint256 remainingPositionShares = inp.positionBorrowShares - totalDebtShares;
      uint256 remainingPositionCollateral = inp.positionCollateral - totalSeized;
      // Position debt or collateral exhausted: nothing more to liquidate.
      if (remainingPositionShares == 0 || remainingPositionCollateral == 0) break;

      (FillAction action, uint256 fillCollateral, uint256 fillShares) =
        _computeFill(inp, offer.remainingCollateral, offer.remainingDebtShares, totalSeized, totalDebtShares);

      if (action == FillAction.Stop) break;
      if (action == FillAction.Skip) {
        // A degenerate zero-remaining slot is pruned; an unprofitable-but-meaningful offer is left
        // in place (it sits at the head and never blocks: its price is fixed by offer terms, so
        // lowering the LTV never makes it profitable).
        if (offer.remainingCollateral == 0 || offer.remainingDebtShares == 0) _unlinkAndFree(s, current);
        current = next;
        continue;
      }

      // CONSUME (effects). `fillCollateral <= remainingCollateral` and `fillShares <=
      // remainingDebtShares` by construction, so the uint128 casts and subtractions cannot
      // overflow/underflow.
      uint128 newCollateral = offer.remainingCollateral - uint128(fillCollateral);
      uint128 newDebtShares = offer.remainingDebtShares - uint128(fillShares);
      bool exhausted = (newCollateral == 0 || newDebtShares == 0);
      offer.remainingCollateral = newCollateral;
      offer.remainingDebtShares = newDebtShares;
      totalSeized += fillCollateral;
      totalDebtShares += fillShares;
      emit IBorrowOffers.OfferConsumed(current, uint128(fillCollateral), uint128(fillShares), exhausted);
      if (exhausted) _unlinkAndFree(s, current);

      // Liquidator target met?
      if (inp.seizedTarget != 0) {
        if (totalSeized >= inp.seizedTarget) break;
      } else {
        if (totalDebtShares >= inp.repaidSharesTarget) break;
      }
      current = next;
    }
  }

  /// @notice Read-only simulation of {consume} for the same inputs (the `previewConsume` helper).
  /// @dev Mirrors {consume}'s control flow exactly minus the writes/events, so the returned totals
  ///      match what a real consume would produce against the same state. Expired / degenerate
  ///      offers are skipped (not pruned) since this is a view.
  function previewConsume(BorrowOffersStorage storage s, ConsumeInput memory inp)
    internal
    view
    returns (uint256 totalSeized, uint256 totalDebtShares)
  {
    // Same guard as {consume}: no live offers (or the uninitialized window state where head == 0)
    // returns (0, 0) instead of walking a zeroed slab (which would loop forever here).
    if (s.count == 0) return (0, 0);

    uint8 current = s.head;
    while (current != NULL) {
      Offer memory offer = s.slab[current];
      uint8 next = offer.next;

      if (block.timestamp >= offer.expiresAt) {
        current = next;
        continue;
      }
      if (block.timestamp < offer.activeAt) {
        current = next;
        continue;
      }

      uint256 remainingPositionShares = inp.positionBorrowShares - totalDebtShares;
      uint256 remainingPositionCollateral = inp.positionCollateral - totalSeized;
      if (remainingPositionShares == 0 || remainingPositionCollateral == 0) break;

      (FillAction action, uint256 fillCollateral, uint256 fillShares) =
        _computeFill(inp, offer.remainingCollateral, offer.remainingDebtShares, totalSeized, totalDebtShares);

      if (action == FillAction.Stop) break;
      if (action == FillAction.Skip) {
        current = next;
        continue;
      }

      totalSeized += fillCollateral;
      totalDebtShares += fillShares;
      if (inp.seizedTarget != 0) {
        if (totalSeized >= inp.seizedTarget) break;
      } else {
        if (totalDebtShares >= inp.repaidSharesTarget) break;
      }
      current = next;
    }
  }

  /// @dev Computes the fill for a single offer and the per-fill decision (pure).
  ///
  ///      Fills are *collateral-driven* for uniform rounding:
  ///      - seizedAssets mode: `fillCollateral = min(offer.remainingCollateral, seizeTargetLeft,
  ///        positionLeft)`.
  ///      - repaidShares mode: `maxFillCollateral = shareTargetLeft * remainingCollateral /
  ///        remainingDebtShares` (rounded down so debt shares cannot overshoot the target);
  ///        `fillCollateral = min(offer.remainingCollateral, maxFillCollateral, positionLeft)`.
  ///      Then `fillShares = fillCollateral.mulDivUp(remainingDebtShares, remainingCollateral)`
  ///      (rounded up, so the chunk's price rounds down: conservative for the cap, and the liquidator
  ///      cannot underpay), clamped to the remaining share target and to the position's remaining
  ///      shares.
  ///
  ///      The two binding checks (I1 profitability, I2 strict de-risk) and their conservative
  ///      (protocol-favorable) rounding are evaluated in {_priceAction}.
  ///
  ///      The position's remaining collateral/shares before this fill (`remainingPositionCollateral`
  ///      / `remainingPositionShares`) are derived from `inp` and the running totals here rather than
  ///      threaded in, to keep the stack shallow (this codebase compiles without the via-IR
  ///      pipeline). Unnamed returns are used for the same reason.
  function _computeFill(
    ConsumeInput memory inp,
    uint256 remainingCollateral,
    uint256 remainingDebtShares,
    uint256 totalSeized,
    uint256 totalDebtShares
  ) private pure returns (FillAction, uint256, uint256) {
    // Degenerate slot (a remaining amount is zero): cannot be filled; the walk prunes it.
    if (remainingCollateral == 0 || remainingDebtShares == 0) return (FillAction.Skip, 0, 0);

    uint256 remainingPositionCollateral = inp.positionCollateral - totalSeized;
    uint256 remainingPositionShares = inp.positionBorrowShares - totalDebtShares;

    uint256 fillCollateral;
    if (inp.seizedTarget != 0) {
      fillCollateral = remainingCollateral.min(inp.seizedTarget - totalSeized).min(remainingPositionCollateral);
    } else {
      // Round down so the implied debt shares never overshoot the remaining share target.
      uint256 maxFillCollateral =
        (inp.repaidSharesTarget - totalDebtShares).mulDiv(remainingCollateral, remainingDebtShares);
      fillCollateral = remainingCollateral.min(maxFillCollateral).min(remainingPositionCollateral);
    }
    // No capacity for this target (target met, or rounds to nothing): halt the walk.
    if (fillCollateral == 0) return (FillAction.Stop, 0, 0);

    uint256 fillShares = fillCollateral.mulDivUp(remainingDebtShares, remainingCollateral);
    if (inp.repaidSharesTarget != 0) {
      uint256 shareTargetLeft = inp.repaidSharesTarget - totalDebtShares;
      if (fillShares > shareTargetLeft) fillShares = shareTargetLeft;
    }
    // Never repay more shares than the position owes.
    if (fillShares > remainingPositionShares) fillShares = remainingPositionShares;
    if (fillShares == 0) return (FillAction.Skip, 0, 0); // cannot charge any shares for this collateral

    // I1/I2 are evaluated in a separate frame ({_priceAction}) to keep this function's stack within
    // the limits of the non-via-IR pipeline.
    FillAction action = _priceAction(
      inp.price,
      inp.totalBorrowAssets,
      inp.totalBorrowShares,
      fillCollateral,
      fillShares,
      remainingPositionCollateral,
      remainingPositionShares
    );
    if (action == FillAction.Consume) return (FillAction.Consume, fillCollateral, fillShares);
    return (action, 0, 0);
  }

  /// @dev Evaluates the two binding per-fill checks on the final fill amounts (pure). The local
  ///      names map to the spec notation (BORROW_POSITION_OFFER_LIQUIDATION_SPEC.md §4 / §10):
  ///      `seizedValue` = v, `repaidDebtValue` = d, `remainingDebtValue` = B,
  ///      `remainingCollateralValue` = V.
  ///      - I1 (profitable): `seizedValue > repaidDebtValue`, else {FillAction.Skip}.
  ///      - I2 (strict de-risk): `v*B < d*V`, else {FillAction.Stop} (over max price).
  ///      Collateral values (`seizedValue`/`remainingCollateralValue`) round down and debt values
  ///      (`repaidDebtValue`/`remainingDebtValue`) round up, so both checks are strict in the
  ///      protocol's favour. `repaidDebtValue > 0` since `fillShares >= 1`.
  ///      `fullMulDiv(v, B, d) < V` is the exact integer form of `v/d < V/B` (i.e. `v*B < d*V`) with
  ///      no intermediate overflow.
  function _priceAction(
    uint256 price,
    uint256 totalBorrowAssets,
    uint256 totalBorrowShares,
    uint256 fillCollateral,
    uint256 fillShares,
    uint256 remainingPositionCollateral,
    uint256 remainingPositionShares
  ) private pure returns (FillAction) {
    uint256 seizedValue = fillCollateral.mulDiv(price, ORACLE_PRICE_SCALE);
    uint256 repaidDebtValue = fillShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    if (seizedValue <= repaidDebtValue) return FillAction.Skip; // I1

    uint256 remainingDebtValue = remainingPositionShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    uint256 remainingCollateralValue = remainingPositionCollateral.mulDiv(price, ORACLE_PRICE_SCALE);
    // I2: fullMulDiv(v, B, d) >= V  <=>  not strictly de-risking.
    if (FixedPointMathLib.fullMulDiv(seizedValue, remainingDebtValue, repaidDebtValue) >= remainingCollateralValue) {
      return FillAction.Stop;
    }

    return FillAction.Consume;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns all live offers ordered head -> tail.
  function listOffers(BorrowOffersStorage storage s) internal view returns (Offer[] memory out) {
    uint8 liveCount = s.count;
    out = new Offer[](liveCount);
    // Same dormant-window guard as {consume} / {previewConsume}: a proxy that has not yet run
    // `initializeV2` has an all-zero offer namespace, so `head == 0` (a valid slab index) rather than
    // the NULL sentinel. Returning the (empty) array now avoids walking the zeroed slab and writing
    // past the length-0 result, which would Panic. `count` is the source of truth for live offers.
    if (liveCount == 0) return out;
    uint8 current = s.head;
    uint256 i;
    while (current != NULL) {
      Offer storage offer = s.slab[current];
      out[i] = offer;
      current = offer.next;
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Evaluates whether `remainingCollateral`/`remainingDebtShares` (the whole remaining
  ///         offer) would pass the I1/I2 gates against the current whole-position state.
  /// @dev Pure helper for the `isConsumable` view. It evaluates the offer's price vs the current
  ///      LTV in isolation: it does not account for list ordering or the cumulative LTV change of
  ///      consuming earlier offers. Returns false if the position has no debt (nothing to liquidate)
  ///      or the offer is degenerate.
  function consumableAtPrice(
    uint256 remainingCollateral,
    uint256 remainingDebtShares,
    uint256 positionCollateral,
    uint256 positionBorrowShares,
    uint256 price,
    uint256 totalBorrowAssets,
    uint256 totalBorrowShares
  ) internal pure returns (bool) {
    if (remainingCollateral == 0 || remainingDebtShares == 0) return false;
    if (positionBorrowShares == 0) return false;

    uint256 seizedValue = remainingCollateral.mulDiv(price, ORACLE_PRICE_SCALE);
    uint256 repaidDebtValue = remainingDebtShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    if (repaidDebtValue == 0) return false;
    if (seizedValue <= repaidDebtValue) return false; // I1

    uint256 remainingDebtValue = positionBorrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    uint256 remainingCollateralValue = positionCollateral.mulDiv(price, ORACLE_PRICE_SCALE);
    // I2: strictly de-risking iff fullMulDiv(v, B, d) < V.
    return FixedPointMathLib.fullMulDiv(seizedValue, remainingDebtValue, repaidDebtValue) < remainingCollateralValue;
  }
}
