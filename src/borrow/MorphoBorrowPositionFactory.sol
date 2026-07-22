// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MorphoBorrowPosition} from "./MorphoBorrowPosition.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {IMorpho, Id} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IBorrowOffersRegistry} from "../interfaces/borrow/IBorrowOffersRegistry.sol";

/// @title MorphoBorrowPositionFactory
/// @notice Factory contract for deploying MorphoBorrowPosition instances.
/// @dev Beacon factory: the constructor deploys one {UpgradeableBeacon} wrapping a fresh
///      MorphoBorrowPosition implementation, and each `createBorrowPosition` call deploys an
///      ERC1967 beacon proxy behind it. Upgrades flow through the beacon (never through the
///      factory), so every position of a deployment stays behind the single beacon.
///      See docs/deployment.md#post-deployment-wiring.
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

  /// @notice The shared {BorrowOffersRegistry} baked into the MorphoBorrowPosition implementation.
  /// @dev Source of truth for the offer roles and per-collateral offer configuration; see
  ///      {MorphoBorrowPosition.OFFERS_REGISTRY}.
  IBorrowOffersRegistry public immutable OFFERS_REGISTRY;

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
  /// @dev The offers registry must already be deployed and initialized: its address is baked into
  ///      the implementation as an immutable. See docs/deployment.md#post-deployment-wiring for
  ///      the deploy order and the live-chain upgrade path.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  /// @param morpho The Morpho Blue protocol contract address
  /// @param offersRegistry The shared {BorrowOffersRegistry} proxy address
  constructor(address initialBeaconOwner, IMorpho morpho, IBorrowOffersRegistry offersRegistry) {
    MORPHO = morpho;
    OFFERS_REGISTRY = offersRegistry;
    BORROW_POSITION_BEACON =
      address(new UpgradeableBeacon(initialBeaconOwner, address(new MorphoBorrowPosition(morpho, offersRegistry))));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new MorphoBorrowPosition proxy.
  /// @dev Deploys an ERC1967 beacon proxy pointing at BORROW_POSITION_BEACON and initializes it
  ///      atomically. The position manager becomes the owner and has exclusive control over the
  ///      position. Emits a {BorrowPositionCreated} event.
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
