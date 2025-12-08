// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {MorphoBorrowPosition} from "./MorphoBorrowPosition.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {IMorpho, Id} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IPreLiquidation} from "lib/pre-liquidation/src/interfaces/IPreLiquidation.sol";
import {IPreLiquidationFactory} from "lib/pre-liquidation/src/interfaces/IPreLiquidationFactory.sol";

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
///      1. Factory is deployed with an initial beacon owner and pre-liquidation factory
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createBorrowPosition()` to deploy new MorphoBorrowPosition instances
///      4. Each position is initialized with its Morpho market and pre-liquidation contract
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
  /// @param preLiquidation The pre-liquidation contract for this borrow position
  event BorrowPositionCreated(
    address indexed borrowPosition,
    address indexed morpho,
    Id indexed marketId,
    address positionManager,
    address preLiquidation
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing MorphoBorrowPosition implementations.
  /// @dev All MorphoBorrowPosition proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable BORROW_POSITION_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon contract with the MorphoBorrowPosition implementation.
  /// @dev Deploys one UpgradeableBeacon wrapping a freshly deployed MorphoBorrowPosition implementation.
  ///      The beacon owner can later upgrade the implementation for all proxies.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  /// @param preLiquidationFactory The PreLiquidation factory contract address
  constructor(address initialBeaconOwner, IPreLiquidationFactory preLiquidationFactory) {
    BORROW_POSITION_BEACON =
      address(new UpgradeableBeacon(initialBeaconOwner, address(new MorphoBorrowPosition(preLiquidationFactory))));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new MorphoBorrowPosition proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys MorphoBorrowPosition proxy pointing to BORROW_POSITION_BEACON
  ///      2. Initializes the position with Morpho market and pre-liquidation contract
  ///
  ///      The position manager becomes the owner and has exclusive control over the position.
  ///      Emits a {BorrowPositionCreated} event.
  /// @param morpho The Morpho Blue protocol contract address
  /// @param marketId The Morpho market ID for this borrow position
  /// @param positionManager The address of the position manager (owner) that will control this position
  /// @param preLiquidation The pre-liquidation contract for this borrow position
  /// @return borrowPosition The address of the newly deployed MorphoBorrowPosition proxy
  function createBorrowPosition(IMorpho morpho, Id marketId, address positionManager, IPreLiquidation preLiquidation)
    external
    returns (address borrowPosition)
  {
    borrowPosition = BORROW_POSITION_BEACON.deployERC1967IBeaconProxy();

    MorphoBorrowPosition(borrowPosition).initialize(morpho, marketId, positionManager, preLiquidation);

    emit BorrowPositionCreated(borrowPosition, address(morpho), marketId, positionManager, address(preLiquidation));
  }
}
