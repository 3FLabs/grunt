// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MorphoFlashLoanRequest} from "./MorphoFlashLoanRequest.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {IMorpho} from "lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title MorphoFlashLoanRequestFactory
/// @notice Factory contract for deploying MorphoFlashLoanRequest instances.
/// @dev This contract implements the beacon proxy pattern for upgradeable deployments:
///      - **UpgradeableBeacon**: The contract type (MorphoFlashLoanRequest) has its own beacon
///      - **ERC1967 Beacon Proxy**: Instances are deployed as minimal proxies pointing to the beacon
///      - **LibClone**: Gas-efficient proxy deployment via Solady's clone library
///
///      Architecture:
///      - One beacon is deployed at construction time with the MorphoFlashLoanRequest implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createFlashLoanRequest` call deploys one proxy: MorphoFlashLoanRequest
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner
///      2. Constructor deploys implementation and wraps it in an UpgradeableBeacon
///      3. Users call `createFlashLoanRequest()` to deploy new MorphoFlashLoanRequest instances
///      4. Each request is initialized with its owner, facility, and asset
///
///      Upgrade Flow:
///      1. Beacon owner deploys new MorphoFlashLoanRequest implementation contract
///      2. Beacon owner calls `upgradeTo()` on the beacon
///      3. All existing proxies immediately use the new implementation
/// @author 3F Protocol
contract MorphoFlashLoanRequestFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new MorphoFlashLoanRequest is created.
  /// @param flashLoanRequest The address of the newly deployed MorphoFlashLoanRequest proxy
  /// @param owner The owner of the flash loan request
  /// @param executor The address granted EXECUTOR_ROLE
  /// @param facility The facility contract address
  /// @param asset The underlying asset token address
  event FlashLoanRequestCreated(
    address indexed flashLoanRequest, address indexed owner, address executor, address facility, address asset
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing MorphoFlashLoanRequest implementations.
  /// @dev All MorphoFlashLoanRequest proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable FLASH_LOAN_REQUEST_BEACON;

  /// @notice The Morpho Blue protocol contract address shared by all flash loan requests.
  IMorpho public immutable MORPHO;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mapping to track all MorphoFlashLoanRequest contracts deployed by this factory.
  /// @dev Returns true if the address is a MorphoFlashLoanRequest deployed by this factory.
  mapping(address => bool) internal _isFlashLoanRequest;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates the beacon contract with the MorphoFlashLoanRequest implementation.
  /// @dev Deploys one UpgradeableBeacon wrapping a freshly deployed MorphoFlashLoanRequest implementation.
  ///      The beacon owner can later upgrade the implementation for all proxies.
  /// @param initialBeaconOwner The address that will own the beacon (can upgrade implementations)
  /// @param morpho The Morpho Blue protocol contract address
  constructor(address initialBeaconOwner, IMorpho morpho) {
    MORPHO = morpho;
    FLASH_LOAN_REQUEST_BEACON =
      address(new UpgradeableBeacon(initialBeaconOwner, address(new MorphoFlashLoanRequest(address(morpho)))));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new MorphoFlashLoanRequest proxy.
  /// @dev Deploys an ERC1967 beacon proxy and initializes it atomically:
  ///      1. Deploys MorphoFlashLoanRequest proxy pointing to FLASH_LOAN_REQUEST_BEACON
  ///      2. Initializes the request with owner, executor, facility, and asset
  ///
  ///      The owner manages scripts and can rescue tokens. The executor calls execute.
  ///      Emits a {FlashLoanRequestCreated} event.
  /// @param owner_ The owner who can manage scripts and rescue tokens
  /// @param executor The address granted EXECUTOR_ROLE to call execute
  /// @param facility The facility contract address
  /// @param asset The underlying asset token address
  /// @return flashLoanRequest The address of the newly deployed MorphoFlashLoanRequest proxy
  function createFlashLoanRequest(address owner_, address executor, address facility, address asset)
    external
    returns (address flashLoanRequest)
  {
    flashLoanRequest = FLASH_LOAN_REQUEST_BEACON.deployERC1967BeaconProxy();

    MorphoFlashLoanRequest(flashLoanRequest).initialize(owner_, executor, facility, asset);

    _isFlashLoanRequest[flashLoanRequest] = true;

    emit FlashLoanRequestCreated(flashLoanRequest, owner_, executor, facility, asset);
  }

  /// @notice Checks if an address is a MorphoFlashLoanRequest contract deployed by this factory.
  /// @param flashLoanRequest The address to check
  /// @return True if the address is a MorphoFlashLoanRequest deployed by this factory
  function isFlashLoanRequest(address flashLoanRequest) external view returns (bool) {
    return _isFlashLoanRequest[flashLoanRequest];
  }
}
