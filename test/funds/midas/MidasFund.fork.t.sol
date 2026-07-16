// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {MidasFundFactory} from "src/funds/midas/MidasFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {BondConfig} from "src/interfaces/funds/midas/IMidasFund.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";
import {IMidasVault, MidasRequestStatus} from "src/interfaces/integrations/midas/IMidasVault.sol";
import {IMidasDepositVault} from "src/interfaces/integrations/midas/IMidasDepositVault.sol";
import {IMidasDataFeed} from "src/interfaces/integrations/midas/IMidasDataFeed.sol";

/// @dev Admin surface of the Midas vaults used in fork tests (not part of the src interfaces).
interface IMidasVaultAdminFork {
  function approveRequest(uint256 requestId, uint256 newRate) external;
  function rejectRequest(uint256 requestId) external;
  function unpauseFn(bytes4 fn) external;
  function fnPaused(bytes4 fn) external view returns (bool);
}

/// @dev Minimal OZ AccessControl surface of the MidasAccessControl contract.
interface IMidasAccessControlFork {
  function grantRole(bytes32 role, address account) external;
  function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Fork tests for MidasFund against the mainnet Midas mGLOBAL deployment.
/// @dev Live mGLOBAL config at the pinned block:
///      - deposit vault (WithAave): instantFee 0, minAmount 0, unlimited daily limit,
///        minMTokenAmountForFirstDeposit = 114_000e18 mGLOBAL (deposits must clear it),
///        depositRequest is fn-paused on-chain → unpaused here by an impersonated vault admin.
///      - Aave redemption vault: instantFee 50 (0.5%).
///      - swapper redemption vault: instantFee 50, minAmount 1e18 mGLOBAL.
///      - mGLOBAL is permissioned: every transfer requires both parties to hold
///        M_GLOBAL_GREENLISTED_ROLE (mints only check the recipient, burns are unchecked).
contract MidasFundForkTest is Test {
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Pinned on 2026-07-06 (latest - ~150 at time of writing).
  uint256 constant FORK_BLOCK = 25_472_600;

  address constant MGLOBAL = 0x7433806912Eae67919e66aea853d46Fa0aef98A8;
  address constant DEPOSIT_VAULT = 0xCe29c36c6D4556f2d01d79414C1354B968dDDEf1;
  address constant REDEMPTION_VAULT_AAVE = 0xA0Fc8BDFb1E6a705C1375810989B1d70a982b01B;
  address constant REDEMPTION_VAULT_SWAPPER = 0x1e0fd66753198c7b8bA64edEe8d41D8628Bf20D7;
  address constant MIDAS_ACCESS_CONTROL = 0x0312A9D1Ff2372DDEdCBB21e4B6389aFc919aC4B;
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

  /// @dev EOA holding DEFAULT_ADMIN_ROLE on the MidasAccessControl at the pinned block.
  address constant MIDAS_DEFAULT_ADMIN = 0xd4195CF4df289a4748C1A7B6dDBE770e27bA1227;

  bytes32 constant GREENLISTED_ROLE = keccak256("M_GLOBAL_GREENLISTED_ROLE");
  bytes32 constant DEPOSIT_VAULT_ADMIN_ROLE = keccak256("M_GLOBAL_DEPOSIT_VAULT_ADMIN_ROLE");

  /// @dev Selector used by the Midas per-function pause registry.
  bytes4 constant SEL_DEPOSIT_REQUEST = bytes4(keccak256("depositRequest(address,uint256,bytes32)"));

  uint256 constant ONE = 1e6; // USDC unit
  uint256 constant SCALE = 1e12; // USDC native → base-18
  uint256 constant BPS = 10_000;

  /// @dev Midas percent precision: 100% = 100_00; instant redemption fee is 50 = 0.5%.
  uint256 constant REDEEM_INSTANT_FEE = 50;

  /// @dev Above the 114_000e18 mGLOBAL first-deposit floor (~123k USDC at the pinned rate).
  uint256 constant DEPOSIT_AMOUNT = 200_000 * ONE;

  uint256 constant ISSUER_ROLE = 1 << 0;
  uint256 constant SENDER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           STATE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MidasFundFactory factory;
  MidasFund fund;
  WrappedAsset wrappedShare;
  address owner;
  address midasAdmin;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

    owner = makeAddr("owner");
    midasAdmin = makeAddr("midasAdmin");

    // Deploy WrappedAsset proxy wrapping the real mGLOBAL token
    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    wrappedShare.initialize(owner, owner, MGLOBAL, "wmGLOBAL", "Wrapped mGLOBAL");

    // Deploy fund via factory
    factory = new MidasFundFactory(owner);
    address fundAddress =
      factory.createFund(owner, address(this), DEPOSIT_VAULT, REDEMPTION_VAULT_AAVE, address(wrappedShare), USDC);
    fund = MidasFund(fundAddress);

    // Grant roles on wrappedShare
    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
    vm.stopPrank();

    // Midas roles: greenlist the fund and the wrapper (mGLOBAL gates every transfer on both
    // parties). Also set up a vault admin to unpause the fn-paused deposit entry point and
    // to approve/reject mint requests.
    IMidasAccessControlFork accessControl = IMidasAccessControlFork(MIDAS_ACCESS_CONTROL);
    vm.startPrank(MIDAS_DEFAULT_ADMIN);
    accessControl.grantRole(GREENLISTED_ROLE, address(fund));
    accessControl.grantRole(GREENLISTED_ROLE, address(wrappedShare));
    accessControl.grantRole(DEPOSIT_VAULT_ADMIN_ROLE, midasAdmin);
    vm.stopPrank();

    // depositRequest is fn-paused on mainnet at the pinned block → unpause it.
    _unpauseFn(DEPOSIT_VAULT, SEL_DEPOSIT_REQUEST);

    // Fund test contract with USDC
    _dealUSDC(address(this), 1_000_000 * ONE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST SCENARIOS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Fork_RequestDeposit_ApproveLifecycle() public {
    uint256 expectedShares = _expectedDepositShares(DEPOSIT_AMOUNT);

    Order memory order = _depositOrder(DEPOSIT_AMOUNT, _haircut(expectedShares));
    assertEq(uint256(fund.create(order)), uint256(State.ACCEPTED), "accepted");

    // Commit: depositRequest transfers the USDC to Midas; no mGLOBAL is minted yet
    IERC20(USDC).approve(address(fund), order.input);
    (State committed,) = fund.commit(order);
    assertEq(uint256(committed), uint256(State.PROCESSING), "processing returned by commit");
    assertEq(IERC20(MGLOBAL).balanceOf(address(fund)), 0, "no mToken minted at commit");

    // The order waits for a Midas vault admin decision on the mint request
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing after commit");
    uint256 requestId = fund.activeRequestId();
    (address sender,, MidasRequestStatus status,,, uint256 tokenOutRate) =
      IMidasDepositVault(DEPOSIT_VAULT).mintRequests(requestId);
    assertEq(sender, address(fund), "request sender is fund");
    assertEq(uint256(status), uint256(MidasRequestStatus.PENDING), "request pending");

    // Deposits carry no holdback: nothing pending, nothing to confirm
    assertFalse(fund.holdbackPending(), "no holdback pending for deposits");
    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.HoldbackNotPending.selector);
    fund.confirmHoldback(order.toId(address(fund)));

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    // Approve at the snapshotted rate → mints mGLOBAL directly to the fund
    vm.prank(midasAdmin);
    IMidasVaultAdminFork(DEPOSIT_VAULT).approveRequest(requestId, tokenOutRate);

    (,, status,,,) = IMidasDepositVault(DEPOSIT_VAULT).mintRequests(requestId);
    assertEq(uint256(status), uint256(MidasRequestStatus.PROCESSED), "request processed");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after approval");

    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertGe(amount, order.output, "shares >= min output");
    assertApproxEqRel(amount, expectedShares, 0.001e18, "shares match deposit feed");
    assertEq(wrappedShare.balanceOf(address(this)), amount, "wmGLOBAL balance");
    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "state ENDED");
  }

  function test_Fork_RequestDeposit_RejectAndRecover() public {
    Order memory order = _depositOrder(DEPOSIT_AMOUNT, _haircut(_expectedDepositShares(DEPOSIT_AMOUNT)));
    fund.create(order);

    IERC20(USDC).approve(address(fund), order.input);
    fund.commit(order);
    uint256 requestId = fund.activeRequestId();

    // Midas admin rejects the request; the input is NOT refunded on-chain
    vm.prank(midasAdmin);
    IMidasVaultAdminFork(DEPOSIT_VAULT).rejectRequest(requestId);

    (,, MidasRequestStatus status,,,) = IMidasDepositVault(DEPOSIT_VAULT).mintRequests(requestId);
    assertEq(uint256(status), uint256(MidasRequestStatus.CANCELED), "request canceled");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still processing (no refund yet)");

    // Simulate the off-band refund by the Midas admin (e.g. via withdrawToken)
    _dealUSDC(address(fund), DEPOSIT_AMOUNT);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering once refunded");

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, DEPOSIT_AMOUNT, "full input recovered");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, amount, "USDC returned to receiver");
  }

  function test_Fork_InstantRedeem_HoldbackLifecycle() public {
    uint256 shares = _doFullDeposit(DEPOSIT_AMOUNT);

    // 0.5% instant fee is taken in mGLOBAL before conversion at the redemption feed
    uint256 expectedNet = _expectedRedeemAssets(shares * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_AAVE);
    Order memory order = _redeemOrder(shares, _haircut(expectedNet));
    fund.create(order);

    // The Aave redemption vault holds no USDC at the pinned block; redeemInstant sources
    // the payout by burning the vault's aEthUSDC (~5.75M available).
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    // The payout arrived and is claimable right away, while the holdback stays pending.
    assertGt(IERC20(USDC).balanceOf(address(fund)), 0, "payout delivered to the fund");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable");
    assertTrue(fund.holdbackPending(), "holdback pending");

    // Partial unlock of the instant proceeds; the order returns to PROCESSING.
    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "partial: back to processing");
    assertGe(amount, order.output, "assets >= min output");
    assertApproxEqRel(amount, expectedNet, 0.001e18, "assets match redemption feed minus fee");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, amount, "USDC received");
    assertEq(wrappedShare.balanceOf(address(this)), 0, "all shares burned");
    assertTrue(fund.holdbackPending(), "holdback still pending");

    // The off-band holdback payment arrives (_dealUSDC sets the balance, zero after the sweep).
    uint256 holdbackAmount = 10_000 * ONE;
    _dealUSDC(address(fund), holdbackAmount);

    // Confirming with a positive balance leaves the final sweep to unlock().
    vm.prank(owner);
    fund.confirmHoldback(order.toId(address(fund)));
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "holdback claimable");

    (state, amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, holdbackAmount, "holdback swept");
  }

  function test_Fork_InstantRedeem_HoldbackPaymentSwept() public {
    uint256 shares = _doFullDeposit(DEPOSIT_AMOUNT);

    uint256 expectedNet = _expectedRedeemAssets(shares * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_AAVE);
    Order memory order = _redeemOrder(shares, _haircut(expectedNet));
    fund.create(order);

    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    uint256 instantProceeds = IERC20(USDC).balanceOf(address(fund));

    // The off-band holdback payment (e.g. the 7% true-up) arrives at the fund.
    uint256 holdbackAmount = 10_000 * ONE;
    _dealUSDC(address(fund), instantProceeds + holdbackAmount);

    // The full balance (instant proceeds + holdback) is claimable even before confirmation.
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "full balance claimable");

    vm.prank(owner);
    fund.confirmHoldback(order.toId(address(fund)));

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (, uint256 amount) = fund.unlock(order);
    assertEq(amount, instantProceeds + holdbackAmount, "instant proceeds + holdback swept");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, amount, "USDC received");
  }

  function test_Fork_BondedInstantRedeem_Lifecycle() public {
    uint256 shares = _doFullDeposit(DEPOSIT_AMOUNT);

    // The bond recipient must be greenlisted (mGLOBAL gates every transfer on both parties).
    address bondRecipient = makeAddr("bondRecipient");
    vm.prank(MIDAS_DEFAULT_ADMIN);
    IMidasAccessControlFork(MIDAS_ACCESS_CONTROL).grantRole(GREENLISTED_ROLE, bondRecipient);

    vm.prank(owner);
    fund.setBondConfig(BondConfig({amount: 200, recipient: bondRecipient}));

    uint256 expectedNet = _expectedRedeemAssets(shares * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_AAVE);
    Order memory order = _redeemOrder(shares, _haircut(expectedNet));
    fund.create(order);
    bytes32 orderId = order.toId(address(fund));

    // Bond leg: 2% of the shares go to the recipient in mGLOBAL; no USDC is sourced.
    uint256 bondAmount = shares * 200 / BPS;
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);
    assertEq(IERC20(MGLOBAL).balanceOf(bondRecipient), bondAmount, "bond paid in mGLOBAL");
    assertEq(IERC20(USDC).balanceOf(address(fund)), 0, "redemption vault not touched");
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "gated in bond phase");
    assertFalse(fund.holdbackPending(), "no holdback during the bond phase");

    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.HoldbackNotPending.selector);
    fund.confirmHoldback(orderId);

    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    // The payment-role unlock re-arms the order for the redeem leg.
    vm.prank(owner);
    fund.unlockInstantRedeem(orderId);
    assertEq(uint256(fund.state(order)), uint256(State.ACCEPTED), "back to accepted");

    // Redeem leg: the remainder settles instantly against the real Aave redemption vault.
    uint256 expectedRemainderNet =
      _expectedRedeemAssets((shares - bondAmount) * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_AAVE);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);
    assertEq(wrappedShare.balanceOf(address(this)), 0, "all shares burned");
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable");
    assertTrue(fund.holdbackPending(), "holdback pending after the redemption");

    // Partial unlock, then the off-band holdback payment completes the order.
    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.PROCESSING), "partial: back to processing");
    assertGe(amount, order.output * (shares - bondAmount) / shares, "assets >= scaled min output");
    assertApproxEqRel(amount, expectedRemainderNet, 0.001e18, "proceeds on the remainder");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, amount, "USDC received");

    uint256 holdbackAmount = 10_000 * ONE;
    _dealUSDC(address(fund), holdbackAmount);
    vm.prank(owner);
    fund.confirmHoldback(orderId);
    (state, amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, holdbackAmount, "holdback swept");
  }

  function test_Fork_BondedRedeem_AbortAndReissue() public {
    uint256 shares = _doFullDeposit(DEPOSIT_AMOUNT);

    address bondRecipient = makeAddr("bondRecipient");
    vm.prank(MIDAS_DEFAULT_ADMIN);
    IMidasAccessControlFork(MIDAS_ACCESS_CONTROL).grantRole(GREENLISTED_ROLE, bondRecipient);
    vm.prank(owner);
    fund.setBondConfig(BondConfig({amount: 200, recipient: bondRecipient}));

    // Bond leg, then the redeem leg is (hypothetically) permanently stuck: abort.
    uint256 expectedNet = _expectedRedeemAssets(shares * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_AAVE);
    Order memory order = _redeemOrder(shares, _haircut(expectedNet));
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    vm.prank(owner);
    fund.recovering(order);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recoverable at zero balance");

    // Zero-amount terminal recover ends the order and frees the instance.
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, 0, "zero-amount finalization");
    uint256 bondAmount = shares * 200 / BPS;
    assertEq(IERC20(MGLOBAL).balanceOf(bondRecipient), bondAmount, "bond stays forfeited");

    // Reissue the remaining shares as a plain redeem through the existing gates.
    vm.prank(owner);
    fund.removeBondConfig();

    uint256 remainder = shares - bondAmount;
    uint256 expectedRemainderNet =
      _expectedRedeemAssets(remainder * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_AAVE);
    Order memory reissued = Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: remainder,
      output: _haircut(expectedRemainderNet),
      salt: keccak256("fork-reissue")
    });
    fund.create(reissued);
    wrappedShare.approve(address(fund), remainder);
    fund.commit(reissued);
    assertEq(uint256(fund.state(reissued)), uint256(State.UNLOCKING), "proceeds claimable");

    vm.prank(owner);
    fund.confirmHoldback(reissued.toId(address(fund)));
    (state, amount) = fund.unlock(reissued);
    assertEq(uint256(state), uint256(State.ENDED), "reissued redeem ended");
    assertGe(amount, reissued.output, "assets >= min output");
    assertApproxEqRel(amount, expectedRemainderNet, 0.001e18, "proceeds on the remainder");
    assertEq(wrappedShare.balanceOf(address(this)), 0, "all shares settled");
  }

  function test_Fork_BondLeg_RevertsWhenRecipientNotGreenlisted() public {
    uint256 shares = _doFullDeposit(DEPOSIT_AMOUNT);

    // Recipient deliberately NOT greenlisted: the bond transfer must revert inside mGLOBAL.
    address bondRecipient = makeAddr("bondRecipient");
    vm.prank(owner);
    fund.setBondConfig(BondConfig({amount: 200, recipient: bondRecipient}));

    Order memory order = _redeemOrder(
      shares, _haircut(_expectedRedeemAssets(shares * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_AAVE))
    );
    fund.create(order);

    wrappedShare.approve(address(fund), shares);
    vm.expectRevert();
    fund.commit(order);
  }

  function test_Fork_Recovering_OffBandRefund() public {
    // Deposit commit: the USDC leaves the fund via depositRequest, no mGLOBAL minted yet.
    Order memory order = _depositOrder(DEPOSIT_AMOUNT, _haircut(_expectedDepositShares(DEPOSIT_AMOUNT)));
    fund.create(order);
    IERC20(USDC).approve(address(fund), order.input);
    fund.commit(order);

    // Operator escape hatch (the mint request is still PENDING on the Midas side): the
    // deposit is unwound off-band by the Midas admin.
    vm.prank(owner);
    fund.recovering(order);

    // Without the refund the dynamic state falls back to PROCESSING.
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing before refund");

    // Simulate the off-band USDC refund
    _dealUSDC(address(fund), DEPOSIT_AMOUNT);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering once refunded");

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.recover(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertEq(amount, DEPOSIT_AMOUNT, "full input recovered");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, amount, "USDC returned to receiver");
  }

  function test_Fork_SwapperVault_InstantRedeem() public {
    uint256 shares = _doFullDeposit(DEPOSIT_AMOUNT);

    vm.prank(owner);
    fund.setRedemptionVault(REDEMPTION_VAULT_SWAPPER);

    // The swapper vault holds <1 USDC at the pinned block; fund it directly so the
    // instant redemption settles from its own balance instead of the mTBILL swap route.
    _dealUSDC(REDEMPTION_VAULT_SWAPPER, 500_000 * ONE);

    uint256 expectedNet = _expectedRedeemAssets(shares * (BPS - REDEEM_INSTANT_FEE) / BPS, REDEMPTION_VAULT_SWAPPER);
    Order memory order = _redeemOrder(shares, _haircut(expectedNet));
    fund.create(order);

    wrappedShare.approve(address(fund), shares);
    fund.commit(order);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "proceeds claimable while holdback pending");

    vm.prank(owner);
    fund.confirmHoldback(order.toId(address(fund)));
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "still claimable after confirmation");

    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
    (State state, uint256 amount) = fund.unlock(order);
    assertEq(uint256(state), uint256(State.ENDED), "ended");
    assertGe(amount, order.output, "assets >= min output");
    assertApproxEqRel(amount, expectedNet, 0.001e18, "assets match redemption feed minus fee");
    assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore, amount, "USDC received");
  }

  function test_Fork_Create_RevertsWhenNotGreenlisted() public {
    // Fresh wrapper + fund, neither greenlisted by Midas
    WrappedAsset implementation = new WrappedAsset();
    WrappedAsset wrappedShare2 = WrappedAsset(LibClone.deployERC1967(address(implementation)));
    wrappedShare2.initialize(owner, owner, MGLOBAL, "wmGLOBAL2", "Wrapped mGLOBAL 2");

    MidasFund fund2 = MidasFund(
      factory.createFund(owner, address(this), DEPOSIT_VAULT, REDEMPTION_VAULT_AAVE, address(wrappedShare2), USDC)
    );

    Order memory order = _depositOrder(DEPOSIT_AMOUNT, _haircut(_expectedDepositShares(DEPOSIT_AMOUNT)));

    // Fund not greenlisted → NotAllowedByFund
    vm.expectRevert(LibFundsErrors.NotAllowedByFund.selector);
    fund2.create(order);

    // Greenlist only the fund → the wrapper check still fails
    vm.prank(MIDAS_DEFAULT_ADMIN);
    IMidasAccessControlFork(MIDAS_ACCESS_CONTROL).grantRole(GREENLISTED_ROLE, address(fund2));

    vm.expectRevert(LibFundsErrors.WrappedShareNotPermissioned.selector);
    fund2.create(order);
  }

  function test_Fork_TotalAssets() public {
    assertEq(fund.totalAssets(), 0, "totalAssets zero before any deposit");

    _doFullDeposit(DEPOSIT_AMOUNT);

    // totalAssets values the wrapper supply at the redemption-side feed (conservative exit)
    uint256 supply = wrappedShare.totalSupply();
    uint256 redemptionRate = IMidasDataFeed(IMidasVault(REDEMPTION_VAULT_AAVE).mTokenDataFeed()).getDataInBase18();
    uint256 expectedTotalAssets = (supply * redemptionRate / 1e18) / SCALE;

    assertGt(fund.totalAssets(), 0, "totalAssets non-zero");
    assertEq(fund.totalAssets(), expectedTotalAssets, "totalAssets matches supply * redemption rate");
    // Redemption feed (~0.935) prices below the deposit feed (~1.076) → exit value < deposit
    assertLt(fund.totalAssets(), DEPOSIT_AMOUNT, "exit valuation below deposited amount");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTERNAL HELPERS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Sets USDC balance for `to` by writing to the proxy's balance mapping (slot 9).
  function _dealUSDC(address to, uint256 amount) internal {
    bytes32 slot = keccak256(abi.encode(to, uint256(9)));
    vm.store(USDC, slot, bytes32(amount));
  }

  /// @dev Unpauses a fn-paused vault entry point via the impersonated vault admin.
  function _unpauseFn(address vault, bytes4 selector) internal {
    if (IMidasVaultAdminFork(vault).fnPaused(selector)) {
      vm.prank(midasAdmin);
      IMidasVaultAdminFork(vault).unpauseFn(selector);
    }
  }

  /// @dev Expected base-18 mGLOBAL amount minted for a native-decimals USDC deposit,
  ///      priced with the deposit vault's own (higher) mToken feed. USDC is flagged
  ///      stable on the vault, so its rate is a constant 1e18.
  function _expectedDepositShares(uint256 usdcAmount) internal view returns (uint256) {
    uint256 mTokenRate = IMidasDataFeed(IMidasVault(DEPOSIT_VAULT).mTokenDataFeed()).getDataInBase18();
    return (usdcAmount * SCALE) * 1e18 / mTokenRate;
  }

  /// @dev Expected native-decimals USDC amount for a base-18 mGLOBAL redemption,
  ///      priced with the given redemption vault's (lower) mToken feed.
  function _expectedRedeemAssets(uint256 mTokenAmount, address vault) internal view returns (uint256) {
    uint256 mTokenRate = IMidasDataFeed(IMidasVault(vault).mTokenDataFeed()).getDataInBase18();
    return (mTokenAmount * mTokenRate / 1e18) / SCALE;
  }

  /// @dev 0.1% haircut applied to feed-derived outputs so orders clear both the fund's
  ///      5% deviation guard and the Midas minReceiveAmount check despite rounding.
  function _haircut(uint256 amount) internal pure returns (uint256) {
    return amount * 9990 / BPS;
  }

  /// @dev Executes a full request-deposit cycle (create → commit → Midas admin approves the
  ///      mint request at its snapshotted rate → unlock) and returns the wrapped shares received.
  function _doFullDeposit(uint256 depositAmount) internal returns (uint256 shares) {
    Order memory order = _depositOrder(depositAmount, _haircut(_expectedDepositShares(depositAmount)));
    fund.create(order);
    IERC20(USDC).approve(address(fund), order.input);
    fund.commit(order);

    uint256 requestId = fund.activeRequestId();
    (,,,,, uint256 tokenOutRate) = IMidasDepositVault(DEPOSIT_VAULT).mintRequests(requestId);
    vm.prank(midasAdmin);
    IMidasVaultAdminFork(DEPOSIT_VAULT).approveRequest(requestId, tokenOutRate);

    (, shares) = fund.unlock(order);
  }

  function _depositOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.DEPOSIT,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: keccak256("fork-deposit")
    });
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      mode: Mode.REDEEM,
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      salt: keccak256("fork-redeem")
    });
  }
}
