// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @notice The status of a Midas deposit/redemption request.
/// @dev Mirrors Midas' `RequestStatus` enum (Pending, Processed, Canceled).
enum MidasRequestStatus {
  /// @notice The request is awaiting processing by a Midas vault admin.
  PENDING,
  /// @notice The request has been approved and settled.
  PROCESSED,
  /// @notice The request has been rejected by a Midas vault admin.
  CANCELED
}

/// @title IMidasVault
/// @author 3F Protocol
/// @notice Shared interface of Midas `ManageableVault` (base of both DepositVault and RedemptionVault).
/// @dev All amounts in the Midas vault API are expressed in base-18 decimals, regardless of the
///      payment token's native decimals.
interface IMidasVault {
  /// @notice Returns the mToken managed by the vault (e.g. mGLOBAL).
  function mToken() external view returns (address);

  /// @notice Returns the DataFeed providing the mToken/USD rate for this vault.
  function mTokenDataFeed() external view returns (address);

  /// @notice Returns the configuration of a registered payment token.
  /// @param token The payment token address.
  /// @return dataFeed The token/USD DataFeed (address(0) if the token is not registered).
  /// @return fee The per-token fee in Midas percent units (1% = 100).
  /// @return allowance The remaining base-18 token allowance for operations.
  /// @return stable Whether the token is priced at a constant 1:1 USD rate.
  function tokensConfig(address token)
    external
    view
    returns (address dataFeed, uint256 fee, uint256 allowance, bool stable);

  /// @notice Returns whether the vault is globally paused.
  function paused() external view returns (bool);

  /// @notice Returns whether a specific vault function is paused.
  /// @param fn The function selector.
  function fnPaused(bytes4 fn) external view returns (bool);

  /// @notice Returns whether the vault enforces its greenlist on callers.
  function greenlistEnabled() external view returns (bool);

  /// @notice Returns the access-control role required by the greenlist.
  /// @dev Product-specific vaults override this (e.g. `M_GLOBAL_GREENLISTED_ROLE` for mGLOBAL).
  function greenlistedRole() external view returns (bytes32);

  /// @notice Returns the MidasAccessControl contract holding all Midas roles.
  function accessControl() external view returns (address);

  /// @notice Returns the minimum base-18 mToken amount per operation.
  function minAmount() external view returns (uint256);

  /// @notice Returns the additional fee applied to instant operations (1% = 100).
  function instantFee() external view returns (uint256);

  /// @notice Returns the base-18 mToken daily limit for instant operations.
  function instantDailyLimit() external view returns (uint256);

  /// @notice Returns the address receiving deposited payment tokens.
  function tokensReceiver() external view returns (address);
}
