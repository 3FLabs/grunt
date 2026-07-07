// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasVault} from "./IMidasVault.sol";

/// @title IMidasDepositVault
/// @author 3F Protocol
/// @notice Interface of the Midas DepositVault (issuance vault) and its variants (e.g. WithAave).
/// @dev All variants share the same external API; they only differ in internal liquidity handling.
///      All amounts are base-18, regardless of `tokenIn` native decimals.
interface IMidasDepositVault is IMidasVault {
  /// @notice Deposits `tokenIn` and mints mToken to the caller in the same transaction.
  /// @param tokenIn The payment token to deposit.
  /// @param amountToken The base-18 amount of `tokenIn` to deposit (fee inclusive).
  /// @param minReceiveAmount The minimum base-18 mToken amount to mint (slippage guard).
  /// @param referrerId The Midas referrer id (bytes32(0) if none).
  function depositInstant(address tokenIn, uint256 amountToken, uint256 minReceiveAmount, bytes32 referrerId) external;

  /// @notice Same as `depositInstant` but mints the mToken to `recipient`.
  function depositInstant(
    address tokenIn,
    uint256 amountToken,
    uint256 minReceiveAmount,
    bytes32 referrerId,
    address recipient
  ) external;

  /// @notice Returns the extra base-18 mToken floor applied to a user's first deposit.
  function minMTokenAmountForFirstDeposit() external view returns (uint256);

  /// @notice Returns the cumulative base-18 mToken amount minted to `user` through this vault.
  function totalMinted(address user) external view returns (uint256);
}
