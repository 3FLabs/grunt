// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {CentrifugeFund} from "./CentrifugeFund.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";

/// @title CentrifugeFundFactory
/// @author 3F Protocol
/// @notice Factory contract for deploying CentrifugeFund instances.
/// @dev This contract implements the beacon proxy pattern for upgradeable deployments:
///      - **UpgradeableBeacon**: The contract type (CentrifugeFund) has its own beacon
///      - **ERC1967 Beacon Proxy**: Instances are deployed as minimal proxies pointing to the beacon
///      - **LibClone**: Gas-efficient proxy deployment via Solady's clone library
///      Architecture:
///      - One beacon is deployed at construction time with the CentrifugeFund implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createFund` call deploys one proxy: CentrifugeFund
///      - Each fund targets a different vault/wrappedShare (per-proxy storage)
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createFund()` to deploy new CentrifugeFund instances
///      4. Each fund is initialized with per-fund parameters (vault, wrappedShare + roles)
///      5. **Post-deployment**: WrappedAsset owner must grant ISSUER_ROLE to the new fund
contract CentrifugeFundFactory {
  using LibClone for address;
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the factory is deployed.
  event FactoryDeployed();

  /// @notice Emitted when a new CentrifugeFund is created.
  /// @param fund The address of the newly deployed CentrifugeFund proxy.
  /// @param vault The Centrifuge vault address.
  event FundCreated(address indexed fund, address indexed vault);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing CentrifugeFund implementations.
  /// @dev All CentrifugeFund proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable CENTRIFUGE_FUND_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon contract with the CentrifugeFund implementation.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations).
  constructor(address initialBeaconOwner) {
    CENTRIFUGE_FUND_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new CentrifugeFund())));

    emit FactoryDeployed();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new CentrifugeFund proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys CentrifugeFund proxy pointing to CENTRIFUGE_FUND_BEACON
  ///      2. Initializes the fund with per-fund parameters
  ///
  ///      **IMPORTANT**: After deployment, the WrappedAsset owner must grant ISSUER_ROLE
  ///      to the newly deployed fund address so it can mint wrapped tokens.
  ///
  ///      The depositor receives DEPOSITOR_ROLE on the fund (can execute orders).
  ///      Emits a {FundCreated} event.
  /// @param owner The address that will own the CentrifugeFund (admin privileges).
  /// @param depositor The address that will have the depositor role (must be a contract).
  /// @param vault The Centrifuge ERC-7540 vault address.
  /// @param wrappedShare The WrappedAsset address wrapping the vault's share token.
  /// @return fund The address of the newly deployed CentrifugeFund proxy.
  function createFund(address owner, address depositor, address vault, address wrappedShare)
    external
    returns (address fund)
  {
    // Deploy CentrifugeFund proxy
    fund = CENTRIFUGE_FUND_BEACON.deployERC1967BeaconProxy();

    // Initialize CentrifugeFund
    CentrifugeFund(fund).initialize(owner, depositor, vault, wrappedShare);

    emit FundCreated(fund, vault);
  }
}
