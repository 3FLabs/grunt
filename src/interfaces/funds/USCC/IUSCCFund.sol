// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFund} from "../IFund.sol";
import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @title IUSCCFund
/// @author 3F Protocol
/// @notice Interface for the USCCFund contract that wraps Superstate USCC.
/// @dev Extends IFund with USCC-specific events, administration, and view functions.
interface IUSCCFund is IFund {
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

  /// @notice Emitted when the oracle address is updated.
  /// @param newOracle The new oracle address.
  /// @param operator The address that updated the oracle.
  event OracleUpdated(address indexed newOracle, address indexed operator);

  /// @notice Emitted when an order is manually resolved by an operator.
  /// @param orderId The unique identifier of the resolved order.
  /// @param newInput The new input amount set by the operator.
  /// @param newOutput The new output amount set by the operator.
  /// @param operator The address that resolved the order.
  event OrderResolved(bytes32 indexed orderId, uint256 newInput, uint256 newOutput, address indexed operator);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the USCCFund contract with all required parameters.
  /// @dev Can only be called once due to the `initializer` modifier from Solady's Initializable.
  ///      The owner has admin control, while the depositor can execute orders.
  /// @param owner_ The address that will own this contract and manage roles.
  /// @param depositor_ The address that will execute orders (must be a contract, receives _DEPOSITOR_ROLE).
  /// @param recipient_ The superstate address receiving USDC to mint USCC.
  /// @param oracle_ The address of Chainlink USCC Oracle.
  function initialize(address owner_, address depositor_, address recipient_, address oracle_) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ADMINISTRATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the fund internal state to RECOVERING (if issues arise with Superstate).
  /// @dev Can only be called by an account with the _OPERATOR_ROLE or the owner.
  ///      This is an emergency function to signal that Superstate failed to process the order.
  ///      Once set to RECOVERING, the state() function will check if recovery funds (original input)
  ///      have been returned. If yes, it shows RECOVERING. If no, it falls back to PROCESSING.
  /// @param orderId The order ID that must match the current order being processed.
  ///        Required to prevent a stale pending transaction from targeting the wrong order if
  ///        the current order completes and a new one enters PROCESSING before it is mined.
  function recovering(bytes32 orderId) external;

  /// @notice Cancels the RECOVERING state, reverting back to PROCESSING.
  /// @dev Can only be called by an account with the _OPERATOR_ROLE or the owner.
  ///      Use this if recovering() was called by mistake and Superstate delivered the output tokens.
  ///      Once back to PROCESSING, the state() function will check for output tokens normally.
  /// @param orderId The order ID that must match the current order in RECOVERING state.
  ///        Required to prevent a stale pending transaction from targeting the wrong order if
  ///        the current order completes and a new one enters RECOVERING before it is mined.
  function cancelRecovering(bytes32 orderId) external;

  /// @notice Sets the oracle address.
  /// @dev Can only be called by an account with the _OPERATOR_ROLE or the owner.
  /// @param oracle The new oracle address.
  function setOracle(address oracle) external;

  /// @notice Resolves the current order by setting its input and output amounts.
  /// @dev Can only be called by an account with the _OPERATOR_ROLE or the owner.
  ///      This function is used to resolve stuck orders in PROCESSING or RECOVERING state if received amounts
  ///      differ from expected ones (e.g., due to unexpected conditions).
  ///
  ///      IMPORTANT: `resolve` must NOT change the current order identity. The original order id remains
  ///      valid for `state/unlock/recover`, but the fund will use the resolved `input/output` amounts as
  ///      the effective thresholds for PROCESSING/RECOVERING balance comparisons.
  ///      It's possible to resolve multiple times if needed, always overriding the previous resolution.
  ///
  /// @param order The order to resolve (must match current order ID before resolution).
  /// @param input The new input amount.
  /// @param output The new output amount.
  function resolve(Order memory order, uint256 input, uint256 output) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The USDC token contract address.
  function USDC() external view returns (address);

  /// @notice The USCC token contract address.
  function USCC() external view returns (address);

  /// @notice The wUSCC wrapped token contract address.
  function WUSCC() external view returns (address);
}
