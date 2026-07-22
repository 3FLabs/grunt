// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Request} from "./Request.sol";
import {Vault} from "./Vault.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title RequestFactory
/// @author 3F Protocol
/// @notice Factory contract for deploying Request instances with their associated PT and YT tokens.
/// @dev The constructor deploys three UpgradeableBeacons (Request, PT Vault, YT Vault); each
///      `createRequest` call deploys one beacon proxy per kind, and the beacon owner upgrades
///      every proxy of a kind at once. See docs/deployment.md#factories.
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
  /*                          STORAGE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mapping to track all Request contracts deployed by this factory.
  /// @dev Returns true if the address is a Request deployed by this factory.
  mapping(address => bool) internal _isRequest;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the factory and creates all beacon contracts with their implementations.
  /// @dev Deploys three UpgradeableBeacons, each wrapping a freshly deployed implementation:
  ///      - Request beacon with a new Request implementation
  ///      - PT Token beacon with a new Vault(false) implementation
  ///      - YT Token beacon with a new Vault(true) implementation
  ///      The beacon owner can later upgrade implementations for all proxies.
  /// @param initialBeaconOwner The address that will own all three beacons (can upgrade implementations)
  constructor(address initialBeaconOwner) {
    REQUEST_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new Request())));
    PT_TOKEN_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new Vault(false))));
    YT_TOKEN_BEACON = address(new UpgradeableBeacon(initialBeaconOwner, address(new Vault(true))));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FACTORY METHODS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new Request with its associated PT and YT token proxies.
  /// @dev Deploys three ERC1967 beacon proxies (Request, PT token, YT token) and initializes them
  ///      atomically; the Request becomes the controller of both tokens.
  /// @param owner The address that will own the Request (admin privileges)
  /// @param puller The address that will have the puller role
  /// @param consumer The address that will have the consumer role (can call consume and authorizeMinting)
  /// @param asset The underlying ERC20 asset address (e.g., USDC)
  /// @param name The base name for PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @param symbol The base symbol for PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @param repaymentDeadline The timestamp after which withdrawals are automatically enabled, regardless of repaid status
  /// @param mintToRepaidDelay Minimum delay (seconds) between the last mint/consume and setRepaid()
  /// @return request The address of the newly deployed Request proxy
  /// @return ptToken The address of the newly deployed PT Token proxy
  /// @return ytToken The address of the newly deployed YT Token proxy
  function createRequest(
    address owner,
    address puller,
    address consumer,
    address asset,
    string memory name,
    string memory symbol,
    uint64 repaymentDeadline,
    uint40 mintToRepaidDelay
  ) external returns (address request, address ptToken, address ytToken) {
    request = REQUEST_BEACON.deployERC1967BeaconProxy();
    ptToken = PT_TOKEN_BEACON.deployERC1967BeaconProxy();
    ytToken = YT_TOKEN_BEACON.deployERC1967BeaconProxy();

    Request(request)
      .initialize(owner, puller, consumer, asset, ptToken, ytToken, name, symbol, repaymentDeadline, mintToRepaidDelay);
    Vault(ptToken).initialize(request);
    Vault(ytToken).initialize(request);

    _isRequest[request] = true;

    emit RequestCreated(request, asset, ptToken, ytToken);
  }

  /// @notice Checks if an address is a Request contract deployed by this factory.
  /// @param request The address to check
  /// @return True if the address is a Request deployed by this factory
  function isRequest(address request) external view returns (bool) {
    return _isRequest[request];
  }
}
