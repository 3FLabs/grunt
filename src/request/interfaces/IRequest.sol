// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Offer} from "../OfferReceiver.sol";

/// @title IRequest
/// @notice Interface for the Request contract that manages funding requests with dual-token (PT/YT) issuance.
interface IRequest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the contract is marked as repaid, enabling withdrawals.
  event Repaid();

  /// @notice Emitted when minting authorization is granted to an address.
  /// @param to The address receiving minting authorization
  /// @param ptAmount The amount of PT tokens authorized to mint
  /// @param ytAmount The amount of YT tokens authorized to mint
  event AuthorizedMinting(address indexed to, uint256 ptAmount, uint256 ytAmount);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Marks the request as repaid, enabling withdrawals and redemptions.
  function setRepaid() external;

  /// @notice Authorizes an address to mint a specific amount of PT and YT tokens.
  /// @param to The address to authorize for minting
  /// @param ptAmount The amount of PT tokens the address can mint
  /// @param ytAmount The amount of YT tokens the address can mint
  function authorizeMinting(address to, uint128 ptAmount, uint128 ytAmount) external;

  /// @notice Transfers underlying assets from the contract to a specified receiver.
  /// @dev This function is used after offers are consumed to transfer the collected funds
  ///      to the borrower. The borrower then repays by transferring assets back to the
  ///      contract before `setRepaid()` is called to enable PT/YT holder withdrawals.
  /// @param receiver The address to receive the transferred assets
  /// @param amount The amount of underlying assets to transfer
  function pullFunds(address receiver, uint256 amount) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          MINTING                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mints PT and YT tokens to the caller using their authorized amounts.
  function mint() external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     OFFER CONSUMPTION                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Consumes a signed offer by minting PT/YT tokens to the offer maker.
  /// @param offer The signed offer struct containing maker, amount, expectedReturn, and other details
  /// @param signature The EIP-712 signature authorizing the offer
  /// @param ptAmount The amount of PT tokens to mint (must be <= offer.amount)
  /// @return ytAmount The amount of YT tokens minted to the offer maker
  function consume(Offer calldata offer, bytes calldata signature, uint256 ptAmount) external returns (uint256 ytAmount);
}

