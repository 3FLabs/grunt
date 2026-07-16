// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @notice Bond configuration for the Midas "Repay-and-Redeem" flow.
/// @param amount Bond size as a fraction of the redeem order input, in basis points (must be
///        less than BPS). Zero disables the bond flow: redeems commit in a single leg.
/// @param recipient The Midas-specified wallet receiving the bond in mTokens. Must be non-zero
///        when amount is positive, and must be greenlisted by Midas when the mToken is
///        permissioned (e.g. mGLOBAL gates every transfer on both parties).
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
  /// @param amount The amount recovered.
  /// @param receiver The address receiving the recovered funds.
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when an order output is unlocked to the receiver.
  /// @dev Fires once per unlock() call: a redeem order with a pending holdback can be swept
  ///      partially several times, each sweep emitting this event with the per-call amount.
  ///      A zero amount marks the terminal finalization call of a redeem whose balance was
  ///      already fully swept before the holdback confirmation (no assets are transferred).
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

  /// @notice Emitted when the holdback payment of the current redeem order is confirmed.
  /// @param orderId The unique identifier of the order.
  /// @param confirmer The address that confirmed the holdback payment.
  event HoldbackConfirmed(bytes32 indexed orderId, address indexed confirmer);

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
  /// @param redemptionVault The new redemption vault address.
  /// @param operator The address that updated the vault.
  event RedemptionVaultUpdated(address indexed redemptionVault, address indexed operator);

  /// @notice Emitted when the Midas referrer id is updated.
  /// @param referrerId The new referrer id.
  /// @param operator The address that updated the referrer id.
  event ReferrerIdUpdated(bytes32 referrerId, address indexed operator);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the MidasFund contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The mToken is derived from the deposit vault; the redemption vault and the wrapped
  ///      share must reference the same mToken.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives DEPOSITOR_ROLE).
  /// @param depositVault_ The Midas DepositVault (issuance vault) proxy address.
  /// @param redemptionVault_ The Midas RedemptionVault proxy address.
  /// @param wrappedShare_ The WrappedAsset contract wrapping the mToken.
  /// @param asset_ The payment token used for deposits and redemptions (e.g. USDC).
  function initialize(
    address owner_,
    address depositor_,
    address depositVault_,
    address redemptionVault_,
    address wrappedShare_,
    address asset_
  ) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the fund internal state to RECOVERING (if issues arise with Midas).
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      - Deposit orders (must be PROCESSING): use this when Midas returns the committed
  ///        input off-band (e.g. via `withdrawToken`). Once set to RECOVERING, the state()
  ///        function will check if recovery funds (original input) have been returned. If
  ///        yes, it shows RECOVERING. If no, it falls back to PROCESSING.
  ///      - Redeem orders: only an UNSETTLED bonded redeem can be flagged — in the bond
  ///        phase (bond leg committed, instant redemption locked), or re-ACCEPTED after
  ///        unlockInstantRedeem() with the bond already paid. This is the abort path for a
  ///        permanently stuck bonded redeem: the bond stays forfeited, the remainder shares
  ///        never left the depositor, and recover() ends the order sweeping any off-band
  ///        refund (possibly zero). Flagging re-locks the instant redemption so that
  ///        cancelRecovering() always lands back in the bond phase.
  ///        Reverts with RecoverNotSupported for a settled redeem (`redeemInstant` executed
  ///        — the payout must complete forward via unlock() and confirmHoldback()) and for
  ///        an uncommitted redeem with no bond paid (cancel() is the tool there).
  /// @param order The order to recover (must match the current order being processed).
  ///        The full order is required (rather than just its id) so the mode can be checked;
  ///        matching on the derived order ID still prevents a stale pending transaction from
  ///        targeting the wrong order if the current order completes and a new one enters
  ///        PROCESSING before it is mined.
  function recovering(Order calldata order) external;

  /// @notice Cancels the RECOVERING state, reverting back to PROCESSING.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Use this if recovering() was called by mistake and Midas delivered the output tokens.
  ///      For a bonded redeem the order lands back in the bond phase (recovering() re-locked
  ///      the instant redemption), so unlockInstantRedeem() must be called again before the
  ///      redeem leg can be committed.
  /// @param orderId The order ID that must match the current order in RECOVERING state.
  function cancelRecovering(bytes32 orderId) external;

  /// @notice Resolves the current order by setting its input and output amounts.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      This function is used to resolve stuck orders in PROCESSING or RECOVERING state if
  ///      received amounts differ from expected ones (e.g., a partial off-band refund).
  ///      Resolved amounts only affect deposit orders (mint-output and refund thresholds);
  ///      redeem orders are partial-claimable on any positive balance, so their state ignores
  ///      the resolved amounts.
  ///
  ///      IMPORTANT: `resolve` must NOT change the current order identity. The original order id
  ///      remains valid for `state/unlock/recover`, but the fund will use the resolved
  ///      `input/output` amounts as the effective thresholds for PROCESSING/RECOVERING balance
  ///      comparisons. It's possible to resolve multiple times if needed, always overriding the
  ///      previous resolution.
  ///
  /// @param order The order to resolve (must match current order ID before resolution).
  /// @param input The new input amount.
  /// @param output The new output amount.
  function resolve(Order memory order, uint256 input, uint256 output) external;

  /// @notice Confirms that the holdback payment of the current redeem order has been received.
  /// @dev Can only be called by an account with the PAYMENT_ROLE or the owner.
  ///      Every redeem order requires this confirmation while PROCESSING: Midas withholds part
  ///      of the instant redemption and returns it off-band in the payment token. Confirmation
  ///      only flips the holdback flag — it never changes the lifecycle state and does not
  ///      gate claiming (any positive balance is claimable via unlock() before it, partially).
  ///      Once confirmed, state() reports UNLOCKING even at zero balance and the next unlock()
  ///      is terminal: it sweeps whatever remains (possibly nothing) and ends the order, so
  ///      unlock() stays the only successful-completion transition to ENDED.
  ///      Deposit orders settle without a holdback (they are marked paid at creation), so
  ///      calling this for a deposit order reverts with HoldbackNotPending. It also reverts
  ///      with HoldbackNotPending during the bond phase of a bonded redeem: the redemption has
  ///      not executed yet, so no holdback exists.
  ///      Committed redeems cannot be recovered (the instant settlement is irreversible), so
  ///      confirming without an actual holdback payment is the official write-off procedure:
  ///      it deliberately completes the order with the instant settlement only.
  /// @param orderId The order ID that must match the current order being processed.
  ///        Required to prevent a stale pending transaction from targeting the wrong order.
  function confirmHoldback(bytes32 orderId) external;

  /// @notice Confirms receipt of the bond (or waives it) and unlocks the instant redemption of
  ///         the current bonded redeem order.
  /// @dev Can only be called by an account with the PAYMENT_ROLE or the owner.
  ///      Requires the current order to be bond-locked — reverts with
  ///      InstantRedeemAlreadyUnlocked for deposit orders, zero-bond redeems, double calls, or
  ///      once the redemption has executed — and its internal state to be either ACCEPTED
  ///      (skip-bond path: unlocking before any commit waives the bond for this order) or
  ///      PROCESSING (normal path: after the bond leg of commit()). Sets the internal state
  ///      back to ACCEPTED so the depositor can commit the redeem leg.
  ///      Once the bond has been paid, cancel() reverts with BondAlreadyPaid: the order
  ///      either completes forward, or — while the redemption has not executed — is aborted
  ///      via recovering() + recover() (the bond stays forfeited).
  /// @param orderId The order ID that must match the current order.
  ///        Required to prevent a stale pending transaction from targeting the wrong order.
  function unlockInstantRedeem(bytes32 orderId) external;

  /// @notice Sets the Midas deposit vault.
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live (internal state EMPTY or ENDED). The new vault must manage the
  ///      same mToken, have the payment token registered, not be paused (globally or for the
  ///      commit-time function this fund calls), and (when its greenlist
  ///      is enabled) have both this fund and the wrapped share greenlisted.
  /// @param depositVault_ The new deposit vault address.
  function setDepositVault(address depositVault_) external;

  /// @notice Sets the Midas redemption vault (e.g. to switch to a dedicated instant-redemption
  ///         vault, or between the Aave and Swapper variants).
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner. Callable at
  ///      any time, including while an order is live: the redemption vault carries no per-order
  ///      state (unlike the deposit vault, which tracks the pending mint request), and a live
  ///      redeem settles through the vault configured when its redeem leg commits, with the
  ///      order's minimum output still enforced on-chain. In particular this is how the
  ///      dedicated Repay-and-Redeem vault — deployed by Midas only once the bond is received —
  ///      is configured while the bonded redeem is live. The new vault must manage the
  ///      same mToken, have the payment token registered, not be paused (globally or for the
  ///      commit-time function this fund calls), and (when its greenlist
  ///      is enabled) have both this fund and the wrapped share greenlisted.
  /// @param redemptionVault_ The new redemption vault address.
  function setRedemptionVault(address redemptionVault_) external;

  /// @notice Sets the bond configuration for the Repay-and-Redeem flow (enables the bond).
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live (internal state EMPTY or ENDED), so the bond lock snapshot
  ///      taken at create() is stable for the order's life.
  ///      Reverts with InvalidBondConfig if the amount is zero or BPS (100%) or more, or if
  ///      the recipient is the zero address. Use removeBondConfig() to disable the bond flow.
  ///      OPERATIONS: the recipient must be greenlisted by Midas when the mToken is
  ///      permissioned (e.g. mGLOBAL gates every transfer), otherwise the bond leg reverts.
  /// @param bondConfig_ The new bond configuration (amount in basis points, recipient).
  function setBondConfig(BondConfig calldata bondConfig_) external;

  /// @notice Removes the bond configuration, disabling the Repay-and-Redeem flow.
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live (internal state EMPTY or ENDED). Subsequent redeem orders
  ///      commit in a single leg again (instant redemption unlocked from creation).
  ///      Idempotent: removing an already-zero config succeeds. Emits BondConfigUpdated with
  ///      a zero amount and recipient.
  function removeBondConfig() external;

  /// @notice Sets the Midas referrer id forwarded on deposits.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  /// @param referrerId_ The new referrer id.
  function setReferrerId(bytes32 referrerId_) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Midas DepositVault (issuance vault) address.
  function depositVault() external view returns (address);

  /// @notice The Midas RedemptionVault address.
  function redemptionVault() external view returns (address);

  /// @notice The mToken wrapped by this fund (e.g. mGLOBAL).
  function mToken() external view returns (address);

  /// @notice Whether the current order is awaiting a holdback confirmation.
  /// @dev True while the current redeem order's internal state is PROCESSING, its redemption
  ///      has executed, and it has not been confirmed via confirmHoldback() yet; stays true
  ///      across partial unlocks, even while the public state() reports UNLOCKING (a positive
  ///      claimable balance). Always false for deposit orders (no holdback) and during the
  ///      bond phase of a bonded redeem (no holdback exists before the redemption executes).
  function holdbackPending() external view returns (bool);

  /// @notice The bond configuration for the Repay-and-Redeem flow.
  function bondConfig() external view returns (BondConfig memory);

  /// @notice The bond amount (in mTokens) paid for the current (or most recent) order.
  /// @dev Reset to 0 on every create(); only a bonded redeem's bond leg sets it.
  function bondPaid() external view returns (uint256);

  /// @notice Whether the current order may execute the instant redemption at commit.
  /// @dev True from creation for deposit orders and zero-bond redeems; a bonded redeem starts
  ///      locked and becomes unlocked via unlockInstantRedeem().
  function instantRedeemUnlocked() external view returns (bool);

  /// @notice The Midas mint request id of the current committed deposit order.
  /// @dev Set when a deposit order is committed via `depositRequest`; reset to 0 on every
  ///      create(), including redeem orders. Only meaningful while the current order is a
  ///      committed deposit.
  function activeRequestId() external view returns (uint256);

  /// @notice The Midas referrer id forwarded on deposits.
  function referrerId() external view returns (bytes32);
}
