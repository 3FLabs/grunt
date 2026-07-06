// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibBorrowOffers} from "src/libs/borrow/LibBorrowOffers.sol";
import {Offer} from "src/interfaces/borrow/IBorrowOffers.sol";

/// @title BorrowOffersHarness
/// @author 3F Protocol
/// @notice Thin, Morpho-independent wrapper that exposes the internal {LibBorrowOffers}
///         data-structure operations and raw storage, so the slab + liveness bitmap can be
///         exercised and asserted directly by tests, in isolation from the position contract and
///         the oracle/market machinery.
/// @dev {LibBorrowOffers} writes to its fixed ERC-7201 slot. In a standalone contract that slot is
///      simply this harness's own storage, so every operation behaves exactly as it does inside
///      {MorphoBorrowPosition} (the library functions are `internal` and inline here unchanged).
///
///      This is a test-only surface: `insert` is the raw library allocation (no profitability /
///      expiry validation, which live in `MorphoBorrowPosition.proposeOffer`). Tests are
///      responsible for feeding it the same kind of values the real entrypoint would (amounts > 0,
///      `expiresAt > activeAt`), so the structure is exercised over states the production contract
///      can actually reach.
contract BorrowOffersHarness {
  using LibBorrowOffers for LibBorrowOffers.BorrowOffersStorage;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        MUTATIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Seeds the effective timelock and resets the offer-book bookkeeping (mirrors the v2 init).
  function init(uint40 timelock) external {
    LibBorrowOffers.BorrowOffersStorage storage s = LibBorrowOffers.borrowOffersStorage();
    s.offerTimelock = timelock;
    LibBorrowOffers.initOfferBook(s);
  }

  /// @notice Allocates a slab slot (lowest free id) and stores a new offer.
  function insert(address proposer, uint40 activeAt, uint40 expiresAt, uint128 collateral, uint128 debtShares)
    external
    returns (uint8 id)
  {
    return LibBorrowOffers.borrowOffersStorage().insert(proposer, activeAt, expiresAt, collateral, debtShares);
  }

  /// @notice Removes a live offer by id (reverts {OfferNotFound} for a non-live id).
  function removeOffer(uint8 id) external {
    LibBorrowOffers.borrowOffersStorage().removeOffer(id);
  }

  /// @notice Runs the consume walk for the given target/market snapshot, applying all offer effects.
  function consume(LibBorrowOffers.ConsumeInput calldata inp) external returns (uint256 seized, uint256 debtShares) {
    return LibBorrowOffers.borrowOffersStorage().consume(inp);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW (STORAGE)                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Read-only simulation of {consume}.
  function previewConsume(LibBorrowOffers.ConsumeInput calldata inp) external view returns (uint256, uint256) {
    return LibBorrowOffers.borrowOffersStorage().previewConsume(inp);
  }

  /// @notice Returns the raw liveness bitmap (bit i set <=> slab[i] is a live offer).
  function liveBits() external view returns (uint32) {
    return LibBorrowOffers.borrowOffersStorage().liveBits;
  }

  /// @notice Returns the number of live offers (bitmap population count).
  function count() external view returns (uint256) {
    return LibBorrowOffers.borrowOffersStorage().liveCount();
  }

  /// @notice Returns whether `id` is a live offer.
  function isLive(uint8 id) external view returns (bool) {
    return LibBorrowOffers.borrowOffersStorage().isLive(id);
  }

  function offerTimelock() external view returns (uint40) {
    return LibBorrowOffers.borrowOffersStorage().offerTimelock;
  }

  /// @notice Returns the raw slab slot at `i` (live or freed).
  function slabAt(uint8 i) external view returns (Offer memory) {
    return LibBorrowOffers.borrowOffersStorage().slab[i];
  }

  /// @notice Returns all live offers, in ascending slab-id order.
  function listOffers() external view returns (Offer[] memory) {
    return LibBorrowOffers.borrowOffersStorage().listOffers();
  }
}
