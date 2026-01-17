// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFacilityIntents} from "./base/IFacilityIntents.sol";
import {IFacilityFunds} from "./base/IFacilityFunds.sol";
import {IFacilityRequests} from "./base/IFacilityRequests.sol";
import {IFacilityPositionManager} from "./base/IFacilityPositionManager.sol";
import {IFacilityLP} from "./base/IFacilityLP.sol";
import {IFacilitySwap} from "./base/IFacilitySwap.sol";

/// @title IFacility
/// @notice Combined interface for managing intents, funds, requests, position managers, liquidity providers, and swaps.
interface IFacility is
  IFacilityIntents,
  IFacilityFunds,
  IFacilityRequests,
  IFacilityPositionManager,
  IFacilityLP,
  IFacilitySwap
{
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the intent descriptor is updated.
  /// @param descriptor The new descriptor address.
  event DescriptorSet(address descriptor);

  /// @notice Emitted when a token is sent from an intent.
  /// @param id The intent ID.
  /// @param token The token address.
  /// @param to The address the token was transferred to.
  /// @param amount The amount of tokens sent.
  event TokenSent(uint256 indexed id, address indexed token, address indexed to, uint256 amount);

  /// @notice Emitted when a token is received by an intent.
  /// @param id The intent ID.
  /// @param token The token address.
  /// @param from The address the token was transferred from.
  /// @param amount The amount of tokens received.
  event TokenReceived(uint256 indexed id, address indexed token, address indexed from, uint256 amount);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the balance of a specific token held by an intent.
  /// @param id The intent ID.
  /// @param token The token address.
  /// @return The token balance held by the intent.
  function intentBalance(uint256 id, address token) external view returns (uint256);

  /// @notice Returns all tokens held by an intent.
  /// @param id The intent ID.
  /// @return tokens The array of token addresses held by the intent.
  function intentTokens(uint256 id) external view returns (address[] memory tokens);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ADMIN                               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets a new intent descriptor address.
  /// @param descriptor The new descriptor address.
  function setDescriptor(address descriptor) external;
}
