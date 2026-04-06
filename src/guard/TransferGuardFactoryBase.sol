// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title TransferGuardFactoryBase
/// @author 3F Protocol
/// @notice Abstract base for all TransferGuard factory contracts.
/// @dev Encapsulates the beacon proxy deployment pattern shared by every guard factory:
///      - One UpgradeableBeacon (set once in constructor by the child)
///      - `createTransferGuard(owner)` deploys an ERC1967 beacon proxy, initializes it, and tracks it
///      - `isTransferGuard(address)` view for deployment verification
///
///      Child contracts only need to supply the beacon address via `super(beacon)` in their constructor.
///      All guards are expected to expose `initialize(address owner)` with the same selector.
abstract contract TransferGuardFactoryBase {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new TransferGuard is created.
  /// @param transferGuard The address of the newly deployed guard proxy
  /// @param owner The address of the guard owner
  event TransferGuardCreated(address indexed transferGuard, address indexed owner);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing guard implementations.
  /// @dev All guard proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable TRANSFER_GUARD_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Tracks all guard contracts deployed by this factory.
  mapping(address => bool) internal _isTransferGuard;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @param beacon The pre-deployed UpgradeableBeacon address
  constructor(address beacon) {
    TRANSFER_GUARD_BEACON = beacon;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new guard proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys guard proxy pointing to TRANSFER_GUARD_BEACON
  ///      2. Calls `initialize(owner)` on the proxy
  ///      3. Records the proxy in `_isTransferGuard`
  ///
  ///      Emits a {TransferGuardCreated} event.
  /// @param owner The address that will own the guard
  /// @return transferGuard The address of the newly deployed guard proxy
  function createTransferGuard(address owner) external virtual returns (address transferGuard) {
    transferGuard = TRANSFER_GUARD_BEACON.deployERC1967BeaconProxy();

    _initializeGuard(transferGuard, owner);

    _isTransferGuard[transferGuard] = true;

    emit TransferGuardCreated(transferGuard, owner);
  }

  /// @notice Checks if an address is a guard deployed by this factory.
  /// @param transferGuard The address to check
  /// @return True if deployed by this factory
  function isTransferGuard(address transferGuard) external view returns (bool) {
    return _isTransferGuard[transferGuard];
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INTERNALS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Initializes the freshly deployed guard proxy. Override to cast to the concrete type.
  /// @param guard The guard proxy address
  /// @param owner The owner to initialize with
  function _initializeGuard(address guard, address owner) internal virtual;
}
