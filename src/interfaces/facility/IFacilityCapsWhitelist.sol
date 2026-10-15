// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IFacilityCapsWhitelist
/// @author 3F Protocol
/// @notice Registry of IFacilityCaps contracts an EXTERNAL deposit cap word may reference.
interface IFacilityCapsWhitelist {
  /// @notice Emitted when a caps contract is allowed or disallowed.
  /// @param caps The caps contract.
  /// @param allowed Whether cap words may reference it.
  event CapsAllowed(address indexed caps, bool allowed);

  /// @notice Returns whether cap words may reference a caps contract.
  /// @param caps The caps contract.
  function isAllowed(address caps) external view returns (bool);

  /// @notice Allows or disallows a caps contract.
  /// @dev Disallowing only blocks new cap words: stored words keep consuming the contract, but
  ///      setting one again, even unchanged, reverts CapsNotAllowed.
  /// @param caps The caps contract.
  /// @param allowed Whether cap words may reference it.
  function setAllowed(address caps, bool allowed) external;
}
