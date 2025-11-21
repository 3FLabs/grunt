// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IRequest
/// @notice Interface for handling token consumption, repayment, and validation logic in a request system.
/// @dev This is the interface expected to intereact with the position manager to:
/// - Account for remaining debt
/// - Consume and repay the request token
/// - Validate the request token and the consumer address
interface IRequest {
  /**
   * @notice Consumes a specified amount of the request token and sends it to the given receiver address.
   * @dev After a repayment has been initiated, no further consumption can take place.
   * Requirements and expected state transitions are implementation-specific.
   * @dev The amount of consumed tokens should not be greater than the principal assets amount.
   * @param amount The amount of the request token to consume.
   * @param receiver The address that will receive the consumed tokens.
   */
  function consume(uint256 amount, address receiver) external;

  /**
   * @notice Repays a specified amount of the request token.
   * @dev This operation records repayment against the outstanding balance.
   * After any call to {repay}, no further consumption is allowed.
   * Only callable if full repayment has not yet been validated.
   * It should pull from the caller's balance.
   * @param amount The amount of the request token to repay.
   */
  function repay(uint256 amount) external;

  /**
   * @notice Validates and finalizes the state that the full repayment of the request token has been made.
   * @dev This function locks the contract against further repayments or consumptions,
   * and may enable a new phase in the workflow. Only callable if the amount repaid
   * matches the total amount required.
   */
  function validateFullRepayment() external;

  /**
   * @notice Returns the total amount of principal tokens that have been consumed.
   * @return The total amount of principal tokens that have been consumed.
   */
  function principalSupply() external view returns (uint256);

  /**
   * @notice Returns the total amount of principal assets that have been repaid.
   * @return The total amount of principal assets that have been repaid.
   */
  function principalAssets() external view returns (uint256);

  /**
   * @notice Returns the total amount of yield tokens that have been consumed.
   * @return The total amount of yield tokens that have been consumed.
   */
  function yieldSupply() external view returns (uint256);

  /**
   * @notice Returns the total amount of yield assets that have been repaid.
   * @return The total amount of yield assets that have been repaid.
   */
  function yieldAssets() external view returns (uint256);

  /**
   * @notice Returns the address of the ERC-20 token underlying this request.
   * @dev The returned address should reference the token contract used for consumption and repayment.
   * @return token The address of the request token used by this contract.
   */
  function token() external view returns (address token);

  /**
   * @notice Returns the address of the consumer of this request.
   * @return consumer The address of the consumer of this request.
   */
  function consumer() external view returns (address consumer);
}
