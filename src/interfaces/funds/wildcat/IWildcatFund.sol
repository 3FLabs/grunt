// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @title IWildcatFund
/// @author 3F Protocol
/// @notice Interface for the WildcatFund contract that wraps a Wildcat V2 private-credit market.
/// @dev Extends IFund with Wildcat-specific events, initialization, administration and view functions.
///      Deposits are synchronous (market.deposit then wrap into the official ERC-4626 wrapper);
///      redemptions are queued (withdrawal batches with an expiry, paid pro-rata from market
///      liquidity, potentially across multiple partial payments if the borrower is delinquent).
///      No recovery flow: deposits are atomic and queued withdrawals cannot be canceled upstream.
interface IWildcatFund is IFund {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a new order is created and accepted.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param owner The owner of the order.
  /// @param receiver The receiver of the order output.
  /// @param input The input amount for the order.
  /// @param output The expected output amount for the order.
  event OrderCreated(
    bytes32 indexed orderId, Mode mode, address indexed owner, address indexed receiver, uint256 input, uint256 output
  );

  /// @notice Emitted when an order is committed and assets are transferred.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount committed.
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);

  /// @notice Emitted when an order is unlocked (possibly partially for REDEEM orders).
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount unlocked.
  /// @param receiver The address receiving the unlocked funds.
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when an order is canceled before commitment.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param owner The owner of the canceled order.
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);

  /// @notice Emitted when an order is manually resolved by an operator.
  /// @param orderId The unique identifier of the resolved order.
  /// @param input The new input amount set by the operator.
  /// @param output The new output amount set by the operator.
  /// @param caller The address that resolved the order.
  event OrderResolved(bytes32 indexed orderId, uint256 input, uint256 output, address indexed caller);

  /// @notice Emitted when an order is forcefully ended by an operator.
  /// @param orderId The unique identifier of the ended order.
  /// @param caller The address that force-ended the order.
  event OrderForceEnded(bytes32 indexed orderId, address indexed caller);

  /// @notice Emitted when stray tokens are rescued from the fund.
  /// @param token The rescued token.
  /// @param to The recipient of the rescued tokens.
  /// @param amount The amount rescued.
  event TokensRescued(address indexed token, address indexed to, uint256 amount);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the WildcatFund contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  ///      The market and underlying asset are derived from the wrapper.
  ///      Post-deployment: depending on the market's hooks policy, the fund may need a deposit
  ///      credential granted (e.g. by the borrower) before the first commit can succeed. Markets
  ///      with an open-access pull provider (like wmtUSDC) require no onboarding.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives DEPOSITOR_ROLE).
  /// @param wrapper_ The official Wildcat ERC-4626 wrapper of the target market.
  /// @param wrappedShare_ The WrappedAsset address wrapping the ERC-4626 wrapper shares.
  function initialize(address owner_, address depositor_, address wrapper_, address wrappedShare_) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Resolves the current order by setting its input and output amounts.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      DEPOSIT orders only (reverts ResolveNotSupported for REDEEM orders, whose progression
  ///      is driven purely by the withdrawal batch's expiry and payments). Used to resolve stuck
  ///      DEPOSIT orders in PROCESSING state when the shares received at commit ended up below
  ///      the order's minimum output (e.g. because the market's scaleFactor accrued between
  ///      create and commit).
  ///
  ///      IMPORTANT: `resolve` must NOT change the current order identity. The original order id remains
  ///      valid for `state/unlock`, but the fund will use the resolved `input/output` amounts as
  ///      the effective thresholds for PROCESSING balance comparisons.
  ///      It's possible to resolve multiple times if needed, always overriding the previous resolution.
  ///
  /// @param order The order to resolve (must match current order ID before resolution).
  /// @param input The new input amount.
  /// @param output The new output amount.
  function resolve(Order memory order, uint256 input, uint256 output) external;

  /// @notice Forcefully ends the current PROCESSING REDEEM order.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Escape hatch for REDEEM orders stuck in PROCESSING because their withdrawal batch
  ///      expired unpaid (delinquent borrower) and the depositor must be unblocked.
  ///      Reverts for DEPOSIT orders (atomic; complete them via `resolve()` + `unlock()`),
  ///      while the batch has not expired yet (an unexpired batch always pays at expiry),
  ///      and if the order is currently UNLOCKING (retrievable amounts must be drained via
  ///      `unlock()` first). Any batch payments arriving after a force-end accrue to this
  ///      contract (they are never credited to later orders) and can be retrieved with
  ///      `rescueTokens()`.
  /// @param order The order to force-end (must match current order ID).
  function forceEnd(Order calldata order) external;

  /// @notice Transfers the fund's full balance of `token` to `to`.
  /// @dev Necessary companion to `forceEnd()`. Wildcat withdrawals are uncancelable and a
  ///      force-ended REDEEM's batch claim survives the order: when the borrower later repays,
  ///      anyone can push those proceeds into this contract via the permissionless
  ///      `market.executeWithdrawal(fund, expiry)`. By design they are unreachable through the
  ///      normal path — the order is archived, and `unlock()` credits orders strictly from
  ///      their own batch's counter, so a later order can never sweep them. Without this
  ///      function, late payments of a force-ended order would be permanently locked here.
  ///      Secondary uses: market-token dust from half-up wrap/unwrap rounding, donations.
  ///
  ///      Safety: only callable by the owner, and only while no order is in flight (internal
  ///      state EMPTY or ENDED). The fund holds nothing at rest by construction, and an active
  ///      REDEEM's proceeds are credited via the market's per-batch counter rather than
  ///      balances, so there is no state in which this can touch an in-flight order's funds.
  ///
  ///      Trust note: proceeds of a force-ended order economically belong to that order's
  ///      receiver (the depositor contract). Rescuing them is a governance/ops remediation
  ///      performed outside the depositor's intent accounting — an on-chain auto-forward to
  ///      the receiver was considered and rejected, since an unattributed transfer into the
  ///      depositor bypasses its balance-snapshot accounting just the same and would still
  ///      require manual remediation of the affected intent.
  /// @param token The token to rescue.
  /// @param to The recipient of the rescued tokens.
  function rescueTokens(address token, address to) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Wildcat V2 market address (the rebasing market token).
  function market() external view returns (address);

  /// @notice The official Wildcat ERC-4626 wrapper over the market token.
  function wrapper() external view returns (address);

  /// @notice The withdrawal batch expiry of the current (or most recent) REDEEM order.
  /// @dev Zero when the current order is a DEPOSIT or no withdrawal has been queued yet.
  function currentBatchExpiry() external view returns (uint32);

  /// @notice The ERC-4626 wrapper shares held by the fund for the in-flight DEPOSIT order.
  /// @dev Non-zero only between commit() and unlock() of a DEPOSIT order. These shares are
  ///      not yet reflected in `totalAssets()` (which is derived from the wrapped share
  ///      supply), so off-chain NAV can add this leg for a complete picture.
  function pendingDepositShares() external view returns (uint256);

  /// @notice The estimated underlying value still owed to the in-flight REDEEM order.
  /// @dev Non-zero only between commit() and the final unlock() of a REDEEM order. Sums:
  ///      - proceeds already paid to the batch for this fund but not yet forwarded to the
  ///        receiver (claimable or pushed by third-party `executeWithdrawal` calls), and
  ///      - the fund's pro-rata share of the batch's unpaid remainder, valued at the current
  ///        scaleFactor (queued withdrawals keep accruing interest until paid, so this leg
  ///        grows over time and the final payout may exceed this estimate).
  ///      This value backs the redeeming order (its shares are already burned), so it is
  ///      intentionally excluded from `totalAssets()`. Returns 0 after a forceEnd even if a
  ///      stranded claim remains (retrievable via `rescueTokens()`).
  function pendingRedeemAssets() external view returns (uint256);
}
