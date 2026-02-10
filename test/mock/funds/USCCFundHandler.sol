// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {USCCFund} from "src/funds/USCCFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";

import {MockERC20} from "../MockERC20.sol";
import {MockSuperstateToken} from "./MockSuperstateToken.sol";

contract USCCFundHandler is Test {
  USCCFund public fund;
  MockERC20 public usdc;
  MockSuperstateToken public uscc;
  WrappedAsset public wuscc;
  address public recipient;

  bool public initialized;

  Order public order;
  State public internalState;
  uint256 public cachedUsccBalance;
  uint256 public expectedRecipientUsdc;
  uint256 public effectiveInput;
  uint256 public effectiveOutput;

  function initialize(
    USCCFund fund_,
    MockERC20 usdc_,
    MockSuperstateToken uscc_,
    WrappedAsset wuscc_,
    address recipient_
  ) external {
    require(!initialized, "initialized");
    initialized = true;

    fund = fund_;
    usdc = usdc_;
    uscc = uscc_;
    wuscc = wuscc_;
    recipient = recipient_;
    internalState = State.EMPTY;
    effectiveInput = 0;
    effectiveOutput = 0;
  }

  function getOrder() external view returns (Order memory) {
    return order;
  }

  function act_createDeposit(uint96 input, uint96 output, bytes32 salt) external {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = _bound(uint256(input), 1, maxAmount);
    uint256 outputAmount = _bound(uint256(output), 0, maxAmount);

    order = Order({
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: outputAmount,
      mode: Mode.DEPOSIT,
      salt: salt
    });

    fund.create(order);
    internalState = State.ACCEPTED;
    cachedUsccBalance = 0;
    effectiveInput = inputAmount;
    effectiveOutput = outputAmount;
  }

  function act_cancel(uint96 input, uint96 output, bytes32 salt) external {
    order = Order({
      owner: address(this),
      receiver: address(this),
      input: uint256(input),
      output: uint256(output),
      mode: Mode.DEPOSIT,
      salt: salt
    });
    internalState = fund.cancel(order);
    effectiveInput = 0;
    effectiveOutput = 0;
  }

  function act_createRedeem(uint96 inputSeed, uint96 output, bytes32 salt) external {
    uint256 balance = wuscc.balanceOf(address(this));
    uint256 fundBalance = uscc.balanceOf(address(fund));
    uint256 maxAmount = balance < fundBalance ? balance : fundBalance;
    if (maxAmount == 0) return;

    uint256 inputAmount = _bound(uint256(inputSeed), 1, maxAmount);
    uint256 outputAmount = _bound(uint256(output), 0, type(uint96).max);

    order = Order({
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: outputAmount,
      mode: Mode.REDEEM,
      salt: salt
    });

    fund.create(order);
    internalState = State.ACCEPTED;
    cachedUsccBalance = 0;
    effectiveInput = inputAmount;
    effectiveOutput = outputAmount;
  }

  function act_commit() external {
    if (order.mode == Mode.DEPOSIT) {
      usdc.mint(address(this), order.input);
      usdc.approve(address(fund), order.input);
      (State newState, uint256 amount) = fund.commit(order);
      require(newState == State.PROCESSING, "commit state");
      require(amount == order.input, "commit amount");
      internalState = State.PROCESSING;
      cachedUsccBalance = uscc.balanceOf(address(fund));
      expectedRecipientUsdc += order.input;
    } else {
      // Only commit redeem orders that are fully backed and owned by this handler.
      if (wuscc.balanceOf(address(this)) < order.input) return;
      if (uscc.balanceOf(address(fund)) < order.input) return;

      (State newState, uint256 amount) = fund.commit(order);
      require(newState == State.PROCESSING, "commit state");
      require(amount == order.input, "commit amount");
      internalState = State.PROCESSING;
      cachedUsccBalance = uscc.balanceOf(address(fund));
    }
  }

  function act_setRecovering() external {
    fund.recovering();
    internalState = State.RECOVERING;
  }

  function act_cancelRecovering() external {
    fund.cancelRecovering();
    internalState = State.PROCESSING;
  }

  function act_resolve(uint96 newInput, uint96 newOutput) external {
    uint256 maxAmount = type(uint96).max;
    uint256 resolvedInput = _bound(uint256(newInput), 0, maxAmount);
    uint256 resolvedOutput = _bound(uint256(newOutput), 0, maxAmount);

    fund.resolve(order, resolvedInput, resolvedOutput);

    effectiveInput = resolvedInput;
    effectiveOutput = resolvedOutput;
  }

  function act_superstateMintUscc(uint96 amount) external {
    uscc.mint(address(fund), uint256(amount));
  }

  function act_superstateMintUsdc(uint96 amount) external {
    usdc.mint(address(fund), uint256(amount));
  }

  function act_unlock() external {
    if (order.mode == Mode.DEPOSIT) {
      uint256 beforeBalance = wuscc.balanceOf(address(this));
      uint256 currentUscc = uscc.balanceOf(address(fund));
      uint256 expected = currentUscc >= cachedUsccBalance ? currentUscc - cachedUsccBalance : 0;

      (State newState, uint256 amount) = fund.unlock(order);
      require(newState == State.ENDED, "unlock state");
      require(amount == expected, "unlock amount");

      assertEq(wuscc.balanceOf(address(this)) - beforeBalance, expected, "wuscc minted");
    } else {
      uint256 beforeBalance = usdc.balanceOf(address(this));
      uint256 expected = usdc.balanceOf(address(fund));

      (State newState, uint256 amount) = fund.unlock(order);
      require(newState == State.ENDED, "unlock state");
      require(amount == expected, "unlock amount");

      assertEq(usdc.balanceOf(address(this)) - beforeBalance, expected, "usdc received");
      assertEq(usdc.balanceOf(address(fund)), 0, "fund usdc cleared");
    }

    internalState = State.ENDED;
  }

  function act_recover() external {
    if (order.mode == Mode.DEPOSIT) {
      uint256 beforeBalance = usdc.balanceOf(address(this));
      uint256 expected = usdc.balanceOf(address(fund));

      (State newState, uint256 amount) = fund.recover(order);
      require(newState == State.ENDED, "recover state");
      require(amount == expected, "recover amount");

      assertEq(usdc.balanceOf(address(this)) - beforeBalance, expected, "usdc recovered");
      assertEq(usdc.balanceOf(address(fund)), 0, "fund usdc cleared");
    } else {
      uint256 beforeBalance = wuscc.balanceOf(address(this));
      uint256 currentUscc = uscc.balanceOf(address(fund));
      uint256 expected = currentUscc >= cachedUsccBalance ? currentUscc - cachedUsccBalance : 0;

      (State newState, uint256 amount) = fund.recover(order);
      require(newState == State.ENDED, "recover state");
      require(amount == expected, "recover amount");

      assertEq(wuscc.balanceOf(address(this)) - beforeBalance, expected, "wuscc recovered");
    }

    internalState = State.ENDED;
  }
}
