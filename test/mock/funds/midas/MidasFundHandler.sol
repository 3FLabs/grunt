// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {BondConfig} from "src/interfaces/funds/midas/IMidasFund.sol";

import {MockERC20} from "../../MockERC20.sol";
import {MockMidasDepositVault} from "./MockMidasDepositVault.sol";
import {MockMidasRedemptionVault} from "./MockMidasRedemptionVault.sol";

/// @dev Invariant handler for MidasFund. Acts as the depositor (and operator/payment
///      operator/vault manager) and mirrors the fund's internal state machine in
///      `internalState`.
///      Deposits settle asynchronously via a Midas mint request (approve/reject driven by
///      act_approveRequest/act_rejectRequest). Redeems always commit in two legs: the bond
///      leg pays the bond to `bondRecipient` (tracked in `ghostTotalBondPaid`, nothing when
///      the config is empty), then act_unlockInstantRedeem re-arms the order for the redeem
///      leg — also callable before any commit to skip the bond leg — which settles instantly
///      through whichever redemption vault act_swapRedemptionVault configured (create()
///      resets it, so the redeem leg reverts until a vault is set); the single terminal
///      unlock then ends the order. Reverting actions are rolled back entirely
///      (fail_on_revert = false), so the model only advances on success.
contract MidasFundHandler is Test {
  using LibOrder for Order;

  MidasFund public fund;
  MockERC20 public usdc;
  MockERC20 public mToken;
  WrappedAsset public wrappedShare;
  MockMidasDepositVault public depositVault;
  MockMidasRedemptionVault public redemptionVault;
  MockMidasRedemptionVault public redemptionVault2;

  bool public initialized;

  Order public order;
  State public internalState;
  bool public rejected;
  bool public refunded;
  uint256 public requestId;

  address public bondRecipient = address(0xB07D);
  uint256 public ghostTotalBondPaid;

  function initialize(
    MidasFund fund_,
    MockERC20 usdc_,
    MockERC20 mToken_,
    WrappedAsset wrappedShare_,
    MockMidasDepositVault depositVault_,
    MockMidasRedemptionVault redemptionVault_,
    MockMidasRedemptionVault redemptionVault2_
  ) external {
    require(!initialized, "initialized");
    initialized = true;

    fund = fund_;
    usdc = usdc_;
    mToken = mToken_;
    wrappedShare = wrappedShare_;
    depositVault = depositVault_;
    redemptionVault = redemptionVault_;
    redemptionVault2 = redemptionVault2_;
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
    rejected = false;
    refunded = false;
    requestId = 0;
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
    rejected = false;
    refunded = false;
    requestId = 0;
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

    uint256 bondPaidBefore = fund.bondPaid();
    fund.commit(order);
    internalState = State.PROCESSING;
    // Deposits always settle via a Midas mint request; redeems settle instantly (the bond leg
    // of a bonded redeem only pays the bond, tracked via the bondPaid delta).
    if (order.mode == Mode.DEPOSIT) requestId = fund.activeRequestId();
    else ghostTotalBondPaid += fund.bondPaid() - bondPaidBefore;
  }

  /// @dev Simulates the Midas admin approving the pending mint request of the current
  ///      deposit order (mints the mToken directly to the fund).
  function act_approveRequest() external {
    if (internalState != State.PROCESSING || order.mode != Mode.DEPOSIT || rejected) return;
    depositVault.approveDepositRequest(requestId);
  }

  /// @dev Simulates the Midas admin rejecting the pending mint request of the current
  ///      deposit order (the pulled USDC is NOT refunded on-chain).
  function act_rejectRequest() external {
    if (internalState != State.PROCESSING || order.mode != Mode.DEPOSIT || rejected) return;
    depositVault.rejectDepositRequest(requestId);
    rejected = true;
  }

  /// @dev Simulates the off-band USDC refund performed by the Midas admin, either after a
  ///      rejected deposit request (the vault returns the pulled USDC) or while the
  ///      operator has flagged the order as RECOVERING (for an aborted bonded redeem the
  ///      refund is swept by recover(), which is also fine with a zero balance).
  function act_refund() external {
    if (refunded) return;
    bool depositRejected = order.mode == Mode.DEPOSIT && rejected && internalState == State.PROCESSING;
    if (internalState != State.RECOVERING && !depositRejected) return;
    depositVault.withdrawToken(address(usdc), address(fund), order.input);
    refunded = true;
  }

  function act_resolve(uint96 newInput, uint96 newOutput) external {
    uint256 resolvedInput = _bound(uint256(newInput), 1, type(uint96).max);
    uint256 resolvedOutput = _bound(uint256(newOutput), 0, type(uint96).max);
    fund.resolve(order, resolvedInput, resolvedOutput);
  }

  function act_recovering() external {
    // Succeeds for PROCESSING deposits and unsettled bonded redeems (bond phase, or
    // re-ACCEPTED with the bond paid); reverts otherwise (RecoverNotSupported /
    // InvalidState) and the model only advances on success.
    fund.recovering(order);
    internalState = State.RECOVERING;
  }

  function act_cancelRecovering() external {
    fund.cancelRecovering(order.toId(address(fund)));
    internalState = State.PROCESSING;
  }

  function act_unlock() external {
    // Single-shot for both modes: unlock() always ends the order.
    (State newState,) = fund.unlock(order);
    internalState = newState;
  }

  function act_recover() external {
    fund.recover(order);
    internalState = State.ENDED;
  }

  /// @dev Sets the bond config (reverts while an order is live).
  function act_setBondConfig(uint16 bpsSeed) external {
    uint256 bps = _bound(uint256(bpsSeed), 1, fund.MAX_BOND_AMOUNT());
    fund.setBondConfig(BondConfig({amount: bps, recipient: bondRecipient}));
  }

  /// @dev Removes the bond config (reverts while an order is live), so both bonded and
  ///      unbonded redeems are explored.
  function act_removeBondConfig() external {
    fund.removeBondConfig();
  }

  /// @dev Unlocks the instant redemption of a bonded redeem (reverts unless the current order
  ///      is bond-locked in ACCEPTED or PROCESSING; the model only advances on success).
  function act_unlockInstantRedeem() external {
    fund.unlockInstantRedeem(order.toId(address(fund)));
    internalState = State.ACCEPTED;
  }

  /// @dev Swaps the redemption vault between the two mock instances. Never gated on the order
  ///      state (the redemption vault carries no per-order state): a live redeem settles
  ///      through whichever vault is configured when its redeem leg commits.
  function act_swapRedemptionVault(bool useSecondary) external {
    fund.setRedemptionVault(address(useSecondary ? redemptionVault2 : redemptionVault));
  }
}
