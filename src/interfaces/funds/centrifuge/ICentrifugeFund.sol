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

  /// @notice Emitted when a cancel request is submitted to the Centrifuge vault.
  /// @param orderId The unique identifier of the order being canceled.
  event CancelRequestSubmitted(bytes32 indexed orderId);

  /// @notice Emitted when an order is force-ended by an operator.
  /// @param orderId The unique identifier of the resolved order.
  /// @param operator The address that resolved the order.
  event OrderForceEnded(bytes32 indexed orderId, address indexed operator);

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

  /// @notice Transitions to RECOVERING and submits a cancel request to the Centrifuge vault.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Must be in PROCESSING state. Reverts with `PendingClaimableAssets` if the vault has
  ///      claimable partial-fill assets (maxMint for deposits, maxWithdraw for redeems) that must
  ///      be drained via `unlock()` first. Sets internal state to RECOVERING, then calls
  ///      cancelDepositRequest or cancelRedeemRequest on the vault depending on the order mode.
  /// @param order The order to cancel.
  function cancelRequest(Order calldata order) external;

  /// @notice Force-ends a stuck order that cannot transition to ENDED naturally.
  /// @dev Can only be called by an account with the OPERATOR_ROLE or the owner.
  ///      Intended for orders stuck in PROCESSING due to griefing (e.g., an attacker
  ///      inflating the vault's pendingDepositRequest via direct requestDeposit calls).
  ///      Must be in PROCESSING or RECOVERING state. Reverts with `PendingClaimableAssets`
  ///      if the vault has claimable fills (maxMint/maxWithdraw) or recoverable cancel assets
  ///      (claimableCancelDepositRequest/claimableCancelRedeemRequest) that must be drained
  ///      via `unlock()` or `recover()` first.
  /// @param order The order to force-end.
  function forceEnd(Order calldata order) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Centrifuge vault address.
  function vault() external view returns (address);
}
