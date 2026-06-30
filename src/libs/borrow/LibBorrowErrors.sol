// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Id} from "lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title LibBorrowErrors
/// @author 3F Protocol
/// @notice Error definitions for the Borrow contracts.
library LibBorrowErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MARKETS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the market ID is invalid (zero bytes32).
  /// @param marketId The invalid market ID.
  error InvalidMarketId(Id marketId);

  /// @notice Thrown when attempting to initialize with a market that doesn't exist in Morpho.
  error MarketNotCreated();

  /// @notice Thrown when the Morpho market's collateral or loan token does not match the PositionManager's expected assets.
  /// @param expected The expected asset address from the PositionManager.
  /// @param actual The actual asset address from the Morpho market.
  error AssetMismatch(address expected, address actual);

  /// @notice Thrown when the borrow amount is greater than the available liquidity.
  error InsufficientLiquidity();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        COLLATERAL                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the position has insufficient collateral after an operation.
  error InsufficientCollateral();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       LIQUIDATION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when attempting to liquidate a healthy position.
  error PositionHealthy();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           LTV                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the liquidation LTV exceeds the Morpho market LLTV.
  /// @param liquidationLtv The liquidation LTV provided.
  /// @param marketLltv The Morpho market LLTV.
  error LiquidationLtvExceedsMarketLltv(uint128 liquidationLtv, uint256 marketLltv);

  /// @notice Thrown when the safe LTV is not strictly less than the liquidation LTV.
  /// @param safeLtv The safe LTV provided.
  /// @param liquidationLtv The liquidation LTV provided.
  error SafeLtvNotLessThanLiquidationLtv(uint128 safeLtv, uint128 liquidationLtv);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INPUT VALIDATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the input parameters are inconsistent (e.g., both seizedAssets and repaidShares are non-zero).
  error InconsistentInput();

  /// @notice Thrown when preLiquidate is called with a borrower other than the contract itself.
  error InvalidBorrower();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      AUTHORIZATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the callback is called by an address other than Morpho.
  error NotMorpho();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    UPGRADE / VERSIONING                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when {MorphoBorrowPosition.initializeV2} is called on a proxy that is not at
  ///         version 1 (i.e. a fresh version-0 proxy or an already-migrated version-2 proxy).
  /// @dev `initializeV2` is migration-only. A fresh proxy is set up through `initialize`.
  error NotInitialized();

  /// @notice Thrown when {MorphoBorrowPosition.initialize} is called on a proxy that has already
  ///         been initialized (version != 0), e.g. a previously-initialized proxy after the beacon
  ///         upgrade.
  /// @dev Such proxies must use `initializeV2` instead; `initialize` is for fresh proxies only.
  error AlreadyInitialized();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OFFERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when an offer is proposed with zero collateral or zero debt shares.
  /// @dev Offer amounts are typed `uint128` (matching Morpho's `uint128` collateral and borrow
  ///      totals), so the upper bound is enforced by the parameter type itself; only the
  ///      lower-bound (> 0) needs an explicit check.
  error OfferAmountZero();

  /// @notice Thrown at proposal time when the offer is not profitable at the current price
  ///         (`collateral value <= debt value`). This is a sanity filter only; the binding
  ///         profitability/de-risking checks are re-evaluated per fill at consume time.
  error OfferNotProfitable();

  /// @notice Thrown when an offer's `expiresAt` is not strictly after its computed `activeAt`,
  ///         i.e. the offer would have no consumable window.
  error OfferExpiryTooShort();

  /// @notice Thrown when an offer's lifespan (`expiresAt - activeAt`, i.e. measured from when it
  ///         becomes consumable) exceeds `MAX_OFFER_LIFESPAN`.
  error OfferExpiryTooLong();

  /// @notice Thrown when the offer slab is full (`MAX_OFFERS` live offers).
  error TooManyOffers();

  /// @notice Thrown when an offer id does not correspond to a currently-live offer (bad id or a
  ///         freed/never-allocated slab slot).
  error OfferNotFound();

  /// @notice Thrown when {MorphoBorrowPosition.proposeOffer} is called while the effective offer
  ///         timelock is zero. Defense in depth for the post-upgrade, pre-`initializeV2` window
  ///         (where `offerTimelock == 0`); in practice no proposer role exists in that window either.
  error OfferTimelockUnset();

  /// @notice Thrown when {MorphoBorrowPosition.setOfferTimelock} is given a value outside
  ///         `[MIN_OFFER_TIMELOCK, MAX_OFFER_TIMELOCK]`.
  error OfferTimelockOutOfRange();

  /// @notice Thrown when the offer (band) liquidation path is entered but nothing is fillable
  ///         (empty / all-inactive / all-over-price / only-unprofitable list). A dedicated error
  ///         so liquidators get a clear signal instead of Morpho's `INCONSISTENT_INPUT` from a
  ///         zero-amount repay.
  error NoConsumableOffer();
}
