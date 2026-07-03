// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibBorrowOffersConstants
/// @author 3F Protocol
/// @notice Compile-time constants for the offer-based pre-liquidation feature of
///         {MorphoBorrowPosition}.
/// @dev File-level constants are inlined by the compiler. They are kept in a dedicated file so the
///      role bitmasks, slab geometry and the timelock/expiry bounds are auditable in one place and
///      shared verbatim between {LibBorrowOffers}, the position contract and its tests.
///
///      Design context (see BORROW_POSITION_OFFER_LIQUIDATION_SPEC.md):
///      offers let trusted proposers open an earlier, privileged, timelocked liquidation band in
///      `(safeLtv, liquidationLtv]`. The bounds below cap the powers of the (trusted but fallible)
///      admin so that neither an instantly-consumable offer (timelock floor) nor a frozen band
///      (timelock ceiling) is reachable.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           ROLES                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Admin role. Maps to Solady `OwnableRoles._ROLE_0` (`1 << 0`).
///      Granted at initialization to the PositionManager's governance `owner()` (with a fallback to
///      the position owner). Manages proposers, guardians and the offer timelock. The bit value is
///      duplicated here (rather than imported from {OwnableRoles}) because `_ROLE_0` is `internal`
///      to that mixin; the literal is asserted equal to `_ROLE_0` in tests.
uint256 constant ROLE_ADMIN = 1 << 0;

/// @dev Proposer role. Maps to Solady `OwnableRoles._ROLE_1` (`1 << 1`). Allowed to post offers.
uint256 constant PROPOSER_ROLE = 1 << 1;

/// @dev Guardian role. Maps to Solady `OwnableRoles._ROLE_2` (`1 << 2`). Allowed to revoke offers
///      (the veto power inside the timelock window, and the kill switch for a bad standing offer).
uint256 constant GUARDIAN_ROLE = 1 << 2;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        SLAB GEOMETRY                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Maximum number of simultaneously-live offers. Bounds both the storage slab and the
///      worst-case consume/insert walk, so liquidation gas is bounded regardless of proposer
///      behaviour. Must be `<= 255` so that offer ids (slab indices) and the {NULL} sentinel fit
///      in a `uint8`. 32 is a deliberate, conservative cap: large enough for realistic lender
///      activity on a single position, small enough that a full O(N) walk stays cheap.
uint256 constant MAX_OFFERS = 32;

/// @dev Sentinel for "no offer" in the `uint8` head/tail/prev/next/free-list links. `0xFF` (255)
///      can never be a real id because ids are constrained to `[0, MAX_OFFERS)` and
///      `MAX_OFFERS <= 255`.
uint8 constant NULL = 0xFF;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    TIMELOCK / EXPIRY BOUNDS               */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Default offer timelock set at initialization. The veto window during which a guardian
///      can revoke a freshly-posted offer before it becomes consumable. Governance can retune it
///      within `[MIN_OFFER_TIMELOCK, MAX_OFFER_TIMELOCK]` via {setOfferTimelock} (itself timelocked).
uint40 constant DEFAULT_OFFER_TIMELOCK = 1 hours;

/// @dev Lower bound for the offer timelock. A positive floor guarantees that every offer has a
///      non-zero veto window even at the minimum setting, so an offer can never be same-block
///      consumable (a key reentrancy assumption: see {MorphoBorrowPosition} security notes).
uint40 constant MIN_OFFER_TIMELOCK = 15 minutes;

/// @dev Upper bound for the offer timelock. A firm ceiling so a malicious or compromised admin
///      cannot grief by (a) giving every future offer an absurd `activeAt` (freezing the band) or
///      (b) self-locking: because any timelock change is itself delayed by the *current* effective
///      timelock, an unbounded value would also delay its own correction. With this cap, both the
///      worst-case freeze and the time to recover from one are bounded by `MAX_OFFER_TIMELOCK`.
uint40 constant MAX_OFFER_TIMELOCK = 7 days;

/// @dev Maximum lifespan of an offer, measured from when it becomes consumable (`expiresAt -
///      activeAt`), since the timelock (veto) window is not part of the offer's live span.
///      Bounds how long a standing authorization can live; stale offers are pruned on expiry. Kept
///      generous because the liveness guarantee (offers must remain consumable when the protocol is
///      no longer actively monitored) wants long-lived offers, while still preventing an
///      indefinitely-standing authorization.
uint40 constant MAX_OFFER_LIFESPAN = 365 days;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      MINIMUM OFFER BONUS                   */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Default minimum offer bonus, in basis points, set at initialization (100 = 1%). A fill's
///      collateral value must exceed the debt value it repays by at least this fraction of that
///      debt value, enforced both when an offer is proposed and again per fill at consume time
///      (see {MorphoBorrowPosition.proposeOffer} and {LibBorrowOffers}). This is an anti-griefing
///      floor for the offer book: without it, a proposer could post barely-profitable offers that
///      sort to the head of the book (lowest price first) and drag the profitability of every band
///      liquidation down to near zero. Because the floor is re-checked at consume time, a live
///      offer whose bonus later drifts below it (via price or accrued-interest movement) is simply
///      skipped by liquidators rather than dragging the band down. Retunable by the admin within
///      `[0, MAX_MIN_OFFER_BONUS_BPS]` via {setMinOfferBonus}.
uint16 constant DEFAULT_MIN_OFFER_BONUS_BPS = 100;

/// @dev Upper bound for the minimum offer bonus (1000 = 10%). A sanity ceiling in the same spirit
///      as `MAX_OFFER_TIMELOCK`: a (trusted but fallible) admin cannot demand an absurd bonus floor
///      that no realistic offer could clear. The floor gates both proposals and every fill, and it
///      stacks under the strict de-risking check (I2): for a position at loan-to-value `LTV`, I2
///      already caps any fill's bonus at `(1 - LTV) / LTV` measured as a fraction of the debt value
///      (the same denomination the floor uses; equivalently `1 - LTV` measured as a fraction of the
///      seized collateral value). So a floor near this ceiling can make the band unusable for
///      high-LTV configurations until the admin lowers it again (the setter is instant): e.g. at
///      `LTV = 0.9` the debt-value cap is only `~11.1%`, so a `10%` floor still just clears, while
///      at `LTV >= 1 / 1.1 (~0.909)` a `10%` floor admits no consumable fill.
uint16 constant MAX_MIN_OFFER_BONUS_BPS = 1_000;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        STORAGE SLOT                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev ERC-7201 storage slot for the offer feature's namespace `"borrow.offers.main"`.
///      Computed as:
///      `keccak256(abi.encode(uint256(keccak256("borrow.offers.main")) - 1)) & ~bytes32(uint256(0xff))`.
///      This is an independent namespace from the existing `"morpho.borrow.position"` slot, so the
///      offer feature cannot collide with the existing market/LTV storage, with the Solady
///      owner/role slots, or with the `Initializable` slot (see the storage-safety argument in
///      {MorphoBorrowPosition}). The value is hard-coded (not computed on-chain) to save gas and was
///      reproduced from the namespace string with the same procedure as the main storage slot.
bytes32 constant BORROW_OFFERS_STORAGE_SLOT = 0xe6485cf370207053ea24e440730156198d1a663d29d90d2bec5f918b1f0d9100;
