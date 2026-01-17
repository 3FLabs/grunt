// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Offer} from "./IOfferReceiver.sol";
import {IRequestInteractions} from "./IRequestInteractions.sol";

/// @title IRequest
/// @notice Interface for the Request contract that manages funding requests with dual-token (PT/YT) issuance.
/// @dev This interface focuses on the operational aspects of requests (minting, consuming offers).
///      The implementation contract should also inherit IVaultController for PT/YT redemption functionality.
interface IRequest is IRequestInteractions {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the contract is marked as repaid, enabling withdrawals.
  /// @param amount The total amount of underlying assets available for redemption
  event Repaid(uint256 amount);

  /// @notice Emitted when funds are pulled from the contract.
  /// @param puller The address that pulled the funds
  /// @param amount The amount of underlying assets pulled
  event FundsPulled(address indexed puller, uint256 amount);

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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          MINTING                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the mint authorization for a given address.
  /// @param account The address to query mint authorization for
  /// @return ptAmount The amount of PT tokens the address is authorized to mint
  /// @return ytAmount The amount of YT tokens the address is authorized to mint
  function mintAuthorization(address account) external view returns (uint128 ptAmount, uint128 ytAmount);

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

