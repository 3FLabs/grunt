// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {IFund, State, Request} from "../interfaces/funds/IFund.sol";

contract USCCFund is IFund {
  /// @inheritDoc IFund
  function create(Request calldata) external pure override returns (State) {
    // validate inputs.
    // No pending state, always accepted or revert.
    return State.ACCEPTED;
  }

  /// @inheritDoc IFund
  function commit(Request calldata) external pure override returns (State, uint256) {
    // request must be accepted
    // transferFrom caller to superstate fund
    return (State.UNLOCKING, 0);
  }

  /// @inheritDoc IFund
  function recover(Request calldata) external pure override returns (State, uint256) {
    return (State.ENDED, 0);
  }

  /// @inheritDoc IFund
  function unlock(Request calldata) external pure override returns (State, uint256) {
    return (State.ENDED, 0);
  }

  /// @inheritDoc IFund
  function estimate(Request calldata) external pure override returns (uint256) {
    return 0;
  }

  /// @inheritDoc IFund
  function asset() external pure override returns (address) {
    return address(0);
  }

  /// @inheritDoc IFund
  function totalAssets() external pure override returns (uint256) {
    return 0;
  }

  /// @inheritDoc IFund
  function maxDeposit(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritDoc IFund
  function maxRedeem(address) external pure override returns (uint256) {
    return type(uint256).max;
  }

  /// @inheritDoc IFund
  function state(Request calldata) external pure override returns (State) {
    return State.ENDED;
  }
}
