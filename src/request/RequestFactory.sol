// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Request} from "./Request.sol";
import {Vault} from "./Vault.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title RequestFactory
/// @notice Factory contract for deploying Request instances with their associated PT and YT tokens.
/// @dev This contract implements the beacon proxy pattern for upgradeable deployments:
///      - **UpgradeableBeacon**: Each contract type (Request, PT Token, YT Token) has its own beacon
///      - **ERC1967 Beacon Proxy**: Instances are deployed as minimal proxies pointing to their beacon
///      - **LibClone**: Gas-efficient proxy deployment via Solady's clone library
///
///      Architecture:
///      - Three beacons are deployed at construction time, each with its implementation
///      - The beacon owner can upgrade all proxies by updating the beacon's implementation
///      - Each `createRequest` call deploys three proxies: Request, PT Token, and YT Token
///
///      Deployment Flow:
///      1. Factory is deployed with an initial beacon owner
///      2. Constructor deploys implementations and wraps them in UpgradeableBeacons
///      3. Users call `createRequest()` to deploy new Request instances
///      4. Each request gets its own PT and YT token proxies, all initialized atomically
///
///      Upgrade Flow:
///      1. Beacon owner deploys new implementation contract
///      2. Beacon owner calls `upgradeTo()` on the appropriate beacon
///      3. All existing proxies immediately use the new implementation
contract RequestFactory {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new Request and its associated tokens are created.
  /// @param request The address of the newly deployed Request proxy
  /// @param asset The underlying ERC20 asset for the request
  /// @param ptToken The address of the Principal Token proxy
  /// @param ytToken The address of the Yield Token proxy
  event RequestCreated(address request, address asset, address ptToken, address ytToken);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The UpgradeableBeacon contract managing Request implementations.
  /// @dev All Request proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable REQUEST_BEACON;

  /// @notice The UpgradeableBeacon contract managing Principal Token (PT) implementations.
  /// @dev All PT token proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable PT_TOKEN_BEACON;

  /// @notice The UpgradeableBeacon contract managing Yield Token (YT) implementations.
  /// @dev All YT token proxies deployed by this factory delegate to this beacon's implementation.
  address public immutable YT_TOKEN_BEACON;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates all beacon contracts with their implementations.
  /// @dev Deploys three UpgradeableBeacons, each wrapping a freshly deployed implementation:
  ///      - Request beacon with a new Request implementation
  ///      - PT Token beacon with a new Vault(false) implementation
  ///      - YT Token beacon with a new Vault(true) implementation
  ///      The beacon owner can later upgrade implementations for all proxies.
  /// @param intialBeaconOwner The address that will own all three beacons (can upgrade implementations)
  constructor(address intialBeaconOwner) {
    REQUEST_BEACON = address(new UpgradeableBeacon(intialBeaconOwner, address(new Request())));
    PT_TOKEN_BEACON = address(new UpgradeableBeacon(intialBeaconOwner, address(new Vault(false))));
    YT_TOKEN_BEACON = address(new UpgradeableBeacon(intialBeaconOwner, address(new Vault(true))));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new Request with its associated PT and YT token proxies.
  /// @dev Deploys three ERC1967 beacon proxies and initializes them atomically:
  ///      1. Deploys Request proxy pointing to REQUEST_BEACON
  ///      2. Deploys PT Token proxy pointing to PT_TOKEN_BEACON
  ///      3. Deploys YT Token proxy pointing to YT_TOKEN_BEACON
  ///      4. Initializes Request with owner, asset, token addresses, and metadata
  ///      5. Initializes both tokens with the Request as their controller
  ///
  ///      The Request becomes the controller for both tokens, managing minting and burning.
  ///      Emits a {RequestCreated} event.
  /// @param owner The address that will own the Request (admin privileges)
  /// @param puller The address that will have the puller role
  /// @param asset The underlying ERC20 asset address (e.g., USDC)
  /// @param name The base name for PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @param symbol The base symbol for PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @return request The address of the newly deployed Request proxy
  /// @return ptToken The address of the newly deployed PT Token proxy
  /// @return ytToken The address of the newly deployed YT Token proxy
  function createRequest(address owner, address puller, address asset, string memory name, string memory symbol)
    external
    returns (address request, address ptToken, address ytToken)
  {
    request = REQUEST_BEACON.deployERC1967IBeaconProxy();
    ptToken = PT_TOKEN_BEACON.deployERC1967IBeaconProxy();
    ytToken = YT_TOKEN_BEACON.deployERC1967IBeaconProxy();

    Request(request).initialize(owner, puller, asset, ptToken, ytToken, name, symbol);
    Vault(ptToken).initialize(request);
    Vault(ytToken).initialize(request);

    emit RequestCreated(request, asset, ptToken, ytToken);
  }
}
