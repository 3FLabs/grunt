// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ParetoFund} from "src/funds/pareto/ParetoFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";

import {MockERC20} from "../../MockERC20.sol";
import {MockIdleCDOEpochVariant} from "./MockIdleCDOEpochVariant.sol";
import {MockIdleCreditVault} from "./MockIdleCreditVault.sol";

contract ParetoFundHandler is Test {
  ParetoFund public fund;
  MockERC20 public usdc;
  MockERC20 public aaTranche;
  WrappedAsset public wrappedShare;
  MockIdleCDOEpochVariant public cdo;
  MockIdleCreditVault public strategy;

  bool public initialized;

  Order public order;
  State public internalState;

  function initialize(
    ParetoFund fund_,
    MockERC20 usdc_,
    MockERC20 aaTranche_,
    WrappedAsset wrappedShare_,
    MockIdleCDOEpochVariant cdo_,
    MockIdleCreditVault strategy_
  ) external {
    require(!initialized, "initialized");
    initialized = true;

    fund = fund_;
    usdc = usdc_;
    aaTranche = aaTranche_;
    wrappedShare = wrappedShare_;
    cdo = cdo_;
    strategy = strategy_;
    internalState = State.EMPTY;
  }

  function getOrder() external view returns (Order memory) {
    return order;
  }

  function act_createDeposit(uint96 input, bytes32 salt) external {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = _bound(uint256(input), 1, maxAmount);
    // At virtualPrice=1e18: output = input * 1e18 / 1e18 = input (in 18-decimal AA units)
    // But we keep it simple: output = inputAmount * 1e12 to scale USDC(6) → AA(18)
    uint256 outputAmount = inputAmount * 1e12;

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
  }

  function act_createRedeem(uint96 inputSeed, bytes32 salt) external {
    uint256 balance = wrappedShare.balanceOf(address(this));
    if (balance == 0) return;

    uint256 inputAmount = _bound(uint256(inputSeed), 1, balance);
    uint256 outputAmount = inputAmount / 1e12; // scale AA(18) → USDC(6)
    if (outputAmount == 0) return;

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
  }

  function act_cancel() external {
    fund.cancel(order);
    internalState = State.EMPTY;
  }

  function act_commit() external {
    if (order.mode == Mode.DEPOSIT) {
      usdc.mint(address(this), order.input);
      usdc.approve(address(fund), order.input);
    } else {
      wrappedShare.approve(address(fund), order.input);
    }

    fund.commit(order);
    internalState = State.PROCESSING;
  }

  function act_cdoFulfillDeposit() external {
    // For deposits, depositAA already minted AA tranche to the fund during commit.
    // If output is not met, mint additional AA to the fund.
    uint256 currentBalance = aaTranche.balanceOf(address(fund));
    if (currentBalance < order.output) {
      aaTranche.mint(address(fund), order.output - currentBalance);
    }
  }

  function act_cdoFulfillRedeem() external {
    // Fund CDO with underlying and advance epoch
    uint256 pendingAmount = strategy.totalClaimable(address(fund));
    if (pendingAmount == 0) return;
    cdo.fundUnderlying(pendingAmount);
    cdo.advanceEpoch();
  }

  function act_resolve(uint96 newInput, uint96 newOutput) external {
    uint256 resolvedInput = _bound(uint256(newInput), 1, type(uint96).max);
    uint256 resolvedOutput = _bound(uint256(newOutput), 1, type(uint96).max);
    fund.resolve(order, resolvedInput, resolvedOutput);
  }

  function act_unlock() external {
    (State newState,) = fund.unlock(order);
    internalState = newState;
  }
}
