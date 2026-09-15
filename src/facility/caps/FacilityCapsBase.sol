// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";
import {IFacilityCaps} from "../../interfaces/facility/IFacilityCaps.sol";

/// @title FacilityCapsBase
/// @author 3F Protocol
/// @notice Roles and initialization shared by the IFacilityCaps implementations.
/// @dev Deployed behind minimal proxies: the implementation disables its own initializer.
abstract contract FacilityCapsBase is Initializable, OwnableRoles, IFacilityCaps {
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to manage caps.
  uint256 internal constant CAPS_MANAGER_ROLE = _ROLE_0;
  /// @notice Role for addresses authorized to consume caps.
  uint256 internal constant CAPS_CONSUMER_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the owner and the initial role holders.
  /// @dev Reverts with AddressZero if the owner is zero, since a zero owner could never grant roles.
  /// @param _owner The owner, able to grant and revoke roles.
  /// @param _initialCapsManagers Addresses granted the manager role.
  /// @param _initialCapsConsumers Addresses granted the consumer role (facilities).
  function initialize(address _owner, address[] calldata _initialCapsManagers, address[] calldata _initialCapsConsumers)
    external
    initializer
  {
    _owner.checkNotZero();
    _initializeOwner(_owner);
    _batchGrantRoles(CAPS_MANAGER_ROLE, _initialCapsManagers);
    _batchGrantRoles(CAPS_CONSUMER_ROLE, _initialCapsConsumers);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _batchGrantRoles(uint256 role, address[] calldata accounts) internal {
    uint256 len = accounts.length;
    for (uint256 i = 0; i < len; i++) {
      _grantRoles(accounts[i], role);
    }
  }
}
