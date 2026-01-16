// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

import {Order, Mode} from "../libs/Order.sol";

struct Asset {
  address asset;
  bool isPositionManager;
}

struct Intent {
  Asset depositAsset;
  Asset targetAsset;

  address guardKey;
  address fund;
  address request;

  uint256 depositCap;
  uint40 resolveStart;
  bool resolved;

  // accounting + lifecycle
  EnumerableMapLib.AddressToUint256Map amounts;
  Order order;
  uint256 totalSupply;

  // governance
  uint8 quorum;
}

struct SwapParams {
  uint256 id1;
  address token1;
  uint256 id2;
  address token2;
  uint256 amount1;
  uint256 amount2;
  uint256 deadline;
}

struct CreateIntentParams {
  Asset depositAsset;
  Asset targetAsset;
  address guardKey;
  address fund;
  address request;
  uint256 depositCap;
  uint40 resolveStart;
  uint8 quorum;
}

interface IFacility {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function createIntent(CreateIntentParams calldata params) external returns (uint256 id);

  function updateTarget(uint256 id, Asset calldata newTargetAsset, address newGuardKey) external;

  /// @notice Closes the intent with the given ID, stopping withdrawals.
  function lock(uint256 id) external;

  /// @notice Resolves the intent with the given ID, opening claims to users.
  function resolve(uint256 id) external;

  /// @notice Sets a new deposit cap for a given intent ID.
  function setDepositCap(uint256 id, uint256 newDepositCap) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev We have only one order per intent.
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode) external returns (Order memory order);
  function cancel(uint256 id) external;
  function commit(uint256 id) external;
  function unlock(uint256 id) external;
  function recover(uint256 id) external;

  function swap(SwapParams calldata params, address[] calldata signers, bytes[] calldata signatures) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function pull(uint256 id, uint256 amount) external;
  function repay(uint256 id, uint256 amount) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget) external;

  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount, bool useTarget) external;

  function burnManager(uint256 id, uint256 shares, bool useTarget) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function deposit(uint256 id, uint256 amount) external;
  function withdraw(uint256 id, uint256 amount) external;
  function claim(uint256 id) external;
}
