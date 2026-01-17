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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ADMIN                               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets a new intent descriptor address.
  /// @param descriptor The new descriptor address.
  function setDescriptor(address descriptor) external;
}
