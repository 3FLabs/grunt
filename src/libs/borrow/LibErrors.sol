// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Id} from "lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title LibErrors
/// @author 3F Protocol
/// @notice Error definitions for the Borrow contracts.
library LibErrors {
  /// @notice Thrown when a required address parameter is the zero address.
  error AddressZero();

  /// @notice Thrown when the market ID is invalid (zero bytes32).
  /// @param marketId The invalid market ID.
  error InvalidMarketId(Id marketId);

  /// @notice Thrown when attempting to initialize with a market that doesn't exist in Morpho.
  error MarketNotCreated();

  /// @notice Thrown when an operation is called with a zero amount.
  error AmountZero();

  /// @notice Thrown when the position has insufficient collateral after an operation.
  error InsufficientCollateral();

  /// @notice Thrown when attempting to liquidate a healthy position.
  error PositionHealthy();

  /// @notice Thrown when the provided LLTV is invalid (zero or greater than WAD).
  error InvalidLltv();

  /// @notice Thrown when the custom LLTV exceeds the Morpho market LLTV.
  /// @param customLltv The custom LLTV provided.
  /// @param marketLltv The Morpho market LLTV.
  error CustomLltvExceedsMarketLltv(uint256 customLltv, uint256 marketLltv);

  /// @notice Thrown when the input parameters are inconsistent (e.g., both seizedAssets and repaidShares are non-zero).
  error InconsistentInput();

  /// @notice Thrown when the callback is called by an address other than Morpho.
  error NotMorpho();
}
