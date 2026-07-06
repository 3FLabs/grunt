// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {SettlementMode} from "src/interfaces/funds/midas/IMidasFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";

import {MockERC20} from "../../MockERC20.sol";
import {MockMidasDepositVault} from "./MockMidasDepositVault.sol";
import {MockMidasRedemptionVault} from "./MockMidasRedemptionVault.sol";

/// @dev Invariant handler for MidasFund. Acts as the depositor (and operator) and mirrors
///      the fund's internal state machine in `internalState`. Reverting actions are rolled
///      back entirely (fail_on_revert = false), so the model only advances on success.
contract MidasFundHandler is Test {
  using LibOrder for Order;

  MidasFund public fund;
  MockERC20 public usdc;
  MockERC20 public mToken;
  WrappedAsset public wrappedShare;
  MockMidasDepositVault public depositVault;
  MockMidasRedemptionVault public redemptionVault;

  bool public initialized;

  Order public order;
  State public internalState;
  bool public committedAsRequest;
  bool public rejected;
  bool public refunded;
  uint256 public requestId;

  function initialize(
    MidasFund fund_,
    MockERC20 usdc_,
    MockERC20 mToken_,
    WrappedAsset wrappedShare_,
    MockMidasDepositVault depositVault_,
    MockMidasRedemptionVault redemptionVault_
  ) external {
    require(!initialized, "initialized");
    initialized = true;

    fund = fund_;
    usdc = usdc_;
    mToken = mToken_;
    wrappedShare = wrappedShare_;
    depositVault = depositVault_;
    redemptionVault = redemptionVault_;
    internalState = State.EMPTY;
  }

  function getOrder() external view returns (Order memory) {
    return order;
  }

  function act_createDeposit(uint96 input, bytes32 salt) external {
    uint256 inputAmount = _bound(uint256(input), 1, type(uint96).max);
    // At 1:1 rates: output (base-18 mToken) = input (USDC 6 decimals) * 1e12
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
    committedAsRequest = false;
    rejected = false;
    refunded = false;
  }

  function act_createRedeem(uint96 inputSeed, bytes32 salt) external {
    uint256 balance = wrappedShare.balanceOf(address(this));
    if (balance == 0) return;

    uint256 inputAmount = _bound(uint256(inputSeed), 1, balance);
    uint256 outputAmount = inputAmount / 1e12; // scale mToken(18) → USDC(6)
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
    committedAsRequest = false;
    rejected = false;
    refunded = false;
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
    committedAsRequest = fund.settlementMode(order.mode) == SettlementMode.REQUEST;
    requestId = fund.activeRequestId();
  }

  function act_approveRequest() external {
    if (internalState != State.PROCESSING || !committedAsRequest || rejected) return;
    if (order.mode == Mode.DEPOSIT) {
      depositVault.approveDepositRequest(requestId);
    } else {
      redemptionVault.approveRedeemRequest(requestId, order.output);
    }
  }

  function act_rejectRequest() external {
    if (internalState != State.PROCESSING || !committedAsRequest || rejected) return;
    if (order.mode == Mode.DEPOSIT) {
      depositVault.rejectDepositRequest(requestId);
    } else {
      redemptionVault.rejectRedeemRequest(requestId);
    }
    rejected = true;
  }

  /// @dev Simulates the off-band refund performed by the Midas admin after a rejection.
  function act_refund() external {
    if (!rejected || refunded) return;
    if (order.mode == Mode.DEPOSIT) {
      depositVault.withdrawToken(address(usdc), address(fund), order.input);
    } else {
      redemptionVault.withdrawToken(address(mToken), address(fund), order.input);
    }
    refunded = true;
  }

  function act_resolve(uint96 newInput, uint96 newOutput) external {
    uint256 resolvedInput = _bound(uint256(newInput), 1, type(uint96).max);
    uint256 resolvedOutput = _bound(uint256(newOutput), 0, type(uint96).max);
    fund.resolve(order, resolvedInput, resolvedOutput);
  }

  function act_recovering() external {
    fund.recovering(order.toId(address(fund)));
    internalState = State.RECOVERING;
  }

  function act_cancelRecovering() external {
    fund.cancelRecovering(order.toId(address(fund)));
    internalState = State.PROCESSING;
  }

  function act_unlock() external {
    fund.unlock(order);
    internalState = State.ENDED;
  }

  function act_recover() external {
    fund.recover(order);
    internalState = State.ENDED;
  }

  function act_setSettlementMode(uint8 modeSeed, uint8 settlementSeed) external {
    fund.setSettlementMode(Mode(modeSeed % 2), SettlementMode(settlementSeed % 2));
  }
}
