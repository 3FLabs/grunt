// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice A batch of queued withdrawals sharing the same expiry timestamp.
/// @param scaledTotalAmount The total scaled amount queued in the batch.
/// @param scaledAmountBurned The scaled amount paid (burned) so far.
/// @param normalizedAmountPaid The normalized (underlying) amount reserved/paid to the batch so far.
struct WithdrawalBatch {
  uint104 scaledTotalAmount;
  uint104 scaledAmountBurned;
  uint128 normalizedAmountPaid;
}

/// @notice Per-account status within a withdrawal batch.
/// @param scaledAmount The account's scaled share of the batch.
/// @param normalizedAmountWithdrawn The normalized amount already claimed by the account.
struct AccountWithdrawalStatus {
  uint104 scaledAmount;
  uint128 normalizedAmountWithdrawn;
}

/// @title IWildcatMarket
/// @author 3F Protocol
/// @notice Minimal interface of a Wildcat V2 market (lender-facing subset).
/// @dev The market itself is a rebasing ERC20 (the "market token"): balances are stored scaled
///      and reported normalized via a monotonically increasing ray-scaled `scaleFactor`.
///      Withdrawals are queued into batches keyed by a uint32 expiry timestamp and paid
///      (possibly partially, pro-rata) from market liquidity once expired.
interface IWildcatMarket {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits exactly `amount` of the underlying asset, minting market tokens 1:1 (normalized).
  /// @dev Reverts if the market is closed, the deposit hook rejects the caller, or the
  ///      market's `maxTotalSupply` cannot absorb the full `amount`.
  /// @param amount The underlying asset amount to deposit.
  function deposit(uint256 amount) external;

  /// @notice Queues a withdrawal of `amount` (normalized) into the current withdrawal batch.
  /// @dev Burns the caller's market tokens into the batch immediately; irreversible.
  /// @param amount The normalized amount to withdraw.
  /// @return expiry The expiry timestamp of the batch the withdrawal was queued into.
  function queueWithdrawal(uint256 amount) external returns (uint32 expiry);

  /// @notice Claims `accountAddress`'s currently available share of an expired withdrawal batch.
  /// @dev Callable by anyone; funds always go to `accountAddress`. Reverts if nothing is claimable.
  /// @param accountAddress The account whose claim is executed.
  /// @param expiry The batch expiry timestamp.
  /// @return normalizedAmountWithdrawn The underlying amount transferred to the account.
  function executeWithdrawal(address accountAddress, uint32 expiry) external returns (uint256 normalizedAmountWithdrawn);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The underlying asset of the market (e.g. USDC).
  function asset() external view returns (address);

  /// @notice Whether the market has been closed by the borrower (terminal wind-down).
  function isClosed() external view returns (bool);

  /// @notice The remaining normalized amount depositable before hitting `maxTotalSupply`.
  function maximumDeposit() external view returns (uint256);

  /// @notice The ray-scaled (1e27) factor converting scaled amounts to normalized amounts.
  function scaleFactor() external view returns (uint256);

  /// @notice The market's withdrawal batch duration in seconds (0 once closed).
  function withdrawalBatchDuration() external view returns (uint256);

  /// @notice Returns the batch state for a given expiry.
  /// @param expiry The batch expiry timestamp.
  function getWithdrawalBatch(uint32 expiry) external view returns (WithdrawalBatch memory);

  /// @notice Returns an account's status within a given batch.
  /// @param accountAddress The account to query.
  /// @param expiry The batch expiry timestamp.
  function getAccountWithdrawalStatus(address accountAddress, uint32 expiry)
    external
    view
    returns (AccountWithdrawalStatus memory);

  /// @notice Returns the normalized amount `accountAddress` can currently claim from a batch.
  /// @dev Reverts with `WithdrawalBatchNotExpired` if `expiry >= block.timestamp`.
  /// @param accountAddress The account to query.
  /// @param expiry The batch expiry timestamp.
  function getAvailableWithdrawalAmount(address accountAddress, uint32 expiry) external view returns (uint256);
}
