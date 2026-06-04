// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibRetargetter, RetargetterStorage} from "../../../libs/manager/rebalancer/LibRetargetter.sol";
import {LibRetargetterErrors} from "../../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibPause} from "../../../libs/common/LibPause.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @title RetargetterBase
/// @author 3F Protocol
/// @notice Shared foundation every Retargetter sub-base extends.
/// @dev Centralises ownership, role management, pause checking, and the transient reentrancy
///      guard. Every sub-base extends this directly to keep the C3 linearisation flat: the main
///      {Retargetter} contract then composes all of them without ambiguity.
abstract contract RetargetterBase is OwnableRoles, ReentrancyGuardTransient {
  using LibPause for uint40;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          MODIFIERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts with {Paused} if the Retargetter is currently paused. Used on every operational
  ///      surface that should not run during an incident (open batch, consume, authorise, propose,
  ///      execute). Cancellation / close paths remain callable even while paused.
  modifier whenNotPaused() {
    if (LibRetargetter.retargetterStorage().pauseUntil.paused()) revert LibRetargetterErrors.Paused();
    _;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OVERRIDES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ReentrancyGuardTransient
  /// @dev Always use transient storage for the reentrancy guard (testnets included), matching the
  ///      convention used elsewhere in this codebase.
  function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
    return false;
  }
}
