// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @title ICentrifugeFund
/// @author 3F Protocol
/// @notice Interface for the CentrifugeFund contract that wraps Centrifuge ERC-7540 vaults.
/// @dev Extends IFund with Centrifuge-specific events, administration, and view functions.
interface ICentrifugeFund is IFund {
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
  /// @param newOrderId The unique identifier of the new resolved order.
  /// @param newInput The new input amount set by the operator.
  /// @param newOutput The new output amount set by the operator.
  /// @param operator The address that resolved the order.
  event OrderResolved(
    bytes32 indexed orderId, bytes32 indexed newOrderId, uint256 newInput, uint256 newOutput, address indexed operator
  );

  /// @notice Emitted when a cancel request is submitted to the Centrifuge vault.
  /// @param orderId The unique identifier of the order being canceled.
  event CancelOrderSubmitted(bytes32 indexed orderId);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the CentrifugeFund contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives DEPOSITOR_ROLE).
  /// @param vault_ The Centrifuge ERC-7540 vault address.
  /// @param wrappedShare_ The WrappedAsset address wrapping the vault's share token.
  function initialize(address owner_, address depositor_, address vault_, address wrappedShare_) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the fund internal state to RECOVERING.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      This signals that the Centrifuge order needs to be canceled.
  ///      After calling this, the operator should call cancelOrder() to submit
  ///      the cancel request to the vault.
  function recovering() external;

  /// @notice Cancels the RECOVERING state, reverting back to PROCESSING.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Use this if recovering() was called by mistake before cancelOrder() is called.
  function cancelRecovering() external;

  /// @notice Submits a cancel request to the Centrifuge vault.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Must be in RECOVERING state. Calls cancelDepositRequest or cancelRedeemRequest
  ///      on the vault depending on the order mode.
  /// @param order The order to cancel.
  function cancelOrder(Order calldata order) external;

  /// @notice Resolves the current order by setting its input and output amounts.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      This function is used to resolve stuck orders in PROCESSING or RECOVERING state.
  /// @param order The order to resolve (must match current order ID before resolution).
  /// @param input The new input amount.
  /// @param output The new output amount.
  function resolve(Order memory order, uint256 input, uint256 output) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Centrifuge vault address.
  function vault() external view returns (address);
}
