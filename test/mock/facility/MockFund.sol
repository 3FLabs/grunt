// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "src/interfaces/funds/IFund.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title MockFund
/// @notice Mock fund contract for testing Facility fund operations
/// @dev Allows setting states and simulating fund order lifecycle
contract MockFund is IFund {
  using SafeTransferLib for address;

  address public asset_;
  address public share_;

  mapping(bytes32 => State) public orderStates;
  mapping(bytes32 => Order) public orders;

  // Controllable state for testing
  State public nextCreateState = State.ACCEPTED;
  State public nextCommitState = State.PROCESSING;
  State public nextUnlockState = State.ENDED;
  State public nextRecoverState = State.ENDED;

  uint256 public commitAmount;
  uint256 public unlockAmount;
  uint256 public recoverAmount;

  bool public shouldRevert;
  string public revertMessage;

  constructor(address asset__, address share__) {
    asset_ = asset__;
    share_ = share__;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setNextCreateState(State state_) external {
    nextCreateState = state_;
  }

  function setNextCommitState(State state_) external {
    nextCommitState = state_;
  }

  function setNextUnlockState(State state_) external {
    nextUnlockState = state_;
  }

  function setNextRecoverState(State state_) external {
    nextRecoverState = state_;
  }

  function setCommitAmount(uint256 amount) external {
    commitAmount = amount;
  }

  function setUnlockAmount(uint256 amount) external {
    unlockAmount = amount;
  }

  function setRecoverAmount(uint256 amount) external {
    recoverAmount = amount;
  }

  function setOrderState(bytes32 orderId, State state_) external {
    orderStates[orderId] = state_;
  }

  function setShouldRevert(bool should, string memory message) external {
    shouldRevert = should;
    revertMessage = message;
  }

  function getOrderId(Order calldata order) public view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, address(this), order));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      IFund OPERATIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function create(Order calldata order) external override returns (State) {
    if (shouldRevert) revert(revertMessage);

    bytes32 orderId = getOrderId(order);
    orders[orderId] = order;
    orderStates[orderId] = nextCreateState;
    return nextCreateState;
  }

  function cancel(Order calldata order) external override returns (State) {
    if (shouldRevert) revert(revertMessage);

    bytes32 orderId = getOrderId(order);
    orderStates[orderId] = State.EMPTY;
    delete orders[orderId];
    return State.EMPTY;
  }

  function commit(Order calldata order) external override returns (State, uint256) {
    if (shouldRevert) revert(revertMessage);

    bytes32 orderId = getOrderId(order);

    // Pull tokens from caller
    address inputToken = order.mode == Mode.DEPOSIT ? asset_ : share_;
    uint256 amount = commitAmount > 0 ? commitAmount : order.input;
    inputToken.safeTransferFrom(msg.sender, address(this), amount);

    orderStates[orderId] = nextCommitState;
    return (nextCommitState, amount);
  }

  function unlock(Order calldata order) external override returns (State, uint256) {
    if (shouldRevert) revert(revertMessage);

    bytes32 orderId = getOrderId(order);

    // Transfer output tokens to receiver
    address outputToken = order.mode == Mode.DEPOSIT ? share_ : asset_;
    uint256 amount = unlockAmount > 0 ? unlockAmount : order.output;

    if (amount > 0) {
      outputToken.safeTransfer(order.receiver, amount);
    }

    orderStates[orderId] = nextUnlockState;
    return (nextUnlockState, amount);
  }

  function recover(Order calldata order) external override returns (State, uint256) {
    if (shouldRevert) revert(revertMessage);

    bytes32 orderId = getOrderId(order);

    // Return input tokens to receiver
    address inputToken = order.mode == Mode.DEPOSIT ? asset_ : share_;
    uint256 amount = recoverAmount > 0 ? recoverAmount : order.input;

    if (amount > 0) {
      inputToken.safeTransfer(order.receiver, amount);
    }

    orderStates[orderId] = nextRecoverState;
    return (nextRecoverState, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        IFund VIEWS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function state(Order calldata order) external view override returns (State) {
    bytes32 orderId = getOrderId(order);
    return orderStates[orderId];
  }

  function asset() external view override returns (address) {
    return asset_;
  }

  function share() external view override returns (address) {
    return share_;
  }

  function totalAssets() external view override returns (uint256) {
    return asset_.balanceOf(address(this));
  }

  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  function maxRedeem(address) external pure override returns (uint256) {
    return type(uint256).max;
  }
}
