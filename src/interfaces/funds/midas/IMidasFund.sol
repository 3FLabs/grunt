// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

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
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount committed.
  event OrderCommitted(bytes32 indexed orderId, Mode mode, uint256 amount);

  /// @notice Emitted when an order is recovered and funds are returned.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount recovered.
  /// @param receiver The address receiving the recovered funds.
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when an order is unlocked and completed successfully.
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

  /// @notice Emitted when the holdback payment of the current order is confirmed.
  /// @param orderId The unique identifier of the order.
  /// @param confirmer The address that confirmed the holdback payment.
  event HoldbackConfirmed(bytes32 indexed orderId, address indexed confirmer);

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
  ///      Use this when Midas returns the committed input off-band (e.g. via `withdrawToken`).
  ///      Once set to RECOVERING, the state() function will check if recovery funds (original
  ///      input) have been returned. If yes, it shows RECOVERING. If no, it falls back to
  ///      PROCESSING.
  /// @param orderId The order ID that must match the current order being processed.
  ///        Required to prevent a stale pending transaction from targeting the wrong order if
  ///        the current order completes and a new one enters PROCESSING before it is mined.
  function recovering(bytes32 orderId) external;

  /// @notice Cancels the RECOVERING state, reverting back to PROCESSING.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Use this if recovering() was called by mistake and Midas delivered the output tokens.
  /// @param orderId The order ID that must match the current order in RECOVERING state.
  function cancelRecovering(bytes32 orderId) external;

  /// @notice Resolves the current order by setting its input and output amounts.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      This function is used to resolve stuck orders in PROCESSING or RECOVERING state if
  ///      received amounts differ from expected ones (e.g., a partial off-band refund).
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

  /// @notice Confirms that the holdback payment of the current order has been received.
  /// @dev Can only be called by an account with the HOLDBACK_ROLE or the owner.
  ///      Every order requires this confirmation while PROCESSING: for deposits the remaining
  ///      mTokens airdropped by Midas once the official NAV is published, for redeems the
  ///      holdback amount returned in the payment token. Once confirmed, state() reports
  ///      UNLOCKING (provided the output balance threshold is met) and unlock() sweeps the
  ///      fund's full output-token balance (instant settlement plus holdback) to the receiver.
  /// @param orderId The order ID that must match the current order being processed.
  ///        Required to prevent a stale pending transaction from targeting the wrong order.
  function confirmHoldback(bytes32 orderId) external;

  /// @notice Sets the Midas deposit vault.
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live (internal state EMPTY or ENDED). The new vault must manage the
  ///      same mToken, have the payment token registered, not be paused, and (when its greenlist
  ///      is enabled) have both this fund and the wrapped share greenlisted.
  /// @param depositVault_ The new deposit vault address.
  function setDepositVault(address depositVault_) external;

  /// @notice Sets the Midas redemption vault (e.g. to switch to a dedicated instant-redemption
  ///         vault, or between the Aave and Swapper variants).
  /// @dev Can only be called by an account with the VAULT_MANAGER_ROLE or the owner, and only
  ///      while no order is live (internal state EMPTY or ENDED). The new vault must manage the
  ///      same mToken, have the payment token registered, not be paused, and (when its greenlist
  ///      is enabled) have both this fund and the wrapped share greenlisted.
  /// @param redemptionVault_ The new redemption vault address.
  function setRedemptionVault(address redemptionVault_) external;

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
  /// @dev True while the current order is PROCESSING and has not been confirmed via
  ///      confirmHoldback() yet.
  function holdbackPending() external view returns (bool);

  /// @notice The Midas referrer id forwarded on deposits.
  function referrerId() external view returns (bytes32);
}
