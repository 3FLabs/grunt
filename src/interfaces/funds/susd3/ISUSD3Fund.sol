// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @title ISUSD3Fund
/// @author 3F Protocol
/// @notice Interface for the SUSD3Fund contract that wraps the sUSD3 (staked USD3) strategy.
/// @dev Extends IFund with sUSD3-specific events, initialization, administration, and view functions.
///      Deposit commits stake synchronously (USDC -> USD3 -> sUSD3), while wrapped-share delivery may
///      wait for the sUSD3 deposit lock. Redemptions (sUSD3 -> USD3 -> USDC) are gated behind the sUSD3
///      cooldown. A pending redeem can be aborted by an operator via `cancelRedeem`, moving it to
///      RECOVERING so `recover()` re-wraps the held sUSD3 back to the receiver.
interface ISUSD3Fund is IFund {
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

  /// @notice Emitted when an order is unlocked and completed (fully or partially).
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

  /// @notice Emitted when a recovering order returns its input to the receiver.
  /// @param orderId The unique identifier of the order.
  /// @param mode The mode of the order (DEPOSIT or REDEEM).
  /// @param amount The amount recovered.
  /// @param receiver The address receiving the recovered funds.
  event OrderRecovered(bytes32 indexed orderId, Mode mode, uint256 amount, address indexed receiver);

  /// @notice Emitted when an operator aborts a pending redeem by cancelling the sUSD3 cooldown.
  /// @param orderId The unique identifier of the order moved to RECOVERING.
  event RedeemCanceled(bytes32 indexed orderId);

  /// @notice Emitted when an operator resolves a stuck order by overriding its output threshold.
  /// @param orderId The unique identifier of the resolved order.
  /// @param input The input amount emitted for off-chain tracking; not stored or used on-chain.
  /// @param output The new output threshold set by the operator.
  /// @param caller The address that resolved the order.
  event OrderResolved(bytes32 indexed orderId, uint256 input, uint256 output, address indexed caller);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the SUSD3Fund contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives DEPOSITOR_ROLE).
  /// @param susd3_ The sUSD3 (staked USD3) strategy address.
  /// @param wrappedShare_ The WrappedAsset address wrapping the sUSD3 share token.
  function initialize(address owner_, address depositor_, address susd3_, address wrappedShare_) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Aborts a pending redeem: cancels the sUSD3 cooldown and moves the order to RECOVERING.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Must be in PROCESSING state for a REDEEM order matching the current order id. After this,
  ///      the depositor calls `recover()` to re-wrap the held sUSD3 back to the receiver.
  /// @param order The redeem order to abort.
  function cancelRedeem(Order calldata order) external;

  /// @notice Resolves the current order by overriding the output threshold used to detect UNLOCKING.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner. Must be in PROCESSING
  ///      state for the current order. Used to unstick a DEPOSIT whose received sUSD3 shares fell short
  ///      of `order.output` (e.g. an adverse rate move between create and commit): the resolved `output`
  ///      becomes the effective threshold that `depositReceived` is compared against. Does not change
  ///      the order identity; can be called multiple times, always overriding the previous resolution.
  /// @param order The order to resolve (must match the current order id).
  /// @param input The new input amount (emitted for off-chain tracking; not stored).
  /// @param output The new output threshold.
  function resolve(Order calldata order, uint256 input, uint256 output) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The sUSD3 (staked USD3) strategy address (the fund's "vault").
  function susd3() external view returns (address);

  /// @notice The USD3 strategy address (the intermediate asset, sUSD3's underlying).
  function usd3() external view returns (address);

  /// @notice Alias of `susd3()` for parity with other fund interfaces.
  function vault() external view returns (address);
}
