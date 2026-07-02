// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Retargetter} from "./Retargetter.sol";
import {RetargetterConfig} from "../../interfaces/manager/rebalancer/IRetargetter.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title RetargetterFactory
/// @author 3F Protocol
/// @notice Factory contract for deploying Retargetter instances as beacon proxies.
/// @dev One instance per (collateralAsset, debtAsset) pair is the expected topology: a single
///      instance serves every PositionManager on that pair. Creation is permissionless; all
///      authority comes from the roles granted afterwards.
///
///      Post-deployment wiring checklist:
///      1. Each served PositionManager's owner grants the instance REBALANCER_ROLE (bit
///         value 4) and configures `maxRebalanceLoss` of at least one basis point (Morpho
///         rounding dust otherwise reverts valid rebalances).
///      2. Fund owners grant the instance DEPOSITOR_ROLE on every whitelisted fund, and the
///         upstream venue allowlists (Superstate, Centrifuge, WrappedAsset roles) must
///         include the instance. Dedicated fund instances only: funds hold a single global
///         order slot, so sharing an instance with the Facility or another Retargetter
///         creates order liveness collisions.
///      3. Deploy the MorphoFlashLoanAdapter once per chain (its constructor takes Morpho
///         Blue's address).
///      4. The instance owner grants REBALANCER and CONSUMER roles, whitelists funds and the
///         adapter, and sets the yield estimates.
contract RetargetterFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new Retargetter is created.
  /// @param retargetter The address of the newly deployed Retargetter proxy
  /// @param owner The address of the instance owner
  /// @param collateralAsset The bound collateral asset
  /// @param debtAsset The bound debt asset
  event RetargetterCreated(
    address indexed retargetter, address indexed owner, address indexed collateralAsset, address debtAsset
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon managing the Retargetter implementation.
  /// @dev All Retargetter proxies deployed by this factory delegate to this beacon's
  ///      implementation.
  address public immutable RETARGETTER_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mapping to track all Retargetter contracts deployed by this factory.
  mapping(address => bool) internal _isRetargetter;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon with the Retargetter implementation.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade the implementation)
  /// @param quoter The stateless quoter shared by every instance
  /// @param requestFactory The Request factory shared by every instance
  constructor(address initialBeaconOwner, address quoter, address requestFactory) {
    RETARGETTER_BEACON =
      address(new UpgradeableBeacon(initialBeaconOwner, address(new Retargetter(quoter, requestFactory))));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new Retargetter proxy bound to an asset pair.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically. Emits a
  ///      {RetargetterCreated} event.
  /// @param owner The address that will own the Retargetter
  /// @param collateralAsset The collateral asset of the bound pair
  /// @param debtAsset The debt asset of the bound pair
  /// @param config The initial configuration
  /// @return retargetter The address of the newly deployed Retargetter proxy
  function createRetargetter(
    address owner,
    address collateralAsset,
    address debtAsset,
    RetargetterConfig calldata config
  ) external returns (address retargetter) {
    retargetter = RETARGETTER_BEACON.deployERC1967BeaconProxy();

    Retargetter(retargetter).initialize(owner, collateralAsset, debtAsset, config);

    _isRetargetter[retargetter] = true;

    emit RetargetterCreated(retargetter, owner, collateralAsset, debtAsset);
  }

  /// @notice Checks if an address is a Retargetter contract deployed by this factory.
  /// @param retargetter The address to check
  /// @return True if the address is a Retargetter deployed by this factory
  function isRetargetter(address retargetter) external view returns (bool) {
    return _isRetargetter[retargetter];
  }
}
