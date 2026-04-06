// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {TransferGuard} from "./TransferGuard.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title TransferGuardFactory
/// @author 3F Protocol
/// @notice Factory contract for deploying TransferGuard instances.
/// @dev This contract implements the beacon proxy pattern for upgradeable deployments:
///      - **UpgradeableBeacon**: The contract type (TransferGuard) has its own beacon
///      - **ERC1967 Beacon Proxy**: Instances are deployed as minimal proxies pointing to the beacon
///      - **LibClone**: Gas-efficient proxy deployment via Solady's clone library
///
///      Architecture:
///      - One beacon is deployed at construction time with the TransferGuard implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createTransferGuard` call deploys one proxy: TransferGuard
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createTransferGuard()` to deploy new TransferGuard instances
///      4. Each transfer guard is initialized with its owner
///
///      Upgrade Flow:
///      1. Beacon owner deploys new TransferGuard implementation contract
///      2. Beacon owner calls `upgradeTo()` on the beacon
///      3. All existing proxies immediately use the new implementation
contract TransferGuardFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new TransferGuard is created.
  /// @param transferGuard The address of the newly deployed TransferGuard proxy
  /// @param owner The address of the transfer guard owner
  event TransferGuardCreated(address indexed transferGuard, address indexed owner);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing TransferGuard implementations.
  /// @dev All TransferGuard proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable TRANSFER_GUARD_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mapping to track all TransferGuard contracts deployed by this factory.
  /// @dev Returns true if the address is a TransferGuard deployed by this factory.
  mapping(address => bool) internal _isTransferGuard;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon contract with the TransferGuard implementation.
  /// @dev Deploys one UpgradeableBeacon wrapping a freshly deployed TransferGuard implementation.
  ///      The beacon owner can later upgrade the implementation for all proxies.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  constructor(address initialBeaconOwner) {
    TRANSFER_GUARD_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new TransferGuard())));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new TransferGuard proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys TransferGuard proxy pointing to TRANSFER_GUARD_BEACON
  ///      2. Initializes the transfer guard with the owner
  ///
  ///      The owner becomes the admin and has exclusive control over the transfer guard.
  ///      Emits a {TransferGuardCreated} event.
  /// @param owner The address that will own the TransferGuard
  /// @return transferGuard The address of the newly deployed TransferGuard proxy
  function createTransferGuard(address owner) external returns (address transferGuard) {
    transferGuard = TRANSFER_GUARD_BEACON.deployERC1967BeaconProxy();

    TransferGuard(transferGuard).initialize(owner);

    _isTransferGuard[transferGuard] = true;

    emit TransferGuardCreated(transferGuard, owner);
  }

  /// @notice Checks if an address is a TransferGuard contract deployed by this factory.
  /// @param transferGuard The address to check
  /// @return True if the address is a TransferGuard deployed by this factory
  function isTransferGuard(address transferGuard) external view returns (bool) {
    return _isTransferGuard[transferGuard];
  }
}
