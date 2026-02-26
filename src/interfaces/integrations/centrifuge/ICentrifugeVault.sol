// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title ICentrifugeVault
/// @author 3F Protocol
/// @notice Minimal interface for interacting with a Centrifuge ERC-7540 vault.
interface ICentrifugeVault {
  /// @notice Returns the underlying asset of the vault.
  function asset() external view returns (address);

  /// @notice Returns the share token of the vault.
  function share() external view returns (address);

  /// @notice Converts an asset amount to the equivalent share amount.
  /// @param assets The number of assets to convert.
  /// @return The equivalent amount of shares.
  function convertToShares(uint256 assets) external view returns (uint256);

  /// @notice Converts a share amount to the equivalent asset amount.
  /// @param shares The number of shares to convert.
  /// @return The equivalent amount of assets.
  function convertToAssets(uint256 shares) external view returns (uint256);

  /// @notice Returns the maximum number of shares that can be minted (claimed) for a controller.
  /// @param controller The address of the controller.
  /// @return The maximum mintable shares.
  function maxMint(address controller) external view returns (uint256);

  /// @notice Returns the maximum amount of assets that can be withdrawn (claimed) for a controller.
  /// @param controller The address of the controller.
  /// @return The maximum withdrawable assets.
  function maxWithdraw(address controller) external view returns (uint256);

  /// @notice Submits a deposit request to the vault.
  /// @param assets The amount of assets being requested.
  /// @param controller The controller of the request.
  /// @param owner The owner of the assets being deposited.
  /// @return requestId The request identifier.
  function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256);

  /// @notice Mints shares to receiver by claiming the deposit request of a controller.
  /// @param shares The amount of shares to mint.
  /// @param receiver The address receiving the shares.
  /// @param controller The controller of the request.
  /// @return assets The amount of assets consumed to mint.
  function mint(uint256 shares, address receiver, address controller) external returns (uint256);

  /// @notice Submits a redeem request to the vault.
  /// @param shares The amount of shares being requested to redeem.
  /// @param controller The controller of the request.
  /// @param owner The owner of the shares being redeemed.
  /// @return requestId The request identifier.
  function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);

  /// @notice Withdraws assets to receiver by claiming the redeem request of a controller.
  /// @param assets The amount of assets to withdraw.
  /// @param receiver The address receiving the assets.
  /// @param controller The controller of the request.
  /// @return shares The amount of shares burned.
  function withdraw(uint256 assets, address receiver, address controller) external returns (uint256);

  /// @notice Submits a deposit request cancellation.
  /// @param requestId The request identifier.
  /// @param controller The controller of the request.
  function cancelDepositRequest(uint256 requestId, address controller) external;

  /// @notice Submits a redeem request cancellation.
  /// @param requestId The request identifier.
  /// @param controller The controller of the request.
  function cancelRedeemRequest(uint256 requestId, address controller) external;

  /// @notice Claims cancelled deposit assets for a controller.
  /// @param requestId The request identifier.
  /// @param receiver The address receiving the assets.
  /// @param controller The controller of the request.
  /// @return assets The amount of assets claimed.
  function claimCancelDepositRequest(uint256 requestId, address receiver, address controller) external returns (uint256);

  /// @notice Claims cancelled redeem shares for a controller.
  /// @param requestId The request identifier.
  /// @param receiver The address receiving the shares.
  /// @param controller The controller of the request.
  /// @return shares The amount of shares claimed.
  function claimCancelRedeemRequest(uint256 requestId, address receiver, address controller) external returns (uint256);

  /// @notice Returns the maximum amount of assets that can be deposited for a controller.
  /// @param controller The address of the controller.
  /// @return The maximum depositable assets.
  function maxDeposit(address controller) external view returns (uint256);

  /// @notice Returns the maximum number of shares that can be redeemed for a controller.
  /// @param controller The address of the controller.
  /// @return The maximum redeemable shares.
  function maxRedeem(address controller) external view returns (uint256);

  /// @notice Checks whether a controller is currently permissioned on the vault.
  /// @param controller The controller to check.
  /// @return whether the controller is permissioned.
  function isPermissioned(address controller) external view returns (bool);

  /// @notice Returns the amount of deposit assets currently pending for a controller.
  /// @param requestId The request identifier (pass 0 for the pending request).
  /// @param controller The address of the controller.
  /// @return The total amount of assets still pending for the request.
  function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256);

  /// @notice Returns whether a deposit cancellation is pending for a controller.
  /// @param requestId The request identifier (pass 0 for the pending request).
  /// @param controller The address of the controller.
  /// @return Whether the deposit cancel request is pending.
  function pendingCancelDepositRequest(uint256 requestId, address controller) external view returns (bool);

  /// @notice Returns the claimable amount from a cancelled deposit request.
  /// @param requestId The request identifier (pass 0 for the pending request).
  /// @param controller The address of the controller.
  /// @return The claimable asset amount.
  function claimableCancelDepositRequest(uint256 requestId, address controller) external view returns (uint256);

  /// @notice Returns the amount of redeem shares currently pending for a controller.
  /// @param requestId The request identifier (pass 0 for the pending request).
  /// @param controller The address of the controller.
  /// @return The total amount of shares still pending for the request.
  function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);

  /// @notice Returns whether a redeem cancellation is pending for a controller.
  /// @param requestId The request identifier (pass 0 for the pending request).
  /// @param controller The address of the controller.
  /// @return Whether the redeem cancel request is pending.
  function pendingCancelRedeemRequest(uint256 requestId, address controller) external view returns (bool);

  /// @notice Returns the claimable amount from a cancelled redeem request.
  /// @param requestId The request identifier (pass 0 for the pending request).
  /// @param controller The address of the controller.
  /// @return The claimable share amount.
  function claimableCancelRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
}
