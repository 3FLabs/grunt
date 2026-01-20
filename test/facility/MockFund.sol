// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFund} from "src/interfaces/funds/IFund.sol";
import {Order, Mode, State} from "src/libs/Order.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @dev Minimal deterministic IFund mock for Facility tests.
contract MockFund is IFund {
  using SafeTransferLib for address;

  address public immutable ASSET;
  address public immutable SHARE;

  bytes32 public currentOrderId;
  State public internalState;

  uint256 public remainingOutput;
  uint256 public remainingRecover;

  bool public recoveringMode;

  int256 public committedDelta;

  bool public didPartialUnlock;
  bool public didPartialRecover;

  constructor(address asset_, address share_) {
    ASSET = asset_;
    SHARE = share_;
    internalState = State.EMPTY;
  }

  function asset() external view returns (address) {
    return ASSET;
  }

  function share() external view returns (address) {
    return SHARE;
  }

  function totalAssets() external pure returns (uint256) {
    return 0;
  }

  function maxDeposit(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function maxRedeem(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function _id(Order calldata order) internal view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, address(this), order));
  }

  function setRecoveringMode(bool value) external {
    recoveringMode = value;
  }

  function setCommittedDelta(int256 delta) external {
    committedDelta = delta;
  }

  function state(Order calldata order) external view returns (State) {
    bytes32 id = _id(order);
    if (id != currentOrderId) return State.EMPTY;

    if (internalState == State.PROCESSING) {
      if (recoveringMode && remainingRecover > 0) return State.RECOVERING;
      if (!recoveringMode && remainingOutput > 0) return State.UNLOCKING;
    }

    return internalState;
  }

  function create(Order calldata order) external returns (State) {
    require(internalState == State.EMPTY || internalState == State.ENDED, "bad state");

    currentOrderId = _id(order);
    internalState = State.ACCEPTED;

    remainingOutput = order.output;
    remainingRecover = order.input;
    recoveringMode = false;

    didPartialUnlock = false;
    didPartialRecover = false;

    return State.ACCEPTED;
  }

  function cancel(Order calldata order) external returns (State) {
    require(_id(order) == currentOrderId, "bad order");
    require(internalState == State.ACCEPTED || internalState == State.PENDING, "bad state");

    currentOrderId = bytes32(0);
    internalState = State.EMPTY;
    remainingOutput = 0;
    remainingRecover = 0;
    recoveringMode = false;

    didPartialUnlock = false;
    didPartialRecover = false;

    return State.EMPTY;
  }

  function commit(Order calldata order) external returns (State, uint256) {
    require(_id(order) == currentOrderId, "bad order");
    require(internalState == State.ACCEPTED, "bad state");

    address tokenIn = order.mode == Mode.DEPOSIT ? ASSET : SHARE;
    tokenIn.safeTransferFrom(msg.sender, address(this), order.input);

    internalState = State.PROCESSING;
    uint256 committedAmount = order.input;
    if (committedDelta != 0) {
      committedAmount = SafeCastLib.toUint256(SafeCastLib.toInt256(order.input) + committedDelta);
    }
    return (State.PROCESSING, committedAmount);
  }

  function unlock(Order calldata order) external returns (State, uint256) {
    require(_id(order) == currentOrderId, "bad order");
    require(internalState == State.PROCESSING && !recoveringMode && remainingOutput > 0, "bad state");

    address tokenOut = order.mode == Mode.DEPOSIT ? SHARE : ASSET;

    uint256 out;
    if (!didPartialUnlock) {
      out = remainingOutput / 2;
      if (out == 0) out = remainingOutput;
      didPartialUnlock = true;
    } else {
      out = remainingOutput;
    }

    remainingOutput -= out;
    tokenOut.safeTransfer(msg.sender, out);

    if (remainingOutput == 0) {
      didPartialUnlock = false;
      internalState = State.ENDED;
      return (State.ENDED, out);
    }

    internalState = State.PROCESSING;
    return (State.PROCESSING, out);
  }

  function recover(Order calldata order) external returns (State, uint256) {
    require(_id(order) == currentOrderId, "bad order");
    require(internalState == State.PROCESSING && recoveringMode && remainingRecover > 0, "bad state");

    address tokenIn = order.mode == Mode.DEPOSIT ? ASSET : SHARE;

    uint256 recovered;
    if (!didPartialRecover) {
      recovered = remainingRecover / 2;
      if (recovered == 0) recovered = remainingRecover;
      didPartialRecover = true;
    } else {
      recovered = remainingRecover;
    }

    remainingRecover -= recovered;
    tokenIn.safeTransfer(msg.sender, recovered);

    if (remainingRecover == 0) {
      didPartialRecover = false;
      internalState = State.ENDED;
      recoveringMode = false;
      return (State.ENDED, recovered);
    }

    internalState = State.PROCESSING;
    return (State.PROCESSING, recovered);
  }
}
