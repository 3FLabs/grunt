// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {IFund} from "../interfaces/funds/IFund.sol";
import {Order, State} from "../libs/Order.sol";

contract USCCFund is IFund {
  /// @inheritdoc IFund
  function create(Order calldata) external pure override returns (State) {
    // validate inputs.
    // No pending state, always accepted or revert.
    return State.ACCEPTED;
  }

  /// @inheritdoc IFund
  function commit(Order calldata) external pure override returns (State, uint256) {
    // order must be accepted
    // transferFrom caller to superstate fund
    return (State.UNLOCKING, 0);
  }

  /// @inheritdoc IFund
  function recover(Order calldata) external pure override returns (State, uint256) {
    return (State.ENDED, 0);
  }

  /// @inheritdoc IFund
  function unlock(Order calldata) external pure override returns (State, uint256) {
    return (State.ENDED, 0);
  }

  /// @inheritdoc IFund
  function estimate(Order calldata) external pure override returns (uint256) {
    return 0;
  }

  /// @inheritdoc IFund
  function asset() external pure override returns (address) {
    return address(0);
  }

  /// @inheritdoc IFund
  function totalAssets() external pure override returns (uint256) {
    return 0;
  }

  /// @inheritdoc IFund
  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritdoc IFund
  function maxRedeem(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritdoc IFund
  function state(Order calldata) external pure override returns (State) {
    return State.ENDED;
  }
}
