// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @notice Bond configuration for the Midas "Repay-and-Redeem" flow.
/// @param amount Bond size as a fraction of the redeem order input, in basis points (at most
///        MAX_BOND_AMOUNT, 500 bps = 5%); zero means no bond payment is required.
/// @param recipient The Midas-specified wallet receiving the bond in mTokens; must be
///        greenlisted by Midas when the mToken is permissioned.
struct BondConfig {
  uint256 amount;
  address recipient;
}

/// @title IMidasFund
/// @author 3F Protocol
/// @notice Interface for the MidasFund contract that wraps a Midas mToken (e.g. mGLOBAL).
/// @dev Extends IFund with Midas-specific events, administration, and view functions.
interface IMidasFund is IFund {
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
  /// @dev Fires once per commit leg: a bonded redeem commits in two legs (the bond, then the
  ///      remainder) and the emitted amounts sum to the order input.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount committed by this leg.
  /// @param requestId The Midas mint request id (only meaningful for DEPOSIT orders, 0 otherwise).
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount, uint256 requestId);

  /// @notice Emitted when an order is recovered and funds are returned.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount recovered: payment tokens for a DEPOSIT, mTokens re-wrapped
  ///        1:1 into shares for a REDEEM (0 marks the terminal finalization of an aborted
  ///        bonded redeem whose bond stayed forfeited).
  /// @param receiver The address receiving the recovered funds.
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when an order output is unlocked to the receiver.
  /// @dev Fires once per order: unlock() is single-shot and ends the order. A zero amount
  ///      marks the terminal finalization call of a redeem whose settlement proceeds floored
  ///      to zero (no assets are transferred).
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount unlocked by this call.
  /// @param receiver The address receiving the unlocked funds.
  event OrderUnlocked(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when an order is canceled before commitment.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param owner The owner of the canceled order.
  event OrderCanceled(bytes32 indexed orderId, Mode mode, address indexed owner);

  /// @notice Emitted when the internal state is manually set to RECOVERING.
  /// @param orderId The unique identifier of the order being recovered.
  event OrderRecovering(bytes32 indexed orderId);

  /// @notice Emitted when the RECOVERING state is canceled back to PROCESSING.
  /// @param orderId The unique identifier of the order.
  event OrderProcessing(bytes32 indexed orderId);

  /// @notice Emitted when an order is manually resolved by an operator.
  /// @param orderId The unique identifier of the resolved order.
  /// @param newInput The new input amount set by the operator.
  /// @param newOutput The new output amount set by the operator.
  /// @param operator The address that resolved the order.
  event OrderResolved(bytes32 indexed orderId, uint256 newInput, uint256 newOutput, address indexed operator);

  /// @notice Emitted when the bond configuration is updated.
  /// @param amount The new bond amount in basis points of the redeem input.
  /// @param recipient The new bond recipient.
  /// @param operator The address that updated the configuration.
  event BondConfigUpdated(uint256 amount, address indexed recipient, address indexed operator);

  /// @notice Emitted when the bond of a redeem order is paid to the bond recipient.
  /// @param orderId The unique identifier of the order.
  /// @param amount The bond amount paid, in mTokens.
  /// @param recipient The address receiving the bond.
  event BondPaid(bytes32 indexed orderId, uint256 amount, address indexed recipient);

  /// @notice Emitted when the instant redemption of the current bonded redeem order is unlocked.
  /// @param orderId The unique identifier of the order.
  /// @param caller The address that unlocked the instant redemption.
  event InstantRedeemUnlocked(bytes32 indexed orderId, address indexed caller);

  /// @notice Emitted when the deposit vault is updated.
  /// @param depositVault The new deposit vault address.
  /// @param operator The address that updated the vault.
  event DepositVaultUpdated(address indexed depositVault, address indexed operator);

  /// @notice Emitted when the redemption vault is updated.
  /// @dev Also emitted with address(0) when create() drops the previous redemption's vault
  ///      (each redemption settles through a fresh vault); the operator is then the depositor.
  /// @param redemptionVault The new redemption vault address.
  /// @param operator The address that updated the vault.
  event RedemptionVaultUpdated(address indexed redemptionVault, address indexed operator);

  /// @notice Emitted when the Midas referrer id is updated.
  /// @param referrerId The new referrer id.
  /// @param operator The address that updated the referrer id.
  event ReferrerIdUpdated(bytes32 referrerId, address indexed operator);

  /// @notice Emitted when the mToken/USD oracle is updated.
  /// @param newOracle The new AggregatorV3-compatible oracle.
  /// @param operator The account that updated the oracle.
  event OracleUpdated(address indexed newOracle, address indexed operator);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the MidasFund contract with all required parameters.
  /// @dev Callable once. The mToken is derived from the deposit vault; the wrapped share must
  ///      wrap the same mToken. No redemption vault is configured at initialization.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives DEPOSITOR_ROLE).
  /// @param depositVault_ The Midas DepositVault (issuance vault) proxy address.
  /// @param wrappedShare_ The WrappedAsset contract wrapping the mToken.
  /// @param asset_ The payment token used for deposits and redemptions (e.g. USDC).
  /// @param oracle_ The 8-decimal AggregatorV3-compatible mToken/USD oracle.
  function initialize(
    address owner_,
    address depositor_,
    address depositVault_,
    address wrappedShare_,
    address asset_,
    address oracle_
  ) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the fund internal state to RECOVERING (if issues arise with Midas).
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Deposits (must be PROCESSING): flag when Midas is expected to return the committed
  ///      input off-band (e.g. via `withdrawToken`); a settled deposit (mTokens claimable) is
  ///      rejected and completes forward via unlock(). Redeems: only an unsettled bonded
  ///      redeem can be flagged (in the bond phase, or re-ACCEPTED with the bond already
  ///      paid); flagging re-locks the instant redemption so cancelRecovering() lands back in
  ///      the bond phase. Recovery procedure: see docs/funds.md#midas-mtoken.
  /// @param order The order to recover (must match the current order). The full order is
  ///        required so the mode can be checked; id matching still prevents a stale pending
  ///        transaction from targeting a later order.
  function recovering(Order calldata order) external;

  /// @notice Cancels the RECOVERING state, reverting back to PROCESSING.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      A bonded redeem lands back in the bond phase, so unlockInstantRedeem() must be
  ///      called again. Only cancel a redeem recovery while no bond has been returned:
  ///      mTokens already received are not swept by the resumed order's completion (they
  ///      surface as a later deposit's balance sweep); once the refund is in, finalize via
  ///      recover() instead.
  /// @param orderId The order ID that must match the current order in RECOVERING state.
  function cancelRecovering(bytes32 orderId) external;

  /// @notice Resolves the current order by setting its input and output amounts.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner, on a
  ///      PROCESSING or RECOVERING order whose received amounts differ from the expected ones
  ///      (e.g. a partial off-band refund). Does not change the order identity: the original
  ///      order id stays valid and the resolved amounts become the effective thresholds for
  ///      deposit balance comparisons (redeems enforce their minimum output on-chain and
  ///      ignore them). Re-resolvable; the last resolution wins.
  /// @param order The order to resolve (must match current order ID before resolution).
  /// @param input The new input amount.
  /// @param output The new output amount.
  function resolve(Order memory order, uint256 input, uint256 output) external;

  /// @notice Confirms receipt of the bond (or skips the bond leg) and unlocks the instant
  ///         redemption of the current redeem order.
  /// @dev Can only be called by an account with the PAYMENT_ROLE or the owner. Every redeem
  ///      order requires this confirmation before its redeem leg can commit. The current
  ///      order must be bond-locked, in internal state ACCEPTED (skip path: waives the bond
  ///      leg before any commit) or PROCESSING (normal path: after the bond leg). Sets the
  ///      internal state back to ACCEPTED so the depositor can commit the redeem leg.
  /// @param orderId The order ID that must match the current order.
  ///        Required to prevent a stale pending transaction from targeting the wrong order.
  function unlockInstantRedeem(bytes32 orderId) external;

  /// @notice Sets the Midas deposit vault.
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live (internal state EMPTY or ENDED). The new vault must manage
  ///      the same mToken, have the payment token registered, not be paused (globally or for
  ///      the commit-time function this fund calls), and (when its greenlist is enabled) have
  ///      both this fund and the wrapped share greenlisted.
  /// @param depositVault_ The new deposit vault address.
  function setDepositVault(address depositVault_) external;

  /// @notice Sets the Midas redemption vault for the current redemption.
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, at any
  ///      time including while an order is live: the redemption vault carries no per-order
  ///      state (unlike the deposit vault, which tracks the pending mint request), and a live
  ///      redeem still enforces its minimum output on-chain. create() resets the stored vault
  ///      to address(0), so this must be called for every redemption before its redeem leg
  ///      commits. Same vault requirements as setDepositVault().
  /// @param redemptionVault_ The new redemption vault address.
  function setRedemptionVault(address redemptionVault_) external;

  /// @notice Sets the bond configuration for the Repay-and-Redeem flow.
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live (the bond terms are stable for an order's life). Reverts with
  ///      InvalidBondConfig if the amount is zero or greater than MAX_BOND_AMOUNT (5%), or if
  ///      the recipient is the zero address; use removeBondConfig() to disable the bond payment.
  /// @param bondConfig_ The new bond configuration (amount in basis points, recipient).
  function setBondConfig(BondConfig calldata bondConfig_) external;

  /// @notice Removes the bond configuration (no bond payment required).
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live. Subsequent redeem orders still follow the two-leg bond flow,
  ///      but their bond leg moves nothing; the unlockInstantRedeem() confirmation is required
  ///      regardless.
  function removeBondConfig() external;

  /// @notice Sets the Midas referrer id forwarded on deposits.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  /// @param referrerId_ The new referrer id.
  function setReferrerId(bytes32 referrerId_) external;

  /// @notice Sets the mToken/USD oracle.
  /// @dev Can be called by the owner or an account with OPERATOR_ROLE, including while an order
  ///      is live. The oracle must be a contract exposing 8-decimal AggregatorV3 data.
  /// @param oracle_ The new oracle address.
  function setOracle(address oracle_) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Midas DepositVault (issuance vault) address.
  function depositVault() external view returns (address);

  /// @notice The Midas RedemptionVault address of the current redemption.
  /// @dev Reset to address(0) on every create(): each redemption settles through a dedicated
  ///      vault set via setRedemptionVault() while the redeem is live.
  function redemptionVault() external view returns (address);

  /// @notice The mToken wrapped by this fund (e.g. mGLOBAL).
  function mToken() external view returns (address);

  /// @notice The bond configuration for the Repay-and-Redeem flow.
  function bondConfig() external view returns (BondConfig memory);

  /// @notice The bond amount (in mTokens) paid for the current (or most recent) order.
  /// @dev Reset to 0 on every create(); only a redeem's bond leg sets it.
  function bondPaid() external view returns (uint256);

  /// @notice Whether the current order may execute the instant redemption at commit.
  /// @dev True from creation for deposit orders; a redeem always starts locked and becomes
  ///      unlocked via unlockInstantRedeem().
  function instantRedeemUnlocked() external view returns (bool);

  /// @notice The Midas mint request id of the current committed deposit order.
  /// @dev Set when a deposit order is committed via `depositRequest`; reset to 0 on every
  ///      create(), including redeem orders. Only meaningful while the current order is a
  ///      committed deposit.
  function activeRequestId() external view returns (uint256);

  /// @notice The Midas referrer id forwarded on deposits.
  function referrerId() external view returns (bytes32);
}
