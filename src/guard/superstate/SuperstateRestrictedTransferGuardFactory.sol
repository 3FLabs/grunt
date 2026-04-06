// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {SuperstateRestrictedTransferGuard} from "./SuperstateRestrictedTransferGuard.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title SuperstateRestrictedTransferGuardFactory
/// @author 3F Protocol
/// @notice Factory for deploying SuperstateRestrictedTransferGuard instances via beacon proxy pattern.
/// @dev The Superstate token address is baked into the implementation at construction time,
///      so all proxies deployed by this factory enforce the same Superstate allowlist.
contract SuperstateRestrictedTransferGuardFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new SuperstateRestrictedTransferGuard is created.
  event TransferGuardCreated(address indexed transferGuard, address indexed owner);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon managing SuperstateRestrictedTransferGuard implementations.
  address public immutable TRANSFER_GUARD_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Tracks all guards deployed by this factory.
  mapping(address => bool) internal _isTransferGuard;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory with a beacon pointing to a SuperstateRestrictedTransferGuard implementation.
  /// @param initialBeaconOwner The address that will own the beacon
  /// @param superstateToken The Superstate token address for allowlist checks
  constructor(address initialBeaconOwner, address superstateToken) {
    TRANSFER_GUARD_BEACON = address(
      new UpgradeableBeacon(initialBeaconOwner, address(new SuperstateRestrictedTransferGuard(superstateToken)))
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new SuperstateRestrictedTransferGuard proxy.
  /// @param owner The address that will own the guard
  /// @return transferGuard The address of the newly deployed guard proxy
  function createTransferGuard(address owner) external returns (address transferGuard) {
    transferGuard = TRANSFER_GUARD_BEACON.deployERC1967BeaconProxy();

    SuperstateRestrictedTransferGuard(transferGuard).initialize(owner);

    _isTransferGuard[transferGuard] = true;

    emit TransferGuardCreated(transferGuard, owner);
  }

  /// @notice Checks if an address is a guard deployed by this factory.
  /// @param transferGuard The address to check
  /// @return True if deployed by this factory
  function isTransferGuard(address transferGuard) external view returns (bool) {
    return _isTransferGuard[transferGuard];
  }
}
