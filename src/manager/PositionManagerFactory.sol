// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {PositionManager} from "./PositionManager.sol";
import {PositionManagerMetadata} from "../libs/manager/LibStorage.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title PositionManagerFactory
/// @notice Factory contract for deploying PositionManager instances.
/// @dev This contract implements the beacon proxy pattern for upgradeable deployments:
///      - **UpgradeableBeacon**: The contract type (PositionManager) has its own beacon
///      - **ERC1967 Beacon Proxy**: Instances are deployed as minimal proxies pointing to the beacon
///      - **LibClone**: Gas-efficient proxy deployment via Solady's clone library
///
///      Architecture:
///      - One beacon is deployed at construction time with the PositionManager implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createPositionManager` call deploys one proxy: PositionManager
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createPositionManager()` to deploy new PositionManager instances
///      4. Each position manager is initialized with its configuration
///
///      Upgrade Flow:
///      1. Beacon owner deploys new PositionManager implementation contract
///      2. Beacon owner calls `upgradeTo()` on the beacon
///      3. All existing proxies immediately use the new implementation
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
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys PositionManager proxy pointing to POSITION_MANAGER_BEACON
  ///      2. Initializes the position manager with owner, token metadata, and configuration
  ///
  ///      The owner becomes the admin and has exclusive control over the position manager.
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
