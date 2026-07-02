// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SUSD3Fund} from "src/funds/susd3/SUSD3Fund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";

import {MockERC20} from "../../MockERC20.sol";
import {MockUSD3} from "./MockUSD3.sol";
import {MockSUSD3} from "./MockSUSD3.sol";

/// @notice Invariant handler driving SUSD3Fund through its order lifecycle. Acts as the depositor.
contract SUSD3FundHandler is Test {
  uint256 private constant MIN_DEPOSIT = 1000e6;
  uint256 private constant MAX_DEPOSIT = 1_000_000e6;

  SUSD3Fund public fund;
  MockERC20 public usdc;
  MockUSD3 public usd3;
  MockSUSD3 public susd3;
  WrappedAsset public wrappedShare;
  address public operator;

  bool public initialized;
  bool public hasOrder;
  Order public order;
  uint256 public saltNonce;

  function initialize(
    SUSD3Fund fund_,
    MockERC20 usdc_,
    MockUSD3 usd3_,
    MockSUSD3 susd3_,
    WrappedAsset wrappedShare_,
    address operator_
  ) external {
    require(!initialized, "initialized");
    initialized = true;
    fund = fund_;
    usdc = usdc_;
    usd3 = usd3_;
    susd3 = susd3_;
    wrappedShare = wrappedShare_;
    operator = operator_;
  }

  function getOrder() external view returns (Order memory) {
    return order;
  }

  function _state() internal view returns (State) {
    return fund.state(order);
  }

  function act_createDeposit(uint96 amountSeed) external {
    if (hasOrder) return;
    uint256 amount = _bound(uint256(amountSeed), MIN_DEPOSIT, MAX_DEPOSIT);
    uint256 expected = susd3.convertToShares(usd3.convertToShares(amount));
    if (expected == 0) return;
    order = Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: expected,
      salt: bytes32(++saltNonce)
    });
    fund.create(order);
    hasOrder = true;
  }

  function act_createRedeem(uint96 sharesSeed) external {
    if (hasOrder) return;
    uint256 bal = wrappedShare.balanceOf(address(this));
    if (bal == 0) return;
    uint256 shares = _bound(uint256(sharesSeed), 1, bal);
    uint256 expected = usd3.convertToAssets(susd3.convertToAssets(shares));
    if (expected == 0) return;
    order = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: shares,
      output: expected,
      salt: bytes32(++saltNonce)
    });
    fund.create(order);
    hasOrder = true;
  }

  function act_cancel() external {
    if (!hasOrder || _state() != State.ACCEPTED) return;
    fund.cancel(order);
    hasOrder = false;
  }

  function act_commit() external {
    if (!hasOrder || _state() != State.ACCEPTED) return;
    if (order.mode == Mode.DEPOSIT) {
      usdc.mint(address(this), order.input);
      usdc.approve(address(fund), order.input);
    } else {
      wrappedShare.approve(address(fund), order.input);
    }
    fund.commit(order);
  }

  function act_warp(uint32 dtSeed) external {
    vm.warp(block.timestamp + _bound(uint256(dtSeed), 1, 40 days));
  }

  function act_unlock() external {
    if (!hasOrder || _state() != State.UNLOCKING) return;
    (State s,) = fund.unlock(order);
    if (s == State.ENDED) hasOrder = false;
  }

  function act_cancelRedeem() external {
    if (!hasOrder || order.mode != Mode.REDEEM || _state() != State.PROCESSING) return;
    vm.prank(operator);
    fund.cancelRedeem(order);
  }

  function act_recover() external {
    if (!hasOrder || _state() != State.RECOVERING) return;
    (State s,) = fund.recover(order);
    if (s == State.ENDED) hasOrder = false;
  }
}
