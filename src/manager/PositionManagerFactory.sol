// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {PositionManager} from "./PositionManager.sol";
import {PositionManagerMetadata} from "../libs/manager/LibStorage.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title PositionManagerFactory
/// @notice Factory contract for deploying PositionManager instances.
/// @dev Instances are ERC1967 beacon proxies pointing at a single UpgradeableBeacon deployed in
///      the constructor; the beacon owner upgrades all instances at once.
/// @author 3F Protocol
contract PositionManagerFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new PositionManager is created.
  /// @param positionManager The address of the newly deployed PositionManager proxy
  /// @param owner The address of the position manager owner
  /// @param collateralAsset The collateral asset address
  /// @param debtAsset The debt asset address
  /// @param ltv The LTV for available collateral calculation
  /// @param transferGuard The initial transfer guard address (address(0) if disabled)
  event PositionManagerCreated(
    address indexed positionManager,
    address indexed owner,
    address indexed collateralAsset,
    address debtAsset,
    uint256 ltv,
    address transferGuard
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing PositionManager implementations.
  /// @dev All PositionManager proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable POSITION_MANAGER_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mapping to track all PositionManager contracts deployed by this factory.
  /// @dev Returns true if the address is a PositionManager deployed by this factory.
  mapping(address => bool) internal _isPositionManager;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon contract with the PositionManager implementation.
  /// @dev Deploys one UpgradeableBeacon wrapping a freshly deployed PositionManager implementation.
  ///      The beacon owner can later upgrade the implementation for all proxies.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  constructor(address initialBeaconOwner) {
    POSITION_MANAGER_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new PositionManager())));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new PositionManager proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically.
  ///      Emits a {PositionManagerCreated} event.
  /// @param owner The address that will own the PositionManager
  /// @param metadata The metadata containing name, symbol, collateral and debt assets
  /// @param ltv The LTV for available collateral calculation (WAD precision)
  /// @param transferGuard The initial transfer guard address (address(0) to disable)
  /// @param maxRebalanceLoss The max rebalance loss in basis points (e.g., 100 = 1%)
  /// @param rebalanceCooldown The cooldown period in seconds between rebalance calls (0 = disabled)
  /// @return positionManager The address of the newly deployed PositionManager proxy
  function createPositionManager(
    address owner,
    PositionManagerMetadata memory metadata,
    uint256 ltv,
    address transferGuard,
    uint16 maxRebalanceLoss,
    uint40 rebalanceCooldown
  ) external returns (address positionManager) {
    positionManager = POSITION_MANAGER_BEACON.deployERC1967BeaconProxy();

    PositionManager(positionManager)
      .initialize(owner, metadata, ltv, transferGuard, maxRebalanceLoss, rebalanceCooldown);

    _isPositionManager[positionManager] = true;

    emit PositionManagerCreated(
      positionManager, owner, metadata.collateralAsset, metadata.debtAsset, ltv, transferGuard
    );
  }

  /// @notice Checks if an address is a PositionManager contract deployed by this factory.
  /// @param positionManager The address to check
  /// @return True if the address is a PositionManager deployed by this factory
  function isPositionManager(address positionManager) external view returns (bool) {
    return _isPositionManager[positionManager];
  }
}
