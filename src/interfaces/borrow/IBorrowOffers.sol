// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title Offer
/// @notice A standing, partially-fillable pre-liquidation offer posted by a trusted proposer.
/// @dev An offer is an *authorization* (no token custody): it lets liquidators repay up to
///      `remainingDebtShares` of the position's Morpho borrow shares in exchange for up to
///      `remainingCollateral` collateral tokens, at the fixed ratio implied by those two amounts.
///
///      Debt is denominated in Morpho borrow **shares** (not loan-token units). A fixed share
///      amount converts to more loan-token assets as interest accrues, so an offer's effective
///      price worsens for the liquidator over time (and an offer can drift below profitability, at
///      which point it is simply skipped, then eventually expires). This choice gives a precise
///      debt-repayment quantity and a clean shares-mode Morpho settlement (no assets-mode
///      `borrowShares` underflow).
///
///      Packing (2 storage slots):
///      - slot 1: `proposer` (160) + `activeAt` (40) + `expiresAt` (40)
///      - slot 2: `remainingCollateral` (128) + `remainingDebtShares` (128)
///      The `uint128` amounts are sound because Morpho stores `Position.collateral` and the market
///      borrow totals as `uint128`.
///
///      Liveness is tracked by the `liveBits` bitmap in {LibBorrowOffers.BorrowOffersStorage} (bit
///      set <=> the slab slot holds a live offer), not by any field of this struct; a freed slot is
///      fully zeroed. A live offer always has a non-zero proposer and both remaining amounts > 0.
struct Offer {
  /// @dev The account that posted the offer (accountability; also used by views).
  address proposer;
  /// @dev Absolute timestamp at which the offer becomes consumable. Fixed at proposal time as
  ///      `proposalTime + effectiveTimelockAtProposal`, so a later timelock change cannot re-time
  ///      an already-proposed offer (its veto window can never be retroactively shortened).
  uint40 activeAt;
  /// @dev Absolute expiry. The offer is consumable only while `now < expiresAt`.
  uint40 expiresAt;
  /// @dev Collateral tokens still offered.
  uint128 remainingCollateral;
  /// @dev Morpho borrow shares still requested for the remaining collateral.
  uint128 remainingDebtShares;
}

/// @title IBorrowOffers
/// @author 3F Protocol
/// @notice External surface (write functions, admin functions, views and events) for the
///         offer-based pre-liquidation feature of {MorphoBorrowPosition}.
interface IBorrowOffers {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new offer is proposed.
  /// @param id The slab id assigned to the offer.
  /// @param proposer The account that posted the offer.
  /// @param collateral The collateral tokens offered.
  /// @param debtShares The Morpho borrow shares requested.
  /// @param activeAt The absolute timestamp at which the offer becomes consumable.
  /// @param expiresAt The absolute expiry timestamp.
  event OfferProposed(
    uint8 indexed id,
    address indexed proposer,
    uint128 collateral,
    uint128 debtShares,
    uint40 activeAt,
    uint40 expiresAt
  );

  /// @notice Emitted when an offer is revoked (guardian veto / admin / owner kill switch).
  /// @param id The slab id of the revoked offer.
  /// @param by The caller that revoked it.
  event OfferRevoked(uint8 indexed id, address indexed by);

  /// @notice Emitted for each chunk consumed from an offer during a band pre-liquidation.
  /// @dev Emitted after the whole consume walk completes (effects are aggregated per offer), in
  ///      ascending order of the offers' effective price at walk entry, not in slab-id order.
  /// @param id The slab id of the consumed offer.
  /// @param collateralFilled The collateral tokens seized from this offer in this chunk.
  /// @param debtSharesFilled The borrow shares repaid against this offer in this chunk.
  /// @param exhausted True if the offer was fully consumed (and removed) by this chunk.
  event OfferConsumed(uint8 indexed id, uint128 collateralFilled, uint128 debtSharesFilled, bool exhausted);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WRITE (PROPOSERS)                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Proposes a new partially-fillable pre-liquidation offer.
  /// @dev Gated by {IBorrowOffersRegistry.checkCanCreateOffer} (a proposer, or the registry
  ///      owner). The offer becomes consumable at `now + timelock` (fixed here from the registry's
  ///      current effective timelock for this market's collateral) and expires at `expiresAt`.
  /// @param collateral The collateral tokens offered (> 0).
  /// @param debtShares The Morpho borrow shares requested (> 0).
  /// @param expiresAt The absolute expiry timestamp (must be strictly after the computed `activeAt`
  ///        and within `MAX_OFFER_LIFESPAN` of that `activeAt`).
  /// @return id The slab id assigned to the new offer.
  function proposeOffer(uint128 collateral, uint128 debtShares, uint40 expiresAt) external returns (uint8 id);

  /// @notice Revokes one or more offers (batch). Gated by
  ///         {IBorrowOffersRegistry.checkCanRevokeOffer} (a guardian, or the registry owner).
  /// @dev Reverts {LibBorrowErrors.OfferNotFound} if any id is not a currently-live offer.
  /// @param ids The slab ids to revoke.
  function revokeOffers(uint8[] calldata ids) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the number of currently-live offers.
  function offerCount() external view returns (uint256);

  /// @notice Returns a single offer by id. A non-live id returns a zeroed {Offer}.
  function offer(uint8 id) external view returns (Offer memory);

  /// @notice Returns all live offers, in ascending slab-id order (NOT price order; the consume
  ///         walk sorts by effective price at consume time).
  function offers() external view returns (Offer[] memory);

  /// @notice Returns whether an offer would currently pass the consume gates (active, not expired,
  ///         profitable and within the max price at the current position LTV).
  /// @dev Approximate helper: it evaluates the offer against the current position state in
  ///      isolation and does not account for ordering or the cumulative LTV change of consuming
  ///      earlier offers. The binding checks are the per-fill checks inside the consume walk.
  function isConsumable(uint8 id) external view returns (bool);

  /// @notice Off-chain helper that simulates a band consume for the given target without mutating
  ///         state.
  /// @param seizedAssets The collateral-seize target (pass 0 to use `repaidShares`).
  /// @param repaidShares The debt-share-repay target (pass 0 to use `seizedAssets`).
  /// @return seized The total collateral that would be seized.
  /// @return debtShares The total borrow shares that would be repaid.
  function previewConsume(uint256 seizedAssets, uint256 repaidShares)
    external
    view
    returns (uint256 seized, uint256 debtShares);
}
