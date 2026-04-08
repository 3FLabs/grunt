// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MorphoBorrowPosition} from "./MorphoBorrowPosition.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {IMorpho, Id} from "lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title MorphoBorrowPositionFactory
/// @notice Factory contract for deploying MorphoBorrowPosition instances.
/// @dev This contract implements the beacon proxy pattern for upgradeable deployments:
///      - **UpgradeableBeacon**: The contract type (MorphoBorrowPosition) has its own beacon
///      - **ERC1967 Beacon Proxy**: Instances are deployed as minimal proxies pointing to the beacon
///      - **LibClone**: Gas-efficient proxy deployment via Solady's clone library
///
///      Architecture:
///      - One beacon is deployed at construction time with the MorphoBorrowPosition implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createBorrowPosition` call deploys one proxy: MorphoBorrowPosition
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createBorrowPosition()` to deploy new MorphoBorrowPosition instances
///      4. Each position is initialized with its Morpho market and custom LTV
///
///      Upgrade Flow:
///      1. Beacon owner deploys new MorphoBorrowPosition implementation contract
///      2. Beacon owner calls `upgradeTo()` on the beacon
///      3. All existing proxies immediately use the new implementation
/// @author 3F Protocol
contract MorphoBorrowPositionFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new MorphoBorrowPosition is created.
  /// @param borrowPosition The address of the newly deployed MorphoBorrowPosition proxy
  /// @param morpho The Morpho protocol contract address
  /// @param marketId The Morpho market ID for this borrow position
  /// @param positionManager The address of the position manager (owner)
  /// @param safeLtv The safe LTV threshold for position mutations
  /// @param liquidationLtv The liquidation LTV for this borrow position
  event BorrowPositionCreated(
    address indexed borrowPosition,
    address indexed morpho,
    Id indexed marketId,
    address positionManager,
    uint128 safeLtv,
    uint128 liquidationLtv
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing MorphoBorrowPosition implementations.
  /// @dev All MorphoBorrowPosition proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable BORROW_POSITION_BEACON;

  /// @notice The Morpho Blue protocol contract address shared by all borrow positions.
  IMorpho public immutable MORPHO;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mapping to track all MorphoBorrowPosition contracts deployed by this factory.
  /// @dev Returns true if the address is a MorphoBorrowPosition deployed by this factory.
  mapping(address => bool) internal _isBorrowPosition;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon contract with the MorphoBorrowPosition implementation.
  /// @dev Deploys one UpgradeableBeacon wrapping a freshly deployed MorphoBorrowPosition implementation.
  ///      The beacon owner can later upgrade the implementation for all proxies.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  /// @param morpho The Morpho Blue protocol contract address
  constructor(address initialBeaconOwner, IMorpho morpho) {
    MORPHO = morpho;
    BORROW_POSITION_BEACON =
      address(new UpgradeableBeacon(initialBeaconOwner, address(new MorphoBorrowPosition(morpho))));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new MorphoBorrowPosition proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys MorphoBorrowPosition proxy pointing to BORROW_POSITION_BEACON
  ///      2. Initializes the position with Morpho market and custom LTVs
  ///
  ///      The position manager becomes the owner and has exclusive control over the position.
  ///      Emits a {BorrowPositionCreated} event.
  /// @param marketId The Morpho market ID for this borrow position
  /// @param positionManager The address of the position manager (owner) that will control this position
  /// @param safeLtv The safe LTV threshold for position mutations (must be > 0 and < liquidationLtv)
  /// @param liquidationLtv The liquidation LTV for this borrow position (must be > safeLtv, <= WAD, and <= market LLTV)
  /// @return borrowPosition The address of the newly deployed MorphoBorrowPosition proxy
  function createBorrowPosition(Id marketId, address positionManager, uint128 safeLtv, uint128 liquidationLtv)
    external
    returns (address borrowPosition)
  {
    borrowPosition = BORROW_POSITION_BEACON.deployERC1967BeaconProxy();

    MorphoBorrowPosition(borrowPosition).initialize(marketId, positionManager, safeLtv, liquidationLtv);

    _isBorrowPosition[borrowPosition] = true;

    emit BorrowPositionCreated(borrowPosition, address(MORPHO), marketId, positionManager, safeLtv, liquidationLtv);
  }

  /// @notice Checks if an address is a MorphoBorrowPosition contract deployed by this factory.
  /// @param borrowPosition The address to check
  /// @return True if the address is a MorphoBorrowPosition deployed by this factory
  function isBorrowPosition(address borrowPosition) external view returns (bool) {
    return _isBorrowPosition[borrowPosition];
  }
}
