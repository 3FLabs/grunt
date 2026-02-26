// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {USCCFund} from "./USCCFund.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";

/// @title USCCFundFactory
/// @author 3F Protocol
/// @notice Factory contract for deploying USCCFund instances.
/// @dev This contract implements the beacon proxy pattern for upgradeable deployments:
///      - **UpgradeableBeacon**: The contract type (USCCFund) has its own beacon
///      - **ERC1967 Beacon Proxy**: Instances are deployed as minimal proxies pointing to the beacon
///      - **LibClone**: Gas-efficient proxy deployment via Solady's clone library
///
///      Architecture:
///      - One beacon is deployed at construction time with the USCCFund implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createFund` call deploys one proxy: USCCFund
///      - Multiple USCCFund instances can share the same WrappedAsset token
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner and token addresses
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createFund()` to deploy new USCCFund instances
///      4. Each fund is initialized with per-fund parameters (recipient + oracle + roles)
///      5. **Post-deployment**: WrappedAsset owner must grant ISSUER_ROLE to the new fund
///
///      Upgrade Flow:
///      1. Beacon owner deploys new USCCFund implementation contract
///      2. Beacon owner calls `upgradeTo()` on the beacon
///      3. All existing proxies immediately use the new implementation
contract USCCFundFactory {
  using LibClone for address;
  using LibChecks for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the factory is deployed.
  /// @param usdc The underlying USDC token address used by all funds.
  /// @param uscc The underlying USCC token address used by all funds.
  /// @param wrappedAsset The address of the WrappedAsset token used by all funds.
  event FactoryDeployed(address indexed usdc, address indexed uscc, address indexed wrappedAsset);

  /// @notice Emitted when a new USCCFund is created.
  /// @param fund The address of the newly deployed USCCFund proxy
  /// @param recipient The Superstate recipient address
  event FundCreated(address indexed fund, address indexed recipient);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing USCCFund implementations.
  /// @dev All USCCFund proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable USCC_FUND_BEACON;

  /// @notice The USDC token address used by all USCCFund instances created by this factory.
  address public immutable USDC;

  /// @notice The USCC token address used by all USCCFund instances created by this factory.
  address public immutable USCC;

  /// @notice The wUSCC token address used by all USCCFund instances created by this factory.
  address public immutable WUSCC;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mapping to track all USCCFund contracts deployed by this factory.
  /// @dev Returns true if the address is a USCCFund deployed by this factory.
  mapping(address => bool) internal _isFund;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon contract with the USCCFund implementation.
  /// @dev Deploys one UpgradeableBeacon wrapping a freshly deployed USCCFund implementation.
  ///      The beacon owner can later upgrade the implementation for all proxies.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  /// @param usdc The USDC token address used by all funds.
  /// @param uscc The USCC token address used by all funds.
  /// @param wuscc The wUSCC token address used by all funds.
  constructor(address initialBeaconOwner, address usdc, address uscc, address wuscc) {
    usdc.checkContract();
    uscc.checkContract();
    wuscc.checkContract();

    USDC = usdc;
    USCC = uscc;
    WUSCC = wuscc;

    USCC_FUND_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new USCCFund(usdc, uscc, wuscc))));

    emit FactoryDeployed(usdc, uscc, wuscc);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new USCCFund proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys USCCFund proxy pointing to USCC_FUND_BEACON
  ///      2. Initializes the fund with per-fund parameters (owner, depositor, recipient, oracle)
  ///
  ///      **IMPORTANT**: After deployment, the WrappedAsset owner must grant ISSUER_ROLE
  ///      to the newly deployed fund address so it can mint wrapped tokens.
  ///
  ///      The depositor receives _DEPOSITOR_ROLE on the fund (can execute orders).
  ///      Emits a {FundCreated} event.
  /// @param owner The address that will own the USCCFund (admin privileges)
  /// @param depositor The address that will have the depositor role (must be a contract)
  /// @param recipient The Superstate address receiving USDC to mint USCC
  /// @param oracle The Chainlink USCC price oracle address (must be a contract)
  /// @return fund The address of the newly deployed USCCFund proxy
  function createFund(address owner, address depositor, address recipient, address oracle)
    external
    returns (address fund)
  {
    // Deploy USCCFund proxy
    fund = USCC_FUND_BEACON.deployERC1967BeaconProxy();

    // Initialize USCCFund
    USCCFund(fund).initialize(owner, depositor, recipient, oracle);

    _isFund[fund] = true;

    emit FundCreated(fund, recipient);
  }

  /// @notice Checks if an address is a USCCFund contract deployed by this factory.
  /// @param fund The address to check
  /// @return True if the address is a USCCFund deployed by this factory
  function isFund(address fund) external view returns (bool) {
    return _isFund[fund];
  }
}
