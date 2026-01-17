// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Intent, IntentProperties, Asset} from "../libs/facility/LibIntent.sol";
import {Order, Mode, Id} from "../libs/Order.sol";

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

/// @title IFacility
/// @notice Interface for managing intents, funds, requests, and position managers.
interface IFacility {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the intent descriptor is updated.
  /// @param descriptor The new descriptor address.
  event DescriptorSet(address descriptor);

  /// @notice Emitted when a new intent is created.
  /// @param id The intent ID.
  /// @param depositAsset The deposit asset configuration.
  /// @param quorum The quorum threshold for guard approvals.
  event IntentCreated(uint256 indexed id, Asset depositAsset, uint8 quorum);

  /// @notice Emitted when an intent is resolved.
  /// @param id The intent ID.
  event IntentResolved(uint256 indexed id);

  /// @notice Emitted when the resolve start timestamp is updated.
  /// @param id The intent ID.
  /// @param newResolveStart The new resolve start timestamp.
  event ResolveStartUpdated(uint256 indexed id, uint40 newResolveStart);

  /// @notice Emitted when the deposit cap is updated.
  /// @param id The intent ID.
  /// @param newDepositCap The new deposit cap.
  event DepositCapUpdated(uint256 indexed id, uint256 newDepositCap);

  /// @notice Emitted when the intent target is updated.
  /// @param id The intent ID.
  /// @param newTargetAsset The new target asset configuration.
  /// @param newGuardKey The new guard key address.
  event IntentTargetUpdated(uint256 indexed id, Asset newTargetAsset, address newGuardKey);

  /// @notice Emitted when the fund address is updated.
  /// @param id The intent ID.
  /// @param newFund The new fund address.
  event FundUpdated(uint256 indexed id, address newFund);

  /// @notice Emitted when the request address is updated.
  /// @param id The intent ID.
  /// @param newRequest The new request address.
  event RequestUpdated(uint256 indexed id, address newRequest);

  /// @notice Emitted when a fund order is being created.
  /// @param id The intent ID.
  /// @param orderId The order ID.
  event CreatingOrder(uint256 indexed id, Id orderId);

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
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a new intent and returns its ID.
  /// @param params Configuration values for the new intent.
  function createIntent(IntentProperties calldata params) external returns (uint256 id);

  /// @notice Updates the target asset and guard key for an intent.
  /// @param id The intent ID.
  /// @param newTargetAsset The new target asset configuration.
  /// @param newGuardKey The new guard key address.
  function updateTarget(uint256 id, Asset calldata newTargetAsset, address newGuardKey) external;

  /// @notice Closes the intent with the given ID, stopping withdrawals.
  /// @param id The intent ID.
  function lock(uint256 id) external;

  /// @notice Resolves the intent with the given ID, opening claims to users.
  /// @param id The intent ID.
  function resolve(uint256 id) external;

  /// @notice Sets a new deposit cap for a given intent ID.
  /// @param id The intent ID.
  /// @param newDepositCap The new deposit cap value.
  function setDepositCap(uint256 id, uint256 newDepositCap) external;

  /// @notice Sets a new fund address for a given intent ID.
  /// @param id The intent ID.
  /// @param newFund The new fund address.
  function setFund(uint256 id, address newFund) external;

  /// @notice Sets a new request address for a given intent ID.
  /// @param id The intent ID.
  /// @param newRequest The new request address.
  function setRequest(uint256 id, address newRequest) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a fund order for an intent.
  /// @param id The intent ID.
  /// @param amount The amount to include in the order.
  /// @param minAmountOut The minimum amount expected from the order.
  /// @param mode The order mode to execute.
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode) external returns (Order memory order);

  /// @notice Cancels the current fund order for an intent.
  /// @param id The intent ID.
  function cancel(uint256 id) external;

  /// @notice Commits the current fund order for an intent.
  /// @param id The intent ID.
  function commit(uint256 id) external;

  /// @notice Unlocks the current fund order for an intent.
  /// @param id The intent ID.
  function unlock(uint256 id) external;

  /// @notice Recovers assets from the current fund order for an intent.
  /// @param id The intent ID.
  function recover(uint256 id) external;

  /// @notice Executes a swap between intents using signed approvals.
  /// @param params Swap configuration and amounts.
  /// @param signers Addresses that signed the swap.
  /// @param signatures Signatures authorizing the swap.
  function swap(SwapParams calldata params, address[] calldata signers, bytes[] calldata signatures) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pulls assets for the given intent ID.
  /// @param id The intent ID.
  /// @param amount The amount to pull.
  function pull(uint256 id, uint256 amount) external;

  /// @notice Repays assets for the given intent ID.
  /// @param id The intent ID.
  /// @param amount The amount to repay.
  function repay(uint256 id, uint256 amount) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits into the position manager for an intent.
  /// @param id The intent ID.
  /// @param depositAmount The amount to deposit.
  /// @param borrowAmount The amount to borrow.
  /// @param useTarget Whether to use the target asset.
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget) external;

  /// @notice Withdraws from the position manager for an intent.
  /// @param id The intent ID.
  /// @param withdrawAmount The amount to withdraw.
  /// @param repayAmount The amount to repay.
  /// @param useTarget Whether to use the target asset.
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount, bool useTarget) external;

  /// @notice Burns position manager shares for an intent.
  /// @param id The intent ID.
  /// @param shares The number of shares to burn.
  /// @param useTarget Whether to use the target asset.
  function burnManager(uint256 id, uint256 shares, bool useTarget) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits assets into the intent as a liquidity provider.
  /// @param id The intent ID.
  /// @param amount The amount to deposit.
  function deposit(uint256 id, uint256 amount) external;

  /// @notice Withdraws assets from the intent as a liquidity provider.
  /// @param id The intent ID.
  /// @param amount The amount to withdraw.
  function withdraw(uint256 id, uint256 amount) external;

  /// @notice Claims resolved assets for the intent.
  /// @param id The intent ID.
  function claim(uint256 id) external;
}
