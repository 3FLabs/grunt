// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFacility} from "./IFacility.sol";

/// @title IIntentDescriptor
/// @author 3F Protocol
/// @notice Interface for generating metadata for intent tokens (ERC6909).
/// @dev Implementations provide name, symbol, description, and tokenURI for each intent ID.
interface IIntentDescriptor {
  /// @notice Returns the name for a given intent token.
  /// @param facility The facility contract address.
  /// @param id The intent token ID.
  /// @return The name of the intent token.
  function name(IFacility facility, uint256 id) external view returns (string memory);

  /// @notice Returns the symbol for a given intent token.
  /// @param facility The facility contract address.
  /// @param id The intent token ID.
  /// @return The symbol of the intent token.
  function symbol(IFacility facility, uint256 id) external view returns (string memory);

  /// @notice Returns a description for a given intent token.
  /// @param facility The facility contract address.
  /// @param id The intent token ID.
  /// @return The description of the intent token.
  function description(IFacility facility, uint256 id) external view returns (string memory);

  /// @notice Returns the token URI for a given intent token.
  /// @param facility The facility contract address.
  /// @param id The intent token ID.
  /// @return The token URI containing metadata for the intent token.
  function tokenURI(IFacility facility, uint256 id) external view returns (string memory);
}
