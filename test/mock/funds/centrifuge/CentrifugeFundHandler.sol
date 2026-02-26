// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentrifugeFund} from "src/funds/centrifuge/CentrifugeFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";

import {MockERC20} from "../../MockERC20.sol";
import {MockCentrifugeVault} from "./MockCentrifugeVault.sol";

contract CentrifugeFundHandler is Test {
  CentrifugeFund public fund;
  MockERC20 public assetToken;
  MockERC20 public shareToken;
  WrappedAsset public wrappedShare;
  MockCentrifugeVault public vault;

  bool public initialized;

  Order public order;
  State public internalState;

  function initialize(
    CentrifugeFund fund_,
    MockERC20 assetToken_,
    MockERC20 shareToken_,
    WrappedAsset wrappedShare_,
    MockCentrifugeVault vault_
  ) external {
    require(!initialized, "initialized");
    initialized = true;

    fund = fund_;
    assetToken = assetToken_;
    shareToken = shareToken_;
    wrappedShare = wrappedShare_;
    vault = vault_;
    internalState = State.EMPTY;
  }

  function getOrder() external view returns (Order memory) {
    return order;
  }

  function act_createDeposit(uint96 input, bytes32 salt) external {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = _bound(uint256(input), 1, maxAmount);

    order = Order({
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: inputAmount, // 1:1 rate
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

    order = Order({
      owner: address(this),
      receiver: address(this),
      input: inputAmount,
      output: inputAmount, // 1:1 rate
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
      assetToken.mint(address(this), order.input);
      assetToken.approve(address(fund), order.input);
    } else {
      // For redeem, fund.commit calls wrappedShare.burn(from=handler, to=fund, amount)
      // which needs allowance since from != msg.sender (msg.sender is the fund)
      wrappedShare.approve(address(fund), order.input);
    }

    fund.commit(order);
    internalState = State.PROCESSING;
  }

  function act_cancelRequest() external {
    fund.cancelRequest(order);
    internalState = State.RECOVERING;
  }

  function act_vaultFulfillDeposit() external {
    uint256 pending = vault._pendingDeposits(address(fund));
    if (pending == 0) return;
    vault.fulfillDeposit(address(fund), pending);
  }

  function act_vaultFulfillRedeem() external {
    uint256 pending = vault._pendingRedeems(address(fund));
    if (pending == 0) return;
    vault.fulfillRedeem(address(fund), pending);
  }

  function act_vaultFulfillCancelDeposit() external {
    if (!vault._pendingCancelDeposit(address(fund))) return;
    uint256 amount = vault._pendingDeposits(address(fund));
    vault.fulfillCancelDeposit(address(fund), amount);
  }

  function act_vaultFulfillCancelRedeem() external {
    if (!vault._pendingCancelRedeem(address(fund))) return;
    uint256 amount = vault._pendingRedeems(address(fund));
    vault.fulfillCancelRedeem(address(fund), amount);
  }

  function act_unlock() external {
    (State newState,) = fund.unlock(order);
    internalState = newState;
  }

  function act_recover() external {
    (State newState,) = fund.recover(order);
    internalState = newState;
  }
}
