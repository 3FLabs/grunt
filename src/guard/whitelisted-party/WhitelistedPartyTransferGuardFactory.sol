// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {WhitelistedPartyTransferGuard} from "./WhitelistedPartyTransferGuard.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title WhitelistedPartyTransferGuardFactory
/// @author 3F Protocol
/// @notice Factory for deploying WhitelistedPartyTransferGuard instances via beacon proxy pattern.
/// @dev Architecture mirrors TransferGuardFactory:
///      - One UpgradeableBeacon is deployed at construction time
///      - Each `createTransferGuard` call deploys an ERC1967 beacon proxy
///      - Beacon owner can upgrade all proxies by updating the beacon's implementation
contract WhitelistedPartyTransferGuardFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new WhitelistedPartyTransferGuard is created.
  /// @param transferGuard The address of the newly deployed guard proxy
  /// @param owner The address of the guard owner
  event TransferGuardCreated(address indexed transferGuard, address indexed owner);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon managing WhitelistedPartyTransferGuard implementations.
  address public immutable TRANSFER_GUARD_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Tracks all guards deployed by this factory.
  mapping(address => bool) internal _isTransferGuard;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon with a WhitelistedPartyTransferGuard implementation.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  constructor(address initialBeaconOwner) {
    TRANSFER_GUARD_BEACON =
      address(new UpgradeableBeacon(initialBeaconOwner, address(new WhitelistedPartyTransferGuard())));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new WhitelistedPartyTransferGuard proxy.
  /// @param owner The address that will own the guard
  /// @return transferGuard The address of the newly deployed guard proxy
  function createTransferGuard(address owner) external returns (address transferGuard) {
    transferGuard = TRANSFER_GUARD_BEACON.deployERC1967BeaconProxy();

    WhitelistedPartyTransferGuard(transferGuard).initialize(owner);

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
