// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibBorrowOffersConstants
/// @author 3F Protocol
/// @notice Compile-time constants for the offer-based pre-liquidation feature of
///         {MorphoBorrowPosition}.
/// @dev File-level constants are inlined by the compiler. They are kept in a dedicated file so the
///      slab geometry and the offer lifespan bound are auditable in one place and shared verbatim
///      between {LibBorrowOffers}, the position contract and its tests. The offer roles and the
///      per-collateral configuration bounds (timelock, minimum bonus) live on the
///      {BorrowOffersRegistry}, where the corresponding storage and setters are.
///
///      Design context:
///      offers let trusted proposers open an earlier, privileged, timelocked liquidation band in
///      `(safeLtv, liquidationLtv]`. The bounds below (together with the registry's) cap the
///      powers of the (trusted but fallible) actors so that neither an unbounded offer book nor an
///      indefinitely-standing authorization is reachable.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        SLAB GEOMETRY                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Maximum number of simultaneously-live offers. Bounds both the storage slab and the
///      worst-case consume walk, so liquidation gas is bounded regardless of proposer behaviour.
///      Must be `<= 32` so the one-bit-per-slot liveness bitmap fits the `uint32 liveBits` field of
///      {LibBorrowOffers.BorrowOffersStorage} (asserted in tests). 32 is a deliberate, conservative
///      cap: large enough for realistic lender activity on a single position, small enough that a
///      full O(N) load-and-sort stays cheap.
uint256 constant MAX_OFFERS = 32;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       LIFESPAN BOUND                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Maximum lifespan of an offer, measured from when it becomes consumable (`expiresAt -
///      activeAt`), since the timelock (veto) window is not part of the offer's live span.
///      Bounds how long a standing authorization can live; stale offers are pruned on expiry. Kept
///      generous because the liveness guarantee (offers must remain consumable when the protocol is
///      no longer actively monitored) wants long-lived offers, while still preventing an
///      indefinitely-standing authorization.
uint40 constant MAX_OFFER_LIFESPAN = 365 days;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        STORAGE SLOT                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev ERC-7201 storage slot for the offer feature's namespace `"borrow.offers.main"`.
///      Computed as:
///      `keccak256(abi.encode(uint256(keccak256("borrow.offers.main")) - 1)) & ~bytes32(uint256(0xff))`.
///      This is an independent namespace from the existing `"morpho.borrow.position"` slot, so the
///      offer feature cannot collide with the existing market/LTV storage, with the Solady
///      owner slot, or with the `Initializable` slot (see the storage-safety argument in
///      {MorphoBorrowPosition}). The value is hard-coded (not computed on-chain) to save gas and was
///      reproduced from the namespace string with the same procedure as the main storage slot.
bytes32 constant BORROW_OFFERS_STORAGE_SLOT = 0xe6485cf370207053ea24e440730156198d1a663d29d90d2bec5f918b1f0d9100;
