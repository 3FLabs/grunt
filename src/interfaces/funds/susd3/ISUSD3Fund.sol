// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @title ISUSD3Fund
/// @author 3F Protocol
/// @notice Interface for the SUSD3Fund contract that wraps the sUSD3 (staked USD3) strategy.
/// @dev Extends IFund with sUSD3-specific events, initialization, administration, and view functions.
///      Deposits (USDC -> USD3 -> sUSD3) are synchronous; redemptions (sUSD3 -> USD3 -> USDC) are gated
///      behind the sUSD3 cooldown. A pending redeem can be aborted by an operator via `cancelRedeem`,
///      moving it to RECOVERING so `recover()` re-wraps the held sUSD3 back to the receiver.
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
