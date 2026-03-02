// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFacilityIntents} from "./base/IFacilityIntents.sol";
import {IFacilityFunds} from "./base/IFacilityFunds.sol";
import {IFacilityRequests} from "./base/IFacilityRequests.sol";
import {IFacilityPositionManager} from "./base/IFacilityPositionManager.sol";
import {IFacilityLP} from "./base/IFacilityLP.sol";
import {IFacilitySwap} from "./base/IFacilitySwap.sol";

/// @title IFacility
/// @author 3F Protocol
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

  /// @notice Emitted when the facility pause state is updated.
  /// @param pausedUntil The pause-until timestamp (0 = not paused, type(uint40).max = permanent).
  event FacilityPausedSet(uint40 pausedUntil);

  /// @notice Emitted when the intent descriptor is updated.
  /// @param descriptor The new descriptor address.
  event DescriptorSet(address descriptor);

  /// @notice Emitted when the repay timelock is updated.
  /// @param repayTimelock The new repay timelock duration (seconds).
  event RepayTimelockSet(uint40 repayTimelock);

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

  /// @notice Returns the facility configuration: pause state and repay timelock.
  /// @return isPaused True if paused, false otherwise.
  /// @return pausedUntil The pause-until timestamp (0 = not paused, type(uint40).max = permanent).
  /// @return repayTimelock The minimum delay (seconds) between setRequest and first repay.
  function facilityConfig() external view returns (bool isPaused, uint40 pausedUntil, uint40 repayTimelock);

  /// @notice Returns all tokens and their balances held by an intent.
  /// @dev Useful for displaying intent holdings and calculating claim previews.
  ///      The tokens and amounts arrays are parallel (same length, same order).
  /// @param id The intent ID.
  /// @return tokens The array of token addresses held by the intent.
  /// @return amounts The array of token balances (same order as tokens).
  function intentBalances(uint256 id) external view returns (address[] memory tokens, uint256[] memory amounts);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the earliest timestamp at which repay is allowed for an intent.
  /// @param id The intent ID.
  /// @return The timestamp at which repay becomes available (0 if no request is set).
  function repayAvailableAt(uint256 id) external view returns (uint40);

  /// @notice Sets a new intent descriptor address.
  /// @param descriptor The new descriptor address.
  function setDescriptor(address descriptor) external;

  /// @notice Sets the repay timelock duration.
  /// @param repayTimelock_ The new repay timelock (seconds).
  function setRepayTimelock(uint40 repayTimelock_) external;

  /// @notice Pauses the facility indefinitely.
  function pause() external;

  /// @notice Pauses the facility for a specified duration.
  /// @param duration The duration to pause for (in seconds).
  function pauseFor(uint256 duration) external;

  /// @notice Unpauses the facility.
  function unpause() external;
}
