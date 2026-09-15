// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IRequestFactory
/// @author 3F Protocol
/// @notice Interface for the factory deploying Request instances with their PT and YT tokens.
interface IRequestFactory {
  /// @notice Creates a new Request with its associated PT and YT token proxies.
  /// @param owner The address that will own the Request (admin privileges)
  /// @param puller The address that will have the puller role
  /// @param consumer The address that will have the consumer role
  /// @param asset The underlying ERC20 asset address
  /// @param name The base name for PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @param symbol The base symbol for PT/YT tokens (prefixed with "PT-" / "YT-")
  /// @param repaymentDeadline The timestamp after which withdrawals are automatically enabled
  /// @param mintToRepaidDelay Minimum delay (seconds) between the last mint/consume and setRepaid
  /// @return request The address of the newly deployed Request proxy
  /// @return ptToken The address of the newly deployed PT token proxy
  /// @return ytToken The address of the newly deployed YT token proxy
  function createRequest(
    address owner,
    address puller,
    address consumer,
    address asset,
    string memory name,
    string memory symbol,
    uint64 repaymentDeadline,
    uint40 mintToRepaidDelay
  ) external returns (address request, address ptToken, address ytToken);

  /// @notice Checks if an address is a Request contract deployed by this factory.
  /// @param request The address to check
  /// @return True if the address is a Request deployed by this factory
  function isRequest(address request) external view returns (bool);
}
