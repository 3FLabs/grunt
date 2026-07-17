// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {State} from "./Order.sol";

/// @title LibFundsErrors
/// @author 3F Protocol
/// @notice Error definitions for the Funds contracts.
library LibFundsErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      ORDER STATE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the current state does not match the expected one.
  /// @param actual The actual state.
  error InvalidState(State actual);

  /// @notice Thrown when the order Id does not match the current one.
  /// @param orderId The invalid order Id.
  error InvalidOrder(bytes32 orderId);

  /// @notice Thrown when trying to create an order while another is still pending.
  error PendingOrder();

  /// @notice Thrown when a new order's computed ID collides with a previously ended order.
  /// @param orderId The colliding order Id.
  error OrderAlreadyExists(bytes32 orderId);

  /// @notice Thrown when trying to cancel a request while partial fill assets are still claimable.
  error PendingClaimableAssets();

  /// @notice Thrown when the order output does not match the vault's current conversion rate.
  error InvalidOutput();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      AUTHORIZATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the order owner does not match the caller (the owner).
  error InvalidOwner();

  /// @notice Thrown when the order receiver does not match the caller (the owner).
  error InvalidReceiver();

  /// @notice Thrown when the wrapped share's underlying token does not match the expected share token.
  error InvalidUnderlyingAsset();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTEGRATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when address(this) is not allowed by Superstate to deposit in USCC.
  error NotAllowedSuperstate();

  /// @notice Thrown when Superstate accounting is paused (mint/burn disabled).
  error SuperstateAccountingPaused();

  /// @notice Thrown when the fund is not permissioned to operate with the vault.
  error NotAllowedByFund();

  /// @notice Thrown when the vault is running an epoch and `depositDuringEpoch` is disabled upstream,
  ///         so any deposit accepted now would be guaranteed to revert at commit time.
  error DepositDuringEpochDisabled();

  /// @notice Thrown when the vault has AA-tranche withdrawal requests disabled upstream
  ///         (e.g., during an epoch where `startEpoch` flipped `allowAAWithdrawRequest` to false),
  ///         so any redeem accepted now would be guaranteed to revert at commit time.
  error WithdrawRequestDisabled();

  /// @notice Thrown when the wrapped share contract is not permissioned on the vault's share token.
  error WrappedShareNotPermissioned();

  /// @notice Thrown when recover() is called on a fund that does not support recovery.
  error RecoverNotSupported();

  /// @notice Thrown when the CDO routes a withdrawal to the instant path instead of the normal epoch-gated queue.
  error InstantWithdrawDetected();

  /// @notice Thrown when the Midas vault targeted by the order is paused,
  ///         so any order accepted now would be guaranteed to revert at commit time.
  error MidasVaultPaused();

  /// @notice Thrown when the Midas vault function targeted by the order is paused,
  ///         so any order accepted now would be guaranteed to revert at commit time.
  /// @param selector The paused Midas vault function selector.
  error MidasVaultFunctionPaused(bytes4 selector);

  /// @notice Thrown when the payment token is not registered on the Midas vault.
  /// @param token The unsupported token address.
  error TokenNotSupported(address token);

  /// @notice Thrown when setting a bond config with a zero amount, an amount of 100% or more,
  ///         or a zero recipient (removing the bond payment goes through removeBondConfig).
  error InvalidBondConfig();

  /// @notice Thrown when unlocking the instant redemption of an order that is not bond-locked
  ///         (deposit order, already unlocked, or redemption already executed).
  error InstantRedeemAlreadyUnlocked();

  /// @notice Thrown when canceling a redeem order whose bond has already been paid; the order
  ///         can only be completed forward (unlockInstantRedeem, then commit and unlock) or
  ///         aborted via recovering() and recover() (the bond stays forfeited).
  error BondAlreadyPaid();

  /// @notice Thrown when a redemption pays out less than the order's minimum output: the
  ///         redemption vault is not blindly trusted to enforce the min-out it was passed,
  ///         so the received payment-token balance delta is verified fund-side.
  /// @param received The payment token amount actually received.
  /// @param minimum The minimum payment token amount expected.
  error InsufficientRedeemOutput(uint256 received, uint256 minimum);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CHAINLINK ORACLE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the Chainlink oracle returns a non-positive price.
  /// @dev Indicates an invalid or paused oracle feed, or corrupted round data.
  ///      Triggered if `answer <= 0` from `latestRoundData()`.
  error ChainlinkInvalidAnswer();

  /// @notice Thrown when the latest Chainlink round is not yet complete.
  /// @dev Indicates the oracle round has not been finalized.
  ///      Triggered if `updatedAt == 0` from `latestRoundData()`.
  error ChainlinkIncompleteRound();

  /// @notice Thrown when the Chainlink oracle response is stale.
  /// @dev Indicates the answer comes from an earlier round than the latest one.
  ///      Triggered if `answeredInRound < roundId` from `latestRoundData()`.
  error ChainlinkStaleRound();

  /// @notice Thrown when the provided oracle address is invalid (e.g., decimals mismatch).
  /// @param oracle The invalid oracle address.
  error InvalidOracle(address oracle);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    TOKEN VALIDATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when there is a decimals mismatch between two tokens.
  /// @param decimalsA The decimals of the first token.
  /// @param decimalsB The decimals of the second token.
  error DecimalsMismatch(uint256 decimalsA, uint256 decimalsB);
}
