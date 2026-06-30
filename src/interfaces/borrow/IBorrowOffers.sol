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
///      `borrowShares` underflow). See BORROW_POSITION_OFFER_LIQUIDATION_SPEC.md §14 (Decision B).
///
///      Packing (2 storage slots, exact):
///      - slot 1: `proposer` (160) + `activeAt` (40) + `expiresAt` (40) + `prev` (8) + `next` (8)
///      - slot 2: `remainingCollateral` (128) + `remainingDebtShares` (128)
///      The `uint128` amounts are sound because Morpho stores `Position.collateral` and the market
///      borrow totals as `uint128`.
struct Offer {
  /// @dev The account that posted the offer (accountability; also used by views). An all-zero
  ///      `proposer` marks a freed / never-allocated slab slot (i.e. "not a live offer").
  address proposer;
  /// @dev Absolute timestamp at which the offer becomes consumable. Fixed at proposal time as
  ///      `proposalTime + effectiveTimelockAtProposal`, so a later timelock change cannot re-time
  ///      an already-proposed offer (its veto window can never be retroactively shortened).
  uint40 activeAt;
  /// @dev Absolute expiry. The offer is consumable only while `now < expiresAt`.
  uint40 expiresAt;
  /// @dev Doubly-linked-list previous pointer ({NULL} at head). Slab index.
  uint8 prev;
  /// @dev Doubly-linked-list next pointer ({NULL} at tail); also threads the free-list when freed.
  uint8 next;
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
  /// @param id The slab id of the consumed offer.
  /// @param collateralFilled The collateral tokens seized from this offer in this chunk.
  /// @param debtSharesFilled The borrow shares repaid against this offer in this chunk.
  /// @param exhausted True if the offer was fully consumed (and removed) by this chunk.
  event OfferConsumed(uint8 indexed id, uint128 collateralFilled, uint128 debtSharesFilled, bool exhausted);

  /// @notice Emitted when a new offer timelock is scheduled (it becomes effective only after the
  ///         current timelock elapses).
  /// @param newTimelock The scheduled timelock value.
  /// @param effectiveAt The absolute timestamp at which `newTimelock` becomes effective.
  event OfferTimelockScheduled(uint40 newTimelock, uint40 effectiveAt);

  /// @notice Emitted once, at initialization, when the admin role is granted.
  /// @param admin The account granted `ROLE_ADMIN` (the PositionManager's governance owner, or the
  ///        position owner as a fallback).
  event RoleAdminInitialized(address indexed admin);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WRITE (PROPOSERS)                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Proposes a new partially-fillable pre-liquidation offer.
  /// @dev Gated to `PROPOSER_ROLE | ROLE_ADMIN | owner`. The offer becomes consumable at
  ///      `now + effectiveTimelock()` (fixed here) and expires at `expiresAt`.
  /// @param collateral The collateral tokens offered (> 0).
  /// @param debtShares The Morpho borrow shares requested (> 0).
  /// @param expiresAt The absolute expiry timestamp (must be strictly after the computed `activeAt`
  ///        and within `MAX_OFFER_LIFESPAN` of that `activeAt`).
  /// @return id The slab id assigned to the new offer.
  function proposeOffer(uint128 collateral, uint128 debtShares, uint40 expiresAt) external returns (uint8 id);

  /// @notice Revokes one or more offers (batch). Gated to `GUARDIAN_ROLE | ROLE_ADMIN | owner`.
  /// @dev Reverts {LibBorrowErrors.OfferNotFound} if any id is not a currently-live offer.
  /// @param ids The slab ids to revoke.
  function revokeOffers(uint8[] calldata ids) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ADMIN (ROLE_ADMIN)                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Grants or revokes `PROPOSER_ROLE` for `account`. Gated to `ROLE_ADMIN | owner`.
  function setProposer(address account, bool enabled) external;

  /// @notice Grants or revokes `GUARDIAN_ROLE` for `account`. Gated to `ROLE_ADMIN | owner`.
  function setGuardian(address account, bool enabled) external;

  /// @notice Schedules a new offer timelock. Gated to `ROLE_ADMIN | owner`.
  /// @dev The change is itself timelocked: it becomes effective only after the *current* effective
  ///      timelock elapses. `timelock` must be within `[MIN_OFFER_TIMELOCK, MAX_OFFER_TIMELOCK]`.
  function setOfferTimelock(uint40 timelock) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the current effective offer timelock (accounting for a due, not-yet-promoted
  ///         pending change).
  function offerTimelock() external view returns (uint40);

  /// @notice Returns the scheduled (pending) offer timelock and when it becomes effective.
  /// @return value The pending timelock value (0 if none scheduled).
  /// @return effectiveAt The timestamp at which it becomes effective (0 if none scheduled).
  function pendingOfferTimelock() external view returns (uint40 value, uint40 effectiveAt);

  /// @notice Returns the number of currently-live offers.
  function offerCount() external view returns (uint256);

  /// @notice Returns a single offer by id. A non-live id returns a zeroed {Offer}.
  function offer(uint8 id) external view returns (Offer memory);

  /// @notice Returns all live offers, ordered head -> tail (most owner-favorable first).
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Migration-only entrypoint that runs the v2 setup on an existing (version-1) proxy.
  /// @dev Permissionless and idempotent-by-construction: it reverts on a fresh (version-0) or
  ///      already-migrated (version-2) proxy. Fresh proxies are set up by `initialize` directly.
  function initializeV2() external;
}
