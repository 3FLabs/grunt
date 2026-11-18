// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {IFacilityCapsWhitelist} from "../../interfaces/facility/IFacilityCapsWhitelist.sol";

/// @title FacilityCapsWhitelist
/// @author 3F Protocol
/// @notice Owner-managed registry of the IFacilityCaps contracts facilities may point cap words at.
/// @dev Referenced by facilities through an immutable, so one registry serves every facility
///      built with it. Not upgradeable: replacing it means redeploying the facility implementation.
///      Its owner must be a trusted multisig, and it should only allow caps contracts whose owner
///      and managers are trusted multisigs too.
contract FacilityCapsWhitelist is Ownable, IFacilityCapsWhitelist {
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  mapping(address => bool) internal _allowed;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  constructor(address _owner) {
    _owner.checkNotZero();
    _initializeOwner(_owner);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityCapsWhitelist
  function isAllowed(address caps) external view returns (bool) {
    return _allowed[caps];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityCapsWhitelist
  /// @dev Reverts with InvalidContract when allowing a codeless address.
  function setAllowed(address caps, bool allowed) external onlyOwner {
    if (allowed) caps.checkContract();
    _allowed[caps] = allowed;
    emit CapsAllowed(caps, allowed);
  }
}
