// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @title IParetoFund
/// @author 3F Protocol
/// @notice Interface for the ParetoFund contract that wraps the Pareto (Idle Finance) CDO Epoch Variant.
/// @dev Extends IFund with Pareto-specific events, initialization, and view functions.
///      No recovery functions are needed: deposits are atomic (depositAA succeeds or reverts),
///      and withdrawals always complete after the epoch ends (no cancel mechanism in the CDO).
interface IParetoFund is IFund {
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

  /// @notice Emitted when an order is manually resolved by an operator.
  /// @param orderId The unique identifier of the resolved order.
  /// @param input The new input amount set by the operator.
  /// @param output The new output amount set by the operator.
  /// @param caller The address that resolved the order.
  event OrderResolved(bytes32 indexed orderId, uint256 input, uint256 output, address indexed caller);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the ParetoFund contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives DEPOSITOR_ROLE).
  /// @param vault_ The IdleCDOEpochVariant proxy address.
  /// @param wrappedShare_ The WrappedAsset address wrapping the AA tranche token.
  function initialize(address owner_, address depositor_, address vault_, address wrappedShare_) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Resolves the current order by overriding its expected output amount.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner, on an order stuck in
  ///      PROCESSING because received amounts differ from expected ones.
  ///      IMPORTANT: `resolve` must NOT change the current order identity; the original order id
  ///      remains valid for `state`/`unlock`. Only `output` is stored, and only the DEPOSIT path of
  ///      `state()` uses it (as the received-balance threshold); `input` is recorded solely in the
  ///      OrderResolved event. Resolving again overrides the previous resolution.
  /// @param order The order to resolve (must match the current order ID).
  /// @param input The new input amount (recorded in the event only).
  /// @param output The new output amount.
  function resolve(Order memory order, uint256 input, uint256 output) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The IdleCDOEpochVariant proxy address.
  function vault() external view returns (address);
}
