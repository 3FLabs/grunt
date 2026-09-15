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
///      Core invariants (binding at consume time):
///      - Profitability with the bonus floor ({isProfitableAboveBonusFloor}): evaluated once per
///        offer on its whole remaining amounts ({_offerClearsFloor}). The floor is scale-invariant
///        (a property of the offer's price, not of a chunk), so an offer exactly at the floor
///        qualifies at any fill size and partitioning a target cannot demote the best offer.
///      - Strict de-risking ({strictlyLowersLtv}): re-checked per consumed chunk, comparing
///        against the running debt/collateral values *before* the fill.
///      Conservative rounding (debt values up, collateral values down) makes both checks strict in
///      the protocol's favour and is load-bearing for Morpho's own health check at the knife edge.
library LibBorrowOffers {
  using FixedPointMathLib for uint256;
  using SharesMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Offer container, stored at {BORROW_OFFERS_STORAGE_SLOT}.
  /// @dev Layout: slot 0 holds `liveBits` (32 bits); the fixed-size `slab` array starts at slot 1.
  ///      The offer roles and configuration (timelock, minimum bonus) live on the shared
  ///      {BorrowOffersRegistry}, so this namespace holds only the book itself.
  ///
  ///      `liveBits` is the single source of truth for liveness: bit `i` set <=> `slab[i]` holds a
  ///      live offer. A cleared bit's slab slot is fully zeroed (freed slots are `delete`d), and an
  ///      all-zero namespace (a fresh proxy, or an existing proxy right after the beacon upgrade)
  ///      structurally reads as an empty book, so no per-proxy initialization or migration is
  ///      needed. Allocation picks the lowest cleared bit, so ids stay within `[0, MAX_OFFERS)`
  ///      and freed ids are reused.
  struct BorrowOffersStorage {
    uint32 liveBits; // bit i set <=> slab[i] is a live offer
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
    uint256 minOfferBonusBps; // consume-time bonus floor (basis points); 0 => only strict profitability applies
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
  ///      - Stop: offer fails the strict de-risking check (over the max price); the walk visits
  ///        offers in ascending price order and not consuming freezes the LTV, so nothing later
  ///        can qualify and the walk halts.
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

  /// @notice Authorized removal for {IBorrowOffers.revokeOffers}: `isGuardian` callers (the
  ///         registry's guardian/owner revoke power, resolved once per batch by the caller) may
  ///         remove any offer; any other caller must be the offer's recorded proposer.
  /// @dev Liveness resolves first, so an unknown id reverts {LibBorrowErrors.OfferNotFound} for
  ///      every caller; an unauthorized caller then reverts {LibBorrowErrors.Unauthorized}.
  function removeOffer(BorrowOffersStorage storage s, uint8 id, address caller, bool isGuardian) internal {
    if (!isLive(s, id)) revert LibBorrowErrors.OfferNotFound();
    if (!isGuardian && s.slab[id].proposer != caller) revert LibBorrowErrors.Unauthorized();
    removeOffer(s, id);
  }

  /// @dev Allocates the lowest free slab index and marks it live, or reverts
  ///      {LibBorrowErrors.TooManyOffers} when all `MAX_OFFERS` slots hold unexpired offers.
  ///      Expired offers are pruned first (bit cleared, slot zeroed; housekeeping only, mirroring
  ///      the pruning in {consume}), so a book full of expired offers self-heals on the next
  ///      proposal instead of requiring a guardian to revoke the dead slots.
  function _alloc(BorrowOffersStorage storage s) private returns (uint8 id) {
    uint256 liveBits = s.liveBits;
    uint256 scanBits = liveBits;
    while (scanBits != 0) {
      uint256 scanId = LibBit.ffs(scanBits);
      scanBits &= scanBits - 1; // clear the lowest set bit
      if (block.timestamp >= s.slab[scanId].expiresAt) {
        liveBits &= ~(uint256(1) << scanId);
        delete s.slab[scanId];
      }
    }
    uint256 freeBits = ~liveBits & ((uint256(1) << MAX_OFFERS) - 1);
    if (freeBits == 0) revert LibBorrowErrors.TooManyOffers();
    id = uint8(LibBit.ffs(freeBits));
    // Only bits below `MAX_OFFERS` (32) survive the mask above, so the cast cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
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
      // A slot is also released when the leftover of a partial fill is no longer strictly
      // profitable (floor of 0): such a remainder cannot be consumed at any configured bonus
      // floor, and keeping it live would let dust hold the book's slots until expiry. The walk
      // admitted this offer's pre-fill amounts and a fill never worsens the remainder's ratio
      // (fill shares round up), so only value rounding on an atom-scale remainder fails here. A
      // below-floor-but-profitable leftover is deliberately kept: like any below-floor offer it
      // is re-admitted by a floor decrease or a price move, and must not be destroyed over a
      // one-atom rounding of the mutable floor.
      bool exhausted = (walkOffer.remainingCollateral == 0 || walkOffer.remainingDebtShares == 0)
        || !_offerClearsFloor(inp, walkOffer.remainingCollateral, walkOffer.remainingDebtShares, 0);
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
    // Clearing bits of an already-`uint32` value cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
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
      // `id` indexes a set bit of the 32-bit live bitmap, so the cast cannot truncate.
      // forge-lint: disable-next-line(unsafe-typecast)
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
      // forge-lint: disable-start(unsafe-typecast)
      walkOffer.remainingCollateral -= uint128(fillCollateral);
      walkOffer.remainingDebtShares -= uint128(fillShares);
      walkOffer.filledCollateral = uint128(fillCollateral);
      walkOffer.filledShares = uint128(fillShares);
      // forge-lint: disable-end(unsafe-typecast)
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
  ///      shares. When the position clamp binds, the seized collateral is rescaled down to the
  ///      offer's fixed ratio, so a nearly-repaid position can never yield the liquidator more
  ///      collateral per share than the proposer authorized.
  ///
  ///      The profitability and consume-time bonus-floor gate is evaluated here on the offer's
  ///      whole remaining amounts ({_offerClearsFloor}); the strict de-risking check on the final
  ///      fill amounts is evaluated in {_priceAction}. Both round conservatively (protocol-favorable).
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

    // Profitability + bonus floor, evaluated on the offer's whole remaining amounts (the floor is
    // a property of the offer's price, so it must not depend on how the target is partitioned; see
    // {_offerClearsFloor}). Skip, not stop: the walk is sorted ascending in price and a
    // higher-bonus offer later can still qualify.
    if (!_offerClearsFloor(inp, remainingCollateral, remainingDebtShares, inp.minOfferBonusBps)) {
      return (FillAction.Skip, 0, 0);
    }

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
    // Reachable only in repaidShares mode: this offer's ratio rounds the remaining share target
    // down to zero collateral (in seizedAssets mode all three min() operands are at least 1).
    // Later offers carry more collateral per debt share (the walk sorts by descending
    // debt-shares-per-collateral), so one of them can still produce a non-zero fill for the same
    // target: skip this offer, do not stop the walk.
    if (fillCollateral == 0) return (FillAction.Skip, 0, 0);

    uint256 fillShares = fillCollateral.mulDivUp(remainingDebtShares, remainingCollateral);
    if (inp.repaidSharesTarget != 0) {
      uint256 shareTargetLeft = inp.repaidSharesTarget - totalDebtShares;
      if (fillShares > shareTargetLeft) fillShares = shareTargetLeft;
    }
    // Never repay more shares than the position owes. Clamping the shares alone would hand the
    // liquidator the full collateral chunk for fewer shares (a better price than the proposer
    // authorized), so the seized collateral is rescaled to the offer's fixed ratio. Rounding down
    // keeps every earlier cap intact (the rescaled value is strictly below the pre-clamp
    // `fillCollateral`) and the liquidator still cannot underpay:
    // `ceil(fillCollateral * shares / collateral) <= fillShares` after a floor rescale.
    if (fillShares > remainingPositionShares) {
      fillShares = remainingPositionShares;
      fillCollateral = fillShares.mulDiv(remainingCollateral, remainingDebtShares);
      if (fillCollateral == 0) return (FillAction.Skip, 0, 0);
    }
    if (fillShares == 0) return (FillAction.Skip, 0, 0); // cannot charge any shares for this collateral

    // The strict de-risking check is evaluated in a separate frame ({_priceAction}) to keep this
    // function's stack within the limits of the non-via-IR pipeline. `inp` is passed by reference
    // (one stack slot) rather than unpacking its price/totals fields, which keeps the callee
    // shallow.
    FillAction action =
      _priceAction(inp, fillCollateral, fillShares, remainingPositionCollateral, remainingPositionShares);
    if (action == FillAction.Consume) return (FillAction.Consume, fillCollateral, fillShares);
    return (action, 0, 0);
  }

  /// @dev Evaluates the strict de-risking check ({strictlyLowersLtv}) on the final fill amounts
  ///      (pure): not met => {FillAction.Stop} (over max price; the walk is sorted ascending in
  ///      price and not consuming freezes the LTV, so nothing later can qualify). The
  ///      profitability/bonus-floor gate is per offer, not per fill: see {_offerClearsFloor}.
  ///      Collateral values (`seizedValue`/`remainingCollateralValue`) round down and debt values
  ///      (`repaidDebtValue`/`remainingDebtValue`) round up, so the check is strict in the
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

    uint256 remainingDebtValue = remainingPositionShares.toAssetsUp(inp.totalBorrowAssets, inp.totalBorrowShares);
    uint256 remainingCollateralValue = remainingPositionCollateral.mulDiv(inp.price, ORACLE_PRICE_SCALE);
    if (!strictlyLowersLtv(seizedValue, repaidDebtValue, remainingDebtValue, remainingCollateralValue)) {
      return FillAction.Stop;
    }

    return FillAction.Consume;
  }

  /// @dev Evaluates the profitability gate with a `minBonusBps` floor on an offer's whole
  ///      remaining amounts (pure). The gate is deliberately not evaluated on the rounded
  ///      per-fill amounts: the floor is scale-invariant on exact values, but a chunk's rounded-up
  ///      shares price the chunk a hair below the offer's nominal bonus, so a partial fill against
  ///      an exactly-at-floor offer (the most owner-favorable admissible price) would miss the
  ///      floor by one raw share and hand the fill to a worse offer. Whole-remaining evaluation
  ///      makes the decision independent of how the liquidator partitions the target, and is the
  ///      same expression as {consumableAtPrice}, so the `isConsumable` view agrees with the walk.
  ///      The walk passes the configured `inp.minOfferBonusBps`; the release check in {consume}
  ///      passes 0 (strict profitability only).
  function _offerClearsFloor(
    ConsumeInput memory inp,
    uint256 remainingCollateral,
    uint256 remainingDebtShares,
    uint256 minBonusBps
  ) private pure returns (bool) {
    uint256 offerValue = remainingCollateral.mulDiv(inp.price, ORACLE_PRICE_SCALE);
    uint256 offerDebtValue = remainingDebtShares.toAssetsUp(inp.totalBorrowAssets, inp.totalBorrowShares);
    return isProfitableAboveBonusFloor(offerValue, offerDebtValue, minBonusBps);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CANONICAL CHECKS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The canonical profitability check with the minimum-bonus floor: the seized collateral
  ///         value must strictly exceed the repaid debt value, by at least `minBonusBps` basis
  ///         points of that debt value.
  /// @dev Single source of truth for the floor's inequality and rounding (`mulDivUp`, so the floor
  ///      is conservative), shared by the consume walk ({_offerClearsFloor}), the `isConsumable` view
  ///      ({consumableAtPrice}) and the proposal-time admission filter
  ///      ({MorphoBorrowPosition._checkOfferProfitable}). `minBonusBps == 0` disables the floor
  ///      (the required excess is 0) and only strict profitability governs.
  function isProfitableAboveBonusFloor(uint256 seizedValue, uint256 repaidDebtValue, uint256 minBonusBps)
    internal
    pure
    returns (bool)
  {
    if (seizedValue <= repaidDebtValue) return false; // not strictly profitable
    // Safe subtraction: strict profitability above guarantees seizedValue > repaidDebtValue.
    return seizedValue - repaidDebtValue >= repaidDebtValue.mulDivUp(minBonusBps, BPS);
  }

  /// @notice The canonical strict de-risking check: a fill that seizes `seizedValue` of collateral
  ///         to repay `repaidDebtValue` of debt strictly lowers the LTV of a position holding
  ///         `remainingCollateralValue` against `remainingDebtValue` iff
  ///         `seizedValue * remainingDebtValue < repaidDebtValue * remainingCollateralValue`
  ///         (the fill's collateral-per-debt ratio sits below the position's, so removing it
  ///         leaves the remainder better collateralized).
  /// @dev `fullMulDiv` is the exact integer form of that product comparison with no intermediate
  ///      overflow. `repaidDebtValue` must be non-zero (guaranteed by callers: it is a rounded-up
  ///      conversion of at least one share).
  function strictlyLowersLtv(
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
  ///         offer) would pass the profitability, bonus-floor and de-risking gates against the
  ///         current whole-position state.
  /// @dev Pure helper for the `isConsumable` view, built from the same {isProfitableAboveBonusFloor}
  ///      / {strictlyLowersLtv} checks as the consume walk (whose floor gate, {_offerClearsFloor},
  ///      also evaluates the whole remaining amounts) so the view agrees with a real consume. It
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
    if (!isProfitableAboveBonusFloor(seizedValue, repaidDebtValue, minBonusBps)) return false;

    return strictlyLowersLtv(
      seizedValue,
      repaidDebtValue,
      positionBorrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares),
      positionCollateral.mulDiv(price, ORACLE_PRICE_SCALE)
    );
  }
}
