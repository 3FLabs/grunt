// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManagerRequestCallback} from "../../../src/interfaces/request/IPositionManagerRequestCallback.sol";

/// @notice Mock contract for testing IPositionManagerRequestCallback functionality
/// @dev Implements the callback to handle pullFunds callbacks
contract MockPositionManagerRequestCallback is IPositionManagerRequestCallback {
  bool public callbackCalled;
  uint256 public lastAmount;
  bytes public lastData;
  bool public shouldRevert;

  function setShouldRevert(bool _shouldRevert) external {
    shouldRevert = _shouldRevert;
  }

  function onPullFunds(uint256 amount, bytes calldata data) external override {
    if (shouldRevert) revert("MockPositionManagerRequestCallback: forced revert");

    callbackCalled = true;
    lastAmount = amount;
    lastData = data;
  }

  function reset() external {
    callbackCalled = false;
    lastAmount = 0;
    lastData = "";
  }
}

