// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IRequestInteractionsCallback} from "../../../src/interfaces/request/IRequestInteractionsCallback.sol";

/// @notice Mock contract for testing IRequestInteractionsCallback functionality
/// @dev Implements the callback to handle pullFunds callbacks
contract MockRequestInteractionsCallback is IRequestInteractionsCallback {
  bool public callbackCalled;
  uint256 public lastAmount;
  bytes public lastData;
  bool public shouldRevert;

  function setShouldRevert(bool _shouldRevert) external {
    shouldRevert = _shouldRevert;
  }

  function onPullFunds(uint256 amount, bytes calldata data) external override {
    if (shouldRevert) revert("MockRequestInteractionsCallback: forced revert");

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
