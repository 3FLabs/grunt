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
}
