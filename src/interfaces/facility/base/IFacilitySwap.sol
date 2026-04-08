// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @dev Parameters describing a two-asset swap between intents.
/// @param id1 First intent ID.
/// @param token1 First token address.
/// @param id2 Second intent ID.
/// @param token2 Second token address.
/// @param amount1 Amount of the first token.
/// @param amount2 Amount of the second token.
/// @param deadline Timestamp after which the swap is no longer valid.
struct SwapParams {
  uint256 id1;
  address token1;
  uint256 id2;
  address token2;
  uint256 amount1;
  uint256 amount2;
  uint256 deadline;
}

/// @title IFacilitySwap
/// @author 3F Protocol
/// @notice Interface for swap operations between intents.
interface IFacilitySwap {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a swap is executed between two intents.
  /// @param id1 The first intent ID.
  /// @param id2 The second intent ID.
  /// @param token1 The token sent from the first intent to the second.
  /// @param amount1 The amount of the token sent from the first intent to the second.
  /// @param token2 The token sent from the second intent to the first.
  /// @param amount2 The amount of the token sent from the second intent to the first.
  event Swap(
    uint256 indexed id1, uint256 indexed id2, address token1, uint256 amount1, address token2, uint256 amount2
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           SWAP                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Executes a swap between intents using signed approvals.
  /// @dev The EIP-712 digest is computed from `SwapParams` only and does not include the signer
  ///      address. Smart contract wallet guardians must use implementations that bind their own
  ///      address into EIP-1271 `isValidSignature` (e.g., Safe >= 1.3.0). Older SC wallets with
  ///      faulty EIP-1271 fallbacks must not be used as quorum signers. See {FacilitySwap} for
  ///      full details.
  /// @param params Swap configuration and amounts.
  /// @param signers Addresses that signed the swap.
  /// @param signatures Signatures authorizing the swap.
  function swap(SwapParams calldata params, address[] calldata signers, bytes[] calldata signatures) external;
}
