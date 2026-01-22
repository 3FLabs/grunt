// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPreLiquidationCallback} from "src/interfaces/borrow/IPreliquidationCallback.sol";
import {ERC20Mock} from "lib/morpho-blue/src/mocks/ERC20Mock.sol";

contract MockPreLiquidationCallback is IPreLiquidationCallback {
  address public loanToken;
  bool public callbackReceived;

  constructor(address _loanToken) {
    loanToken = _loanToken;
  }

  function onPreLiquidate(uint256 repaidAssets, bytes calldata data) external override {
    callbackReceived = true;
    // Approve the caller (MorphoBorrowPosition) to pull the loan tokens
    ERC20Mock(loanToken).approve(msg.sender, repaidAssets);
  }
}
