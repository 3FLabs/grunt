// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IMidasDataFeed
/// @author 3F Protocol
/// @notice Interface of the Midas DataFeed wrapping a Chainlink-compatible aggregator.
interface IMidasDataFeed {
  /// @notice Returns the latest answer scaled to base-18 decimals.
  /// @dev Reverts if the underlying aggregator is unhealthy, deprecated or out of bounds.
  /// @return answer The latest price in base-18 decimals.
  function getDataInBase18() external view returns (uint256 answer);
}
