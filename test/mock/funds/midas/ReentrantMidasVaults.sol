// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {Order, State} from "src/libs/funds/Order.sol";

import {MockMidasDepositVault} from "./MockMidasDepositVault.sol";
import {MockMidasRedemptionVault} from "./MockMidasRedemptionVault.sol";

contract ReentrantMidasDepositVault is MockMidasDepositVault {
  MidasFund public reentrantFund;
  Order public reentrantOrder;
  bool public shouldReenter;
  bool public reenterSucceeded;
  bytes4 public reenterRevertSelector;

  constructor(address mToken_, address mTokenDataFeed_, address accessControl_)
    MockMidasDepositVault(mToken_, mTokenDataFeed_, accessControl_)
  {}

  function setReentrantCommit(MidasFund fund, Order calldata order) external {
    reentrantFund = fund;
    reentrantOrder = order;
    shouldReenter = true;
    reenterSucceeded = false;
    reenterRevertSelector = bytes4(0);
  }

  function depositRequest(address tokenIn, uint256 amountToken, bytes32 referrerId)
    public
    override
    returns (uint256 requestId)
  {
    _tryReentrantCommit();
    return super.depositRequest(tokenIn, amountToken, referrerId);
  }

  function _tryReentrantCommit() internal {
    if (!shouldReenter) return;
    shouldReenter = false;

    try reentrantFund.commit(reentrantOrder) returns (State, uint256) {
      reenterSucceeded = true;
    } catch (bytes memory reason) {
      reenterRevertSelector = _selector(reason);
    }
  }

  function _selector(bytes memory reason) private pure returns (bytes4 selector) {
    if (reason.length < 4) return bytes4(0);
    assembly {
      selector := mload(add(reason, 0x20))
    }
  }
}

contract ReentrantMidasRedemptionVault is MockMidasRedemptionVault {
  MidasFund public reentrantFund;
  Order public reentrantOrder;
  bool public shouldReenter;
  bool public reenterSucceeded;
  bytes4 public reenterRevertSelector;

  constructor(address mToken_, address mTokenDataFeed_, address accessControl_)
    MockMidasRedemptionVault(mToken_, mTokenDataFeed_, accessControl_)
  {}

  function setReentrantCommit(MidasFund fund, Order calldata order) external {
    reentrantFund = fund;
    reentrantOrder = order;
    shouldReenter = true;
    reenterSucceeded = false;
    reenterRevertSelector = bytes4(0);
  }

  function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) public override {
    _tryReentrantCommit();
    super.redeemInstant(tokenOut, amountMTokenIn, minReceiveAmount);
  }

  function _tryReentrantCommit() internal {
    if (!shouldReenter) return;
    shouldReenter = false;

    try reentrantFund.commit(reentrantOrder) returns (State, uint256) {
      reenterSucceeded = true;
    } catch (bytes memory reason) {
      reenterRevertSelector = _selector(reason);
    }
  }

  function _selector(bytes memory reason) private pure returns (bytes4 selector) {
    if (reason.length < 4) return bytes4(0);
    assembly {
      selector := mload(add(reason, 0x20))
    }
  }
}
