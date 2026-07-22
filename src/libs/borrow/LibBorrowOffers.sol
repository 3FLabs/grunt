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
///      library owns its own ERC-7201 namespace (`"borrow.offers.main"`).
///
///      Core invariants (binding, re-checked per consumed chunk):
///      - Profitability ({isProfitableAboveBonusFloor}): each fill seizes collateral worth
///        strictly more than the debt value it repays, with at least the minimum bonus on top.
///      - Strict de-risking ({strictlyLowersLtv}): each fill strictly lowers the position LTV,
///        comparing against the running debt/collateral values *before* the fill.
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
  ///      `liveBits` is the single source of truth for liveness: bit `i` set <=> `slab[i]` holds a
  ///      live offer, and a freed slot is fully zeroed (`delete`d), so an all-zero namespace
  ///      structurally reads as an empty book and no per-proxy initialization or migration is
  ///      needed. A live offer always has a non-zero proposer and both remaining amounts > 0.
  ///      Allocation picks the lowest cleared bit, so ids stay within `[0, MAX_OFFERS)` and freed
  ///      ids are reused.
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
    s.liveBits = uint32(liveBits | (uint256(1) << id));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSUME                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Loads the consumable offers, walks them cheapest-first consuming profitable,
  ///         strictly-de-risking chunks until the liquidator target is met or a stop condition
  ///         fires, then writes all effects back to storage.
  /// @dev Same load + walk as {previewConsume}; only the write-back differs, so preview and
  ///      consume cannot disagree against the same state. Every expired offer in the book is
  ///      pruned, even ones past the walk's halt point (expired offers are never consumable, so
  ///      this is housekeeping only).
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

  /// @dev The shared consume/preview walk over the sorted consumable offers: fills cheapest-first.
  ///      Pure over memory: fills are recorded by mutating the {WalkOffer}s in place (memory
  ///      structs are references), which {consume} then persists.
  ///      Stop conditions (any one halts the walk): liquidator target met; position collateral or
  ///      debt exhausted; all offers visited; offer over the max price (see {FillAction.Stop}).
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

  /// @dev Computes the fill for a single offer and the per-fill decision (pure). Fills are
  ///      collateral-driven for uniform rounding: `fillShares` rounds up, so the chunk's price
  ///      rounds in the protocol's favour and the liquidator cannot underpay; in repaidShares
  ///      mode the candidate collateral rounds down so the implied shares never overshoot the
  ///      target. The binding checks (profitability, bonus floor, strict de-risking) are
  ///      evaluated in {_priceAction}.
  ///
  ///      The position's remaining collateral/shares are derived from `inp` and the running
  ///      totals rather than threaded in, and returns are unnamed, to keep the stack within the
  ///      limits of the non-via-IR pipeline this codebase compiles with.
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
    // Reachable only in repaidShares mode (in seizedAssets mode all three min() operands are at
    // least 1). Later offers carry more collateral per debt share and can still produce a
    // non-zero fill for the same target: skip this offer, do not stop the walk.
    if (fillCollateral == 0) return (FillAction.Skip, 0, 0);

    uint256 fillShares = fillCollateral.mulDivUp(remainingDebtShares, remainingCollateral);
    if (inp.repaidSharesTarget != 0) {
      uint256 shareTargetLeft = inp.repaidSharesTarget - totalDebtShares;
      if (fillShares > shareTargetLeft) fillShares = shareTargetLeft;
    }
    // Never repay more shares than the position owes. Clamping the shares alone would hand the
    // liquidator the full collateral chunk for fewer shares (a better price than the proposer
    // authorized), so the seized collateral is rescaled down to the offer's fixed ratio; the
    // floor rescale stays below every earlier cap and the liquidator still cannot underpay.
    if (fillShares > remainingPositionShares) {
      fillShares = remainingPositionShares;
      fillCollateral = fillShares.mulDiv(remainingCollateral, remainingDebtShares);
      if (fillCollateral == 0) return (FillAction.Skip, 0, 0);
    }
    if (fillShares == 0) return (FillAction.Skip, 0, 0); // cannot charge any shares for this collateral

    FillAction action =
      _priceAction(inp, fillCollateral, fillShares, remainingPositionCollateral, remainingPositionShares);
    if (action == FillAction.Consume) return (FillAction.Consume, fillCollateral, fillShares);
    return (action, 0, 0);
  }

  /// @dev Evaluates the binding per-fill checks on the final fill amounts (pure):
  ///      profitability + bonus floor ({isProfitableAboveBonusFloor}) not met =>
  ///      {FillAction.Skip}; strict de-risking ({strictlyLowersLtv}) not met =>
  ///      {FillAction.Stop} (over the max price; see {FillAction}). Collateral values round down
  ///      and debt values round up, so the checks are strict in the protocol's favour.
  ///      `repaidDebtValue > 0` since `fillShares >= 1`.
  function _priceAction(
    ConsumeInput memory inp,
    uint256 fillCollateral,
    uint256 fillShares,
    uint256 remainingPositionCollateral,
    uint256 remainingPositionShares
  ) private pure returns (FillAction) {
    uint256 seizedValue = fillCollateral.mulDiv(inp.price, ORACLE_PRICE_SCALE);
    uint256 repaidDebtValue = fillShares.toAssetsUp(inp.totalBorrowAssets, inp.totalBorrowShares);
    if (!isProfitableAboveBonusFloor(seizedValue, repaidDebtValue, inp.minOfferBonusBps)) return FillAction.Skip;

    uint256 remainingDebtValue = remainingPositionShares.toAssetsUp(inp.totalBorrowAssets, inp.totalBorrowShares);
    uint256 remainingCollateralValue = remainingPositionCollateral.mulDiv(inp.price, ORACLE_PRICE_SCALE);
    if (!strictlyLowersLtv(seizedValue, repaidDebtValue, remainingDebtValue, remainingCollateralValue)) {
      return FillAction.Stop;
    }

    return FillAction.Consume;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CANONICAL CHECKS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The canonical profitability check with the minimum-bonus floor: the seized collateral
  ///         value must strictly exceed the repaid debt value, by at least `minBonusBps` basis
  ///         points of that debt value.
  /// @dev Single source of truth for the floor's inequality and rounding (`mulDivUp`, so the floor
  ///      is conservative), shared by the consume walk ({_priceAction}), the `isConsumable` view
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
  /// @dev Backs the `isConsumable` view with the same {isProfitableAboveBonusFloor} /
  ///      {strictlyLowersLtv} checks as the consume walk; see {IBorrowOffers.isConsumable} for
  ///      the evaluated-in-isolation caveat. Pass `minBonusBps == 0` to gate on strict
  ///      profitability only.
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
