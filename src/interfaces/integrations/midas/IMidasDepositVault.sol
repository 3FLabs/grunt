// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasVault, MidasRequestStatus} from "./IMidasVault.sol";

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

  /// @notice Transfers `tokenIn` now and requests an mToken mint, settled later by a vault admin.
  /// @dev The mToken is minted directly to the requester when the admin approves the request.
  ///      A rejected request is NOT refunded on-chain (the payment token already left at request time).
  /// @param tokenIn The payment token to deposit.
  /// @param amountToken The base-18 amount of `tokenIn` to deposit (fee inclusive).
  /// @param referrerId The Midas referrer id (bytes32(0) if none).
  /// @return requestId The id of the created mint request.
  function depositRequest(address tokenIn, uint256 amountToken, bytes32 referrerId) external returns (uint256 requestId);

  /// @notice Returns the mint request stored for `requestId`.
  /// @return sender The mToken recipient of the request.
  /// @return tokenIn The payment token deposited.
  /// @return status The request status (PENDING, PROCESSED or CANCELED).
  /// @return depositedUsdAmount The base-18 USD value deposited (fee inclusive).
  /// @return usdAmountWithoutFees The base-18 USD value net of fees.
  /// @return tokenOutRate The base-18 mToken/USD rate snapshotted at request time.
  function mintRequests(uint256 requestId)
    external
    view
    returns (
      address sender,
      address tokenIn,
      MidasRequestStatus status,
      uint256 depositedUsdAmount,
      uint256 usdAmountWithoutFees,
      uint256 tokenOutRate
    );

  /// @notice Returns the extra base-18 mToken floor applied to a user's first deposit.
  function minMTokenAmountForFirstDeposit() external view returns (uint256);

  /// @notice Returns the cumulative base-18 mToken amount minted to `user` through this vault.
  function totalMinted(address user) external view returns (uint256);
}
