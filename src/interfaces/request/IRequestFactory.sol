// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IRequestFactory
/// @author 3F Protocol
/// @notice Minimal interface for deploying new {Request} instances behind beacon proxies.
/// @dev Mirrors the public surface of {RequestFactory.createRequest} used by external callers
///      that only need to deploy / detect a Request. The concrete factory remains the source of
///      truth for the full ABI.
interface IRequestFactory {
  /// @notice Creates a new Request alongside its paired PT and YT token proxies.
  /// @param owner The address that owns the Request (admin privileges, may call setRepaid).
  /// @param puller The address granted the PULLER role.
  /// @param consumer The address granted the CONSUMER role (consume + authorizeMinting).
  /// @param asset The underlying ERC20 asset address.
  /// @param name The base name handed to the PT/YT tokens (prefixed by "PT-" / "YT-").
  /// @param symbol The base symbol handed to the PT/YT tokens (prefixed by "PT-" / "YT-").
  /// @param repaymentDeadline The Unix timestamp at which withdrawals open regardless of repaid.
  /// @param mintToRepaidDelay Minimum delay between the last mint/consume and `setRepaid`.
  /// @return request The deployed Request address.
  /// @return ptToken The deployed PT token address.
  /// @return ytToken The deployed YT token address.
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

  /// @notice Returns whether `request` was deployed by this factory.
  function isRequest(address request) external view returns (bool);
}
