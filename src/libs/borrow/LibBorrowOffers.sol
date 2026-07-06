// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibBit} from "lib/solady/src/utils/LibBit.sol";
import {SharesMathLib} from "./SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {LibBorrowErrors} from "./LibBorrowErrors.sol";
import {IBorrowOffers, Offer} from "../../interfaces/borrow/IBorrowOffers.sol";
import {MAX_OFFERS, BORROW_OFFERS_STORAGE_SLOT} from "./LibBorrowOffersConstants.sol";
import {BPS} from "../Constants.sol";

/// @title LibBorrowOffers
/// @author 3F Protocol
/// @notice Storage, slab bookkeeping, timelock, fill math and the consume walk for the offer-based
///         pre-liquidation feature of {MorphoBorrowPosition}.
/// @dev All functions are `internal`, so they are inlined into {MorphoBorrowPosition}: `msg.sender`,
///      `block.timestamp` and emitted events are exactly as if the code lived in the contract. The
///      library owns its own ERC-7201 namespace (`"borrow.offers.main"`), kept separate from the
///      existing market/LTV storage so the upgrade is storage-safe.
///
///      Offers are held in a fixed slab with a one-bit-per-slot liveness bitmap (`liveBits`); no
///      order is maintained in storage. The consume walk loads the consumable offers into memory,
///      sorts them by effective price at that instant (exact, unlike the storage-order-drift of a
///      sorted-at-insert list), and fills cheapest-first.
///
///      Core invariants (binding, re-checked per consumed chunk; see
///      BORROW_POSITION_OFFER_LIQUIDATION_SPEC.md sections 4 / 10):
///      - I1 (profitability): each fill seizes collateral worth strictly more than the debt value
///        it repays (`v > d`).
///      - I2 (strict de-risking): each fill strictly lowers the position LTV, i.e. `v*B < d*V`,
///        equivalently `fullMulDiv(v, B, d) < V`, where `B`/`V` are the running debt/collateral
///        values *before* the fill.
///      Conservative rounding (debt value up, seized value down, `B` up, `V` down) makes both
///      checks strict in the protocol's favour and is load-bearing for Morpho's own health check at
///      the knife edge (see section 11.4).
library LibBorrowOffers {
  using FixedPointMathLib for uint256;
  using SharesMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Offer container, stored at {BORROW_OFFERS_STORAGE_SLOT}.
  /// @dev Layout (slot 0 packs to 168 bits; the fixed-size `slab` array starts at slot 1):
  ///      `offerTimelock`(40) + `pendingTimelock`(40) + `pendingTimelockAt`(40) + `liveBits`(32) +
  ///      `minOfferBonusBps`(16).
  ///
  ///      `liveBits` is the single source of truth for liveness: bit `i` set <=> `slab[i]` holds a
  ///      live offer. A cleared bit's slab slot is fully zeroed (freed slots are `delete`d), and an
  ///      all-zero namespace (the post-upgrade, pre-`initializeV2` window) structurally reads as an
  ///      empty book. Allocation picks the lowest cleared bit, so ids stay within
  ///      `[0, MAX_OFFERS)` and freed ids are reused.
  struct BorrowOffersStorage {
    // --- timelock (itself timelocked; see {promoteTimelock} / {effectiveTimelock}) ---
    uint40 offerTimelock; // current effective timelock; 0 only in the pre-initializeV2 window
    uint40 pendingTimelock; // scheduled next value (meaningful only when pendingTimelockAt != 0)
    uint40 pendingTimelockAt; // when pendingTimelock becomes effective; 0 == no pending change
    // --- slab bookkeeping ---
    uint32 liveBits; // bit i set <=> slab[i] is a live offer
    // --- proposal admission ---
    uint16 minOfferBonusBps; // minimum offer bonus in basis points; 0 only pre-initializeV2 or if disabled
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
    uint256 minOfferBonusBps; // consume-time bonus floor (basis points); 0 => only strict I1 applies
  }

  /// @notice In-memory image of one consumable offer during the load / sort / walk pipeline.
  /// @dev Loaded by {_loadConsumable}, mutated in place by {_walk} (memory structs are passed by
  ///      reference), and written back to storage by {consume}. The remaining amounts are the
  ///      running values (post-fill after the walk); the filled amounts are the walk's output for
  ///      the write-back and the {IBorrowOffers.OfferConsumed} event.
  struct WalkOffer {
    uint8 id; // slab index
    uint128 remainingCollateral;
    uint128 remainingDebtShares;
    uint128 filledCollateral; // 0 <=> the walk did not touch this offer
    uint128 filledShares;
  }

  /// @dev Per-offer decision returned by {_computeFill}.
  ///      - Consume: fill `(fillCollateral, fillDebtShares)` is profitable and strictly de-risking.
  ///      - Skip: offer is unprofitable / below the bonus floor / unfillable for this target;
  ///        advance to the next offer, leave it in the book.
  ///      - Stop: offer is over the max price, or the liquidator target is met / no capacity; the
  ///        walk visits offers in ascending price order and not consuming freezes the LTV, so
  ///        nothing later can qualify and the walk halts.
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

  /// @notice Resets the offer-book bookkeeping for a fresh offer setup.
  /// @dev Leaves `offerTimelock` and `minOfferBonusBps` untouched (set by the caller).
  function initOfferBook(BorrowOffersStorage storage s) internal {
    s.liveBits = 0;
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

  /// @notice Allocates a slab slot, stores the offer and emits {IBorrowOffers.OfferProposed}.
  /// @dev No ordering is maintained in storage; the consume walk sorts the book by effective price
  ///      in memory at consume time. Amount validation (`> 0`) is done by the caller
  ///      ({MorphoBorrowPosition.proposeOffer}).
  /// @return id The slab id assigned (the lowest free index).
  function insert(
    BorrowOffersStorage storage s,
    address proposer,
    uint40 activeAt,
    uint40 expiresAt,
    uint128 collateral,
    uint128 debtShares
  ) internal returns (uint8 id) {
    id = _alloc(s);

    Offer storage newOffer = s.slab[id];
    newOffer.proposer = proposer;
    newOffer.activeAt = activeAt;
    newOffer.expiresAt = expiresAt;
    newOffer.remainingCollateral = collateral;
    newOffer.remainingDebtShares = debtShares;

    emit IBorrowOffers.OfferProposed(id, proposer, collateral, debtShares, activeAt, expiresAt);
  }

  /// @notice Removes a live offer by id (used by `revokeOffers`).
  /// @dev Reverts {LibBorrowErrors.OfferNotFound} for an out-of-range id or a non-live slot.
  ///      Clearing the slot refunds gas and keeps the "freed slot is fully zeroed" convention.
  function removeOffer(BorrowOffersStorage storage s, uint8 id) internal {
    if (!isLive(s, id)) revert LibBorrowErrors.OfferNotFound();
    s.liveBits = uint32(s.liveBits & ~(uint256(1) << id));
    delete s.slab[id];
  }

  /// @dev Allocates the lowest free slab index and marks it live, or reverts
  ///      {LibBorrowErrors.TooManyOffers} when all `MAX_OFFERS` slots are live.
  function _alloc(BorrowOffersStorage storage s) private returns (uint8 id) {
    uint256 liveBits = s.liveBits;
    uint256 freeBits = ~liveBits & ((uint256(1) << MAX_OFFERS) - 1);
    if (freeBits == 0) revert LibBorrowErrors.TooManyOffers();
    id = uint8(LibBit.ffs(freeBits));
    s.liveBits = uint32(liveBits | (uint256(1) << id));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSUME                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Loads the consumable offers, walks them cheapest-first consuming profitable,
  ///         strictly-de-risking chunks until the liquidator target is met or a stop condition
  ///         fires, then writes all effects back to storage.
  /// @dev Same load + walk as {previewConsume}; only the write-back differs, so preview and
  ///      consume cannot disagree against the same state.
  ///
  ///      Every expired offer in the book is pruned, even ones past the walk's halt point (the
  ///      sorted-at-insert predecessor only pruned expired offers its cursor reached). Expired
  ///      offers are never consumable, so this widens housekeeping only, and it still rolls back
  ///      with the transaction when the caller reverts on a fruitless walk (`NoConsumableOffer`).
  ///
  ///      Effects-before-interaction: all offer mutations (decrements, deletions, expiry prunes)
  ///      are persisted here, before the caller performs the single Morpho `repay`. A reentrant
  ///      `preLiquidate` (via `onPreLiquidate`) therefore observes already-decremented offers and
  ///      cannot double-consume an authorization.
  /// @return totalSeized Total collateral to seize (offer-native units).
  /// @return totalDebtShares Total borrow shares to repay (offer-native units).
  function consume(BorrowOffersStorage storage s, ConsumeInput memory inp)
    internal
    returns (uint256 totalSeized, uint256 totalDebtShares)
  {
    (WalkOffer[] memory offers, uint256 walkLength, uint256 pruneBits) = _loadConsumable(s);
    (totalSeized, totalDebtShares) = _walk(inp, offers, walkLength);

    // Write-back (effects). `clearBits` accumulates every slot to un-live: expired offers pruned
    // at load plus offers the walk exhausted.
    uint256 clearBits = pruneBits;
    while (pruneBits != 0) {
      uint256 id = LibBit.ffs(pruneBits);
      pruneBits &= pruneBits - 1; // clear the lowest set bit
      delete s.slab[id];
    }
    for (uint256 i; i < walkLength; ++i) {
      WalkOffer memory walkOffer = offers[i];
      if (walkOffer.filledCollateral == 0) continue; // untouched by the walk
      bool exhausted = (walkOffer.remainingCollateral == 0 || walkOffer.remainingDebtShares == 0);
      if (exhausted) {
        clearBits |= uint256(1) << walkOffer.id;
        delete s.slab[walkOffer.id];
      } else {
        Offer storage offer = s.slab[walkOffer.id];
        offer.remainingCollateral = walkOffer.remainingCollateral;
        offer.remainingDebtShares = walkOffer.remainingDebtShares;
      }
      emit IBorrowOffers.OfferConsumed(walkOffer.id, walkOffer.filledCollateral, walkOffer.filledShares, exhausted);
    }
    if (clearBits != 0) s.liveBits = uint32(s.liveBits & ~clearBits);
  }

  /// @notice Read-only simulation of {consume} for the same inputs (the `previewConsume` helper).
  /// @dev Shares {_loadConsumable} and {_walk} with {consume} verbatim; it can only differ from a
  ///      real consume through the write-back it skips.
  function previewConsume(BorrowOffersStorage storage s, ConsumeInput memory inp)
    internal
    view
    returns (uint256 totalSeized, uint256 totalDebtShares)
  {
    (WalkOffer[] memory offers, uint256 walkLength,) = _loadConsumable(s);
    return _walk(inp, offers, walkLength);
  }

  /// @dev Loads every live, active, non-expired offer into memory and sorts the result by
  ///      effective price, ascending (cheapest for the liquidator first). Expired offers are
  ///      reported in `pruneBits` for {consume} to delete (a view cannot prune); not-yet-active
  ///      offers are left in place silently (their veto window has not elapsed).
  /// @return offers Array sized for all live offers; only the first `walkLength` entries are used.
  /// @return walkLength Number of loaded (consumable) offers.
  /// @return pruneBits Bitmap of expired offer ids to delete.
  function _loadConsumable(BorrowOffersStorage storage s)
    private
    view
    returns (WalkOffer[] memory offers, uint256 walkLength, uint256 pruneBits)
  {
    uint256 bits = s.liveBits;
    offers = new WalkOffer[](LibBit.popCount(bits));
    while (bits != 0) {
      uint256 id = LibBit.ffs(bits);
      bits &= bits - 1; // clear the lowest set bit
      Offer storage offer = s.slab[id];
      if (block.timestamp >= offer.expiresAt) {
        pruneBits |= uint256(1) << id;
        continue;
      }
      if (block.timestamp < offer.activeAt) continue;
      WalkOffer memory walkOffer = offers[walkLength];
      walkOffer.id = uint8(id);
      walkOffer.remainingCollateral = offer.remainingCollateral;
      walkOffer.remainingDebtShares = offer.remainingDebtShares;
      unchecked {
        ++walkLength;
      }
    }
    _sortByPrice(offers, walkLength);
  }

  /// @dev Sorts `offers[0..n)` by effective price, ascending: descending
  ///      `remainingDebtShares / remainingCollateral` (more debt repaid per collateral unit ==
  ///      cheaper collateral for the liquidator == more owner-favorable). Insertion sort over the
  ///      struct pointers; `n <= MAX_OFFERS` bounds the cost. The strict comparator makes the sort
  ///      stable, so equal-price offers keep their ascending-id load order.
  function _sortByPrice(WalkOffer[] memory offers, uint256 n) private pure {
    for (uint256 i = 1; i < n; ++i) {
      WalkOffer memory key = offers[i];
      uint256 j = i;
      while (j > 0 && _cheaperThan(key, offers[j - 1])) {
        offers[j] = offers[j - 1];
        unchecked {
          --j;
        }
      }
      offers[j] = key;
    }
  }

  /// @dev Returns whether `a`'s effective price is strictly lower than `b`'s. Ratio compare without
  ///      division: `a.debtShares / a.collateral > b.debtShares / b.collateral` cross-multiplied.
  ///      Products are uint128 * uint128 < 2**256, so no overflow.
  function _cheaperThan(WalkOffer memory a, WalkOffer memory b) private pure returns (bool) {
    return
      uint256(a.remainingDebtShares) * b.remainingCollateral > uint256(b.remainingDebtShares) * a.remainingCollateral;
  }

  /// @dev The shared consume/preview walk over the sorted consumable offers: fills cheapest-first
  ///      until the liquidator target is met, the position is exhausted, or an over-price offer
  ///      stops the walk (offers are visited in ascending price order and not consuming freezes the
  ///      LTV, so nothing later can qualify). Pure over memory: fills are recorded by mutating the
  ///      {WalkOffer}s in place (memory structs are references), which {consume} then persists.
  ///
  ///      Stop conditions (any one halts the walk): liquidator target met; position collateral
  ///      exhausted; position debt exhausted; all offers visited; offer over the max price.
  /// @return totalSeized Total collateral to seize (offer-native units).
  /// @return totalDebtShares Total borrow shares to repay (offer-native units).
  function _walk(ConsumeInput memory inp, WalkOffer[] memory offers, uint256 walkLength)
    private
    pure
    returns (uint256 totalSeized, uint256 totalDebtShares)
  {
    for (uint256 i; i < walkLength; ++i) {
      WalkOffer memory walkOffer = offers[i];

      uint256 remainingPositionShares = inp.positionBorrowShares - totalDebtShares;
      uint256 remainingPositionCollateral = inp.positionCollateral - totalSeized;
      // Position debt or collateral exhausted: nothing more to liquidate.
      if (remainingPositionShares == 0 || remainingPositionCollateral == 0) break;

      (FillAction action, uint256 fillCollateral, uint256 fillShares) =
        _computeFill(inp, walkOffer.remainingCollateral, walkOffer.remainingDebtShares, totalSeized, totalDebtShares);

      if (action == FillAction.Stop) break;
      if (action == FillAction.Skip) continue;

      // CONSUME. `fillCollateral <= remainingCollateral` and `fillShares <= remainingDebtShares`
      // by construction, so the uint128 casts and subtractions cannot overflow/underflow.
      walkOffer.remainingCollateral -= uint128(fillCollateral);
      walkOffer.remainingDebtShares -= uint128(fillShares);
      walkOffer.filledCollateral = uint128(fillCollateral);
      walkOffer.filledShares = uint128(fillShares);
      totalSeized += fillCollateral;
      totalDebtShares += fillShares;

      // Liquidator target met?
      if (inp.seizedTarget != 0) {
        if (totalSeized >= inp.seizedTarget) break;
      } else {
        if (totalDebtShares >= inp.repaidSharesTarget) break;
      }
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
  ///      The binding checks (I1 profitability, the consume-time bonus floor, I2 strict de-risk)
  ///      and their conservative (protocol-favorable) rounding are evaluated in {_priceAction}.
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
    // Degenerate zero-remaining amounts cannot be filled. Unreachable belt-and-braces: admission
    // requires both amounts > 0 and the walk deletes an offer the moment a side hits zero.
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

    // I1, the bonus floor and I2 are evaluated in a separate frame ({_priceAction}) to keep this
    // function's stack within the limits of the non-via-IR pipeline. `inp` is passed by reference
    // (one stack slot) rather than unpacking its price/totals/floor fields, which keeps the callee
    // shallow enough to add the bonus-floor check without spilling.
    FillAction action =
      _priceAction(inp, fillCollateral, fillShares, remainingPositionCollateral, remainingPositionShares);
    if (action == FillAction.Consume) return (FillAction.Consume, fillCollateral, fillShares);
    return (action, 0, 0);
  }

  /// @dev Evaluates the binding per-fill checks on the final fill amounts (pure). The local
  ///      names map to the spec notation (BORROW_POSITION_OFFER_LIQUIDATION_SPEC.md sections 4 /
  ///      10): `seizedValue` = v, `repaidDebtValue` = d, `remainingDebtValue` = B,
  ///      `remainingCollateralValue` = V.
  ///      - I1 + bonus floor ({passesI1AndFloor}): not met => {FillAction.Skip}. The offer's price
  ///        is fixed by its terms, so an unprofitable or below-floor offer is skipped (not
  ///        stopped): the walk is sorted ascending in price, and a below-floor offer can be
  ///        followed by higher-bonus offers that still qualify.
  ///      - I2 ({strictlyDeRisks}): not met => {FillAction.Stop} (over max price).
  ///      Collateral values (`seizedValue`/`remainingCollateralValue`) round down and debt values
  ///      (`repaidDebtValue`/`remainingDebtValue`) round up, so the checks are strict in the
  ///      protocol's favour. `repaidDebtValue > 0` since `fillShares >= 1`.
  function _priceAction(
    ConsumeInput memory inp,
    uint256 fillCollateral,
    uint256 fillShares,
    uint256 remainingPositionCollateral,
    uint256 remainingPositionShares
  ) private pure returns (FillAction) {
    uint256 seizedValue = fillCollateral.mulDiv(inp.price, ORACLE_PRICE_SCALE);
    uint256 repaidDebtValue = fillShares.toAssetsUp(inp.totalBorrowAssets, inp.totalBorrowShares);
    if (!passesI1AndFloor(seizedValue, repaidDebtValue, inp.minOfferBonusBps)) return FillAction.Skip;

    uint256 remainingDebtValue = remainingPositionShares.toAssetsUp(inp.totalBorrowAssets, inp.totalBorrowShares);
    uint256 remainingCollateralValue = remainingPositionCollateral.mulDiv(inp.price, ORACLE_PRICE_SCALE);
    if (!strictlyDeRisks(seizedValue, repaidDebtValue, remainingDebtValue, remainingCollateralValue)) {
      return FillAction.Stop;
    }

    return FillAction.Consume;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CANONICAL CHECKS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The canonical I1 (strict profitability) + minimum-bonus-floor check: the seized
  ///         collateral value must exceed the repaid debt value by at least `minBonusBps` basis
  ///         points of that debt value.
  /// @dev Single source of truth for the floor's inequality and rounding (`mulDivUp`, so the floor
  ///      is conservative), shared by the consume walk ({_priceAction}), the `isConsumable` view
  ///      ({consumableAtPrice}) and the proposal-time admission filter
  ///      ({MorphoBorrowPosition._checkOfferProfitable}). `minBonusBps == 0` disables the floor
  ///      (the required excess is 0) and only strict I1 governs.
  function passesI1AndFloor(uint256 seizedValue, uint256 repaidDebtValue, uint256 minBonusBps)
    internal
    pure
    returns (bool)
  {
    if (seizedValue <= repaidDebtValue) return false; // I1
    // Safe subtraction: I1 above guarantees seizedValue > repaidDebtValue.
    return seizedValue - repaidDebtValue >= repaidDebtValue.mulDivUp(minBonusBps, BPS);
  }

  /// @notice The canonical I2 (strict de-risking) check: seizing value `v` against debt value `d`
  ///         strictly lowers the LTV of a position holding collateral value `V` and debt value `B`
  ///         iff `v*B < d*V`.
  /// @dev `fullMulDiv(v, B, d) < V` is the exact integer form of `v/d < V/B` with no intermediate
  ///      overflow. `repaidDebtValue` must be non-zero (guaranteed by callers: it is a rounded-up
  ///      conversion of at least one share).
  function strictlyDeRisks(
    uint256 seizedValue,
    uint256 repaidDebtValue,
    uint256 remainingDebtValue,
    uint256 remainingCollateralValue
  ) internal pure returns (bool) {
    return FixedPointMathLib.fullMulDiv(seizedValue, remainingDebtValue, repaidDebtValue) < remainingCollateralValue;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns whether `id` is a currently-live offer (in range and its `liveBits` bit set).
  function isLive(BorrowOffersStorage storage s, uint8 id) internal view returns (bool) {
    return id < MAX_OFFERS && s.liveBits & (uint256(1) << id) != 0;
  }

  /// @notice Returns the number of currently-live offers.
  function liveCount(BorrowOffersStorage storage s) internal view returns (uint256) {
    return LibBit.popCount(s.liveBits);
  }

  /// @notice Returns all live offers, in ascending slab-id order (NOT price order; the consume
  ///         walk sorts by effective price at consume time).
  function listOffers(BorrowOffersStorage storage s) internal view returns (Offer[] memory out) {
    uint256 bits = s.liveBits;
    out = new Offer[](LibBit.popCount(bits));
    uint256 i;
    while (bits != 0) {
      uint256 id = LibBit.ffs(bits);
      bits &= bits - 1; // clear the lowest set bit
      out[i] = s.slab[id];
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Evaluates whether `remainingCollateral`/`remainingDebtShares` (the whole remaining
  ///         offer) would pass the I1, bonus-floor and I2 gates against the current whole-position
  ///         state.
  /// @dev Pure helper for the `isConsumable` view, built from the same {passesI1AndFloor} /
  ///      {strictlyDeRisks} checks as the consume walk so the view agrees with a real consume. It
  ///      evaluates the offer's price vs the current LTV in isolation: it does not account for the
  ///      cumulative LTV change of consuming cheaper offers first. Returns false if the position
  ///      has no debt (nothing to liquidate) or the offer is degenerate; pass `minBonusBps == 0` to
  ///      gate on strict profitability only.
  function consumableAtPrice(
    uint256 remainingCollateral,
    uint256 remainingDebtShares,
    uint256 positionCollateral,
    uint256 positionBorrowShares,
    uint256 price,
    uint256 totalBorrowAssets,
    uint256 totalBorrowShares,
    uint256 minBonusBps
  ) internal pure returns (bool) {
    if (remainingCollateral == 0 || remainingDebtShares == 0) return false;
    if (positionBorrowShares == 0) return false;

    uint256 seizedValue = remainingCollateral.mulDiv(price, ORACLE_PRICE_SCALE);
    uint256 repaidDebtValue = remainingDebtShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    if (!passesI1AndFloor(seizedValue, repaidDebtValue, minBonusBps)) return false;

    return strictlyDeRisks(
      seizedValue,
      repaidDebtValue,
      positionBorrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares),
      positionCollateral.mulDiv(price, ORACLE_PRICE_SCALE)
    );
  }
}
