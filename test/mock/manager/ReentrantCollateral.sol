// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20Mock} from "lib/morpho-blue/src/mocks/ERC20Mock.sol";
import {ReentrantMinter} from "./ReentrantMinter.sol";

/// @title ReentrantCollateral
/// @notice ERC20Mock that calls onTokenReceived on the recipient after transfer
contract ReentrantCollateral is ERC20Mock {
  bool public callbackEnabled;

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
