// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibBorrowOffersConstants
/// @author 3F Protocol
/// @notice Compile-time constants for the offer-based pre-liquidation feature of
///         {MorphoBorrowPosition}.
/// @dev File-level constants are inlined by the compiler; kept in a dedicated file so the slab
///      geometry and the offer lifespan bound are shared verbatim between {LibBorrowOffers}, the
///      position contract and the tests. The per-collateral configuration bounds live on the
///      {BorrowOffersRegistry}. Design context: docs/borrow.md#liquidation-offers.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        SLAB GEOMETRY                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Maximum number of simultaneously-live offers; bounds both the storage slab and the
///      worst-case consume-walk gas regardless of proposer behaviour. Must be `<= 32` so the
///      liveness bitmap fits the `uint32 liveBits` field of
///      {LibBorrowOffers.BorrowOffersStorage} (asserted in tests).
uint256 constant MAX_OFFERS = 32;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       LIFESPAN BOUND                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Maximum lifespan of an offer, measured from when it becomes consumable (`expiresAt -
///      activeAt`), so the veto window does not eat into the live span. Bounds how long a
///      standing authorization can live while staying generous enough for offers meant to remain
///      consumable when the protocol is no longer actively monitored.
uint40 constant MAX_OFFER_LIFESPAN = 365 days;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                        STORAGE SLOT                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev ERC-7201 storage slot for the offer feature's namespace `"borrow.offers.main"`.
///      Computed as:
///      `keccak256(abi.encode(uint256(keccak256("borrow.offers.main")) - 1)) & ~bytes32(uint256(0xff))`.
///      An independent namespace from the `"morpho.borrow.position"` slot; hard-coded (not
///      computed on-chain) to save gas.
bytes32 constant BORROW_OFFERS_STORAGE_SLOT = 0xe6485cf370207053ea24e440730156198d1a663d29d90d2bec5f918b1f0d9100;
