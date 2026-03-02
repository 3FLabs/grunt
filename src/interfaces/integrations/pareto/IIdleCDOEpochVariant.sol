// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IIdleCDOEpochVariant
/// @author 3F Protocol
/// @notice Minimal interface for the Pareto (Idle Finance) CDO Epoch Variant contract.
/// @dev Only includes functions called by ParetoFund. The CDO uses epoch-based withdrawals:
///      deposits are synchronous via `depositAA`, while withdrawals require `requestWithdraw`
///      followed by `claimWithdrawRequest` after the epoch ends.
interface IIdleCDOEpochVariant {
  /// @notice Deposits assets into the AA (senior) tranche.
  /// @param amount The amount of underlying tokens to deposit.
  /// @return The amount of AA tranche tokens minted.
  function depositAA(uint256 amount) external returns (uint256);

  /// @notice Requests an epoch-gated withdrawal of tranche tokens.
  /// @param amount The amount of tranche tokens to withdraw.
  /// @param tranche The tranche token address (AA or BB).
  /// @return The epoch number in which the withdrawal was requested.
  function requestWithdraw(uint256 amount, address tranche) external returns (uint256);

  /// @notice Claims a previously requested withdrawal after the epoch has ended.
  function claimWithdrawRequest() external;

  /// @notice Returns the AA (senior) tranche token address.
  function AATranche() external view returns (address);

  /// @notice Returns the underlying token address (e.g., USDC).
  function token() external view returns (address);

  /// @notice Returns the strategy contract address.
  function strategy() external view returns (address);

  /// @notice Returns the virtual price of a tranche token in underlying terms.
  /// @param tranche The tranche token address.
  /// @return The virtual price (18 decimals).
  function virtualPrice(address tranche) external view returns (uint256);

  /// @notice Returns whether an epoch is currently running.
  function isEpochRunning() external view returns (bool);

  /// @notice Returns the end date of the current epoch (0 if no epoch running).
  function epochEndDate() external view returns (uint256);

  /// @notice Checks whether a wallet is allowed to interact with the CDO (Keyring access control).
  /// @param wallet The address to check.
  /// @return Whether the wallet is allowed.
  function isWalletAllowed(address wallet) external view returns (bool);
}
