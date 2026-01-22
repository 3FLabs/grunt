// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MockERC20} from "test/mock/MockERC20.sol";
import {ReentrantMinter} from "./ReentrantMinter.sol";

/// @title ReentrantCollateral
/// @notice MockERC20 that calls onTokenReceived on the recipient after transfer
contract ReentrantCollateral is MockERC20 {
  bool public callbackEnabled;

  constructor() MockERC20("Reentrant Collateral", "RC", 18) {}

  function setCallbackEnabled(bool enabled) external {
    callbackEnabled = enabled;
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    bool result = super.transfer(to, amount);
    if (callbackEnabled && to.code.length > 0) {
      try ReentrantMinter(payable(to)).onTokenReceived() {} catch {}
    }
    return result;
  }
}
