// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MidasFund} from "src/funds/midas/MidasFund.sol";
import {MidasFundFactory} from "src/funds/midas/MidasFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {MidasRequestStatus} from "src/interfaces/integrations/midas/IMidasVault.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";

import {MockERC20} from "../../mock/MockERC20.sol";
import {MockMidasDataFeed} from "../../mock/funds/midas/MockMidasDataFeed.sol";
import {MockMidasAccessControl} from "../../mock/funds/midas/MockMidasAccessControl.sol";
import {MockMidasDepositVault} from "../../mock/funds/midas/MockMidasDepositVault.sol";
import {MockMidasRedemptionVault} from "../../mock/funds/midas/MockMidasRedemptionVault.sol";
import {MidasFundHandler} from "test/mock/funds/midas/MidasFundHandler.sol";

contract MidasFundFuzzTest is Test {
  using LibOrder for Order;

  uint256 private constant ONE_USDC = 1e6;
  uint256 private constant ONE_MTOKEN = 1e18;
  uint256 private constant ASSET_SCALE = 1e12;

  // WrappedAsset roles
  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  MidasFundFactory public factory;
  MidasFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public mGlobal;
  MockMidasAccessControl public midasAcl;
  MockMidasDataFeed public depositMTokenFeed;
  MockMidasDataFeed public depositAssetFeed;
  MockMidasDataFeed public redemptionMTokenFeed;
  MockMidasDataFeed public redemptionAssetFeed;
  MockMidasDepositVault public depositVault;
  MockMidasRedemptionVault public redemptionVault;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    mGlobal = new MockERC20("Midas Global", "mGLOBAL", 18);
    midasAcl = new MockMidasAccessControl();
    depositMTokenFeed = new MockMidasDataFeed();
    depositAssetFeed = new MockMidasDataFeed();
    redemptionMTokenFeed = new MockMidasDataFeed();
    redemptionAssetFeed = new MockMidasDataFeed();

    depositVault = new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    redemptionVault = new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    depositVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);
    redemptionVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(mGlobal), "wmGLOBAL", "Wrapped mGLOBAL");

    factory = new MidasFundFactory(owner);
    address fundAddr = factory.createFund(
      owner, address(this), address(depositVault), address(redemptionVault), address(wrappedShare), address(usdc)
    );
    fund = MidasFund(fundAddr);

    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               FUZZ: DEPOSIT REQUEST LIFECYCLE              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_DepositRequestLifecycle_Succeeds(uint96 input) public {
    uint256 inputAmount = bound(uint256(input), 1, type(uint96).max);
    // At 1:1 rates the vault mints inputAmount * 1e12 mToken (base-18) for inputAmount USDC.
    uint256 expectedMToken = inputAmount * ASSET_SCALE;

    Order memory order = _depositOrder(inputAmount, expectedMToken);
    fund.create(order);

    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    // Deposits settle asynchronously: PROCESSING until the Midas admin approves the request.
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing while request pending");
    uint256 requestId = fund.activeRequestId();
    assertEq(requestId, 1, "request id recorded");

    // The holdback gate does not apply to deposit orders.
    assertFalse(fund.holdbackPending(), "no holdback gate on deposits");
    vm.prank(owner);
    vm.expectRevert(LibFundsErrors.HoldbackNotPending.selector);
    fund.confirmHoldback(order.toId(address(fund)));

    // Approval mints the mToken directly to the fund.
    depositVault.approveDepositRequest(requestId);
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after approval");

    (State newState, uint256 amount) = fund.unlock(order);

    assertEq(amount, expectedMToken, "amount");
    assertEq(wrappedShare.balanceOf(address(this)), expectedMToken, "wrapper minted");
    assertEq(mGlobal.balanceOf(address(wrappedShare)), expectedMToken, "mToken in wrapper");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  function testFuzz_DepositAirdrop_SweptAfterApproval(uint96 input, uint96 airdropSeed) public {
    uint256 inputAmount = bound(uint256(input), 1, type(uint96).max);
    uint256 airdropAmount = bound(uint256(airdropSeed), 1, type(uint96).max);
    uint256 expectedMToken = inputAmount * ASSET_SCALE;

    Order memory order = _depositOrder(inputAmount, expectedMToken);
    fund.create(order);
    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    // An off-band mToken airdrop alone must not unlock the order while the request is pending,
    // even if it covers the expected output.
    mGlobal.mint(address(fund), airdropAmount);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still gated by pending request");

    depositVault.approveDepositRequest(fund.activeRequestId());

    (, uint256 amount) = fund.unlock(order);
    assertEq(amount, expectedMToken + airdropAmount, "approved mint + airdrop wrapped");
    assertEq(wrappedShare.balanceOf(address(this)), expectedMToken + airdropAmount, "wrapper covers full balance");
  }

  function testFuzz_DepositRequestReject_Recovers(uint96 input) public {
    uint256 inputAmount = bound(uint256(input), 1, type(uint96).max);

    Order memory order = _depositOrder(inputAmount, inputAmount * ASSET_SCALE);
    fund.create(order);
    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);

    // Rejection alone does not refund on-chain; the order stays PROCESSING until refunded.
    depositVault.rejectDepositRequest(fund.activeRequestId());
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing before refund");

    // The Midas admin returns the pulled USDC off-band.
    depositVault.withdrawToken(address(usdc), address(fund), inputAmount);
    assertEq(uint256(fund.state(order)), uint256(State.RECOVERING), "recovering after refund");

    (State newState, uint256 amount) = fund.recover(order);
    assertEq(amount, inputAmount, "amount");
    assertEq(usdc.balanceOf(address(this)), inputAmount, "usdc returned");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             FUZZ: REDEEM HOLDBACK LIFECYCLE                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_RedeemHoldbackLifecycle_Succeeds(uint96 input) public {
    uint256 inputUsdc = bound(uint256(input), 1, type(uint96).max);
    uint256 mTokenAmount = inputUsdc * ASSET_SCALE;

    _depositAndUnlock(inputUsdc);

    Order memory order = _redeemOrder(mTokenAmount, inputUsdc);
    fund.create(order);
    wrappedShare.approve(address(fund), mTokenAmount);
    fund.commit(order);

    // Every redeem stays PROCESSING until the holdback payment is confirmed.
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing until confirmed");
    assertTrue(fund.holdbackPending(), "holdback pending");

    vm.prank(owner);
    fund.confirmHoldback(order.toId(address(fund)));

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after confirmation");

    (State newState, uint256 amount) = fund.unlock(order);

    assertEq(amount, inputUsdc, "amount");
    assertEq(usdc.balanceOf(address(this)), inputUsdc, "usdc received");
    assertEq(wrappedShare.totalSupply(), 0, "wrapper supply burned");
    assertEq(uint256(newState), uint256(State.ENDED), "ended");
  }

  function testFuzz_RedeemHoldback_SweepsPayment(uint96 input, uint96 holdbackSeed) public {
    uint256 inputUsdc = bound(uint256(input), 1, type(uint96).max);
    uint256 holdbackAmount = bound(uint256(holdbackSeed), 1, type(uint96).max);
    uint256 mTokenAmount = inputUsdc * ASSET_SCALE;

    _depositAndUnlock(inputUsdc);

    Order memory order = _redeemOrder(mTokenAmount, inputUsdc);
    fund.create(order);
    wrappedShare.approve(address(fund), mTokenAmount);
    fund.commit(order);

    // The off-band holdback payment arrives; the order remains gated until confirmed.
    usdc.mint(address(fund), holdbackAmount);
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "still gated");

    vm.prank(owner);
    fund.confirmHoldback(order.toId(address(fund)));

    (, uint256 amount) = fund.unlock(order);
    assertEq(amount, inputUsdc + holdbackAmount, "full balance swept");
    assertEq(usdc.balanceOf(address(this)), inputUsdc + holdbackAmount, "proceeds + holdback received");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                FUZZ: OUTPUT DEVIATION BOUNDS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_Create_AcceptsOutputWithinMaxDeviation(uint96 input, uint16 deviationBps) public {
    uint256 inputAmount = bound(uint256(input), 1, type(uint96).max);
    uint256 bps = bound(uint256(deviationBps), 0, 500);
    // expectedOutput = inputAmount * 1e12 is always divisible by 10_000, so the
    // deviation math below is exact.
    uint256 expectedOutput = inputAmount * ASSET_SCALE;
    uint256 output = expectedOutput * (10_000 - bps) / 10_000;

    Order memory order = _depositOrder(inputAmount, output);
    State state = fund.create(order);
    assertEq(uint256(state), uint256(State.ACCEPTED), "accepted within deviation");
  }

  function testFuzz_Create_RejectsOutputBeyondMaxDeviation(uint96 input, uint16 deviationBps) public {
    uint256 inputAmount = bound(uint256(input), 1, type(uint96).max);
    uint256 bps = bound(uint256(deviationBps), 501, 10_000);
    uint256 expectedOutput = inputAmount * ASSET_SCALE;
    uint256 output = expectedOutput * (10_000 - bps) / 10_000;

    Order memory order = _depositOrder(inputAmount, output);
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                FUZZ: TOTAL ASSETS VARYING RATE             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_TotalAssets_VaryingMTokenRate(uint64 rawRate) public {
    uint256 rate = bound(uint256(rawRate), 0.5e18, 2e18);

    _depositAndUnlock(ONE_USDC);
    uint256 supply = wrappedShare.totalSupply();
    assertEq(supply, ONE_MTOKEN, "supply");

    redemptionMTokenFeed.setRate(rate);
    uint256 expected = supply * rate / 1e18 / ASSET_SCALE;
    assertEq(fund.totalAssets(), expected, "totalAssets");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              FUZZ: ARCHIVED ORDER REMAINS ENDED            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_ArchivedEndedOrderRemainsEnded(uint96 input, uint96 nextInput) public {
    uint256 maxAmount = type(uint96).max;
    uint256 inputAmount = bound(uint256(input), 1, maxAmount - 1);
    uint256 nextInputAmount = bound(uint256(nextInput), 1, maxAmount);
    if (nextInputAmount == inputAmount) nextInputAmount = inputAmount + 1;

    Order memory order = _depositOrder(inputAmount, inputAmount * ASSET_SCALE);
    fund.create(order);
    usdc.mint(address(this), inputAmount);
    usdc.approve(address(fund), inputAmount);
    fund.commit(order);
    depositVault.approveDepositRequest(fund.activeRequestId());
    fund.unlock(order);

    Order memory nextOrder = _depositOrderWithSalt(nextInputAmount, nextInputAmount * ASSET_SCALE, keccak256("next"));
    fund.create(nextOrder);

    assertEq(uint256(fund.state(order)), uint256(State.ENDED), "archived order ended");
    assertEq(uint256(fund.state(nextOrder)), uint256(State.ACCEPTED), "next order accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _depositOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return _depositOrderWithSalt(input, output, keccak256("deposit"));
  }

  function _depositOrderWithSalt(uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return Order({
      owner: address(this), receiver: address(this), input: input, output: output, mode: Mode.DEPOSIT, salt: salt
    });
  }

  function _redeemOrder(uint256 input, uint256 output) internal view returns (Order memory) {
    return Order({
      owner: address(this),
      receiver: address(this),
      input: input,
      output: output,
      mode: Mode.REDEEM,
      salt: keccak256("redeem")
    });
  }

  function _depositAndUnlock(uint256 usdcAmount) internal {
    Order memory order = _depositOrderWithSalt(usdcAmount, usdcAmount * ASSET_SCALE, keccak256("bootstrap"));
    fund.create(order);
    usdc.mint(address(this), usdcAmount);
    usdc.approve(address(fund), usdcAmount);
    fund.commit(order);
    depositVault.approveDepositRequest(fund.activeRequestId());
    fund.unlock(order);
  }
}

contract MidasFundInvariantTest is StdInvariant, Test {
  uint256 private constant OPERATOR_ROLE = 1 << 0;
  uint256 private constant HOLDBACK_ROLE = 1 << 2;

  uint256 private constant ISSUER_ROLE = 1 << 0;
  uint256 private constant SENDER_ROLE = 1 << 1;

  uint256 private constant ASSET_SCALE = 1e12;

  MidasFundFactory public factory;
  MidasFund public fund;
  WrappedAsset public wrappedShare;
  MockERC20 public usdc;
  MockERC20 public mGlobal;
  MockMidasAccessControl public midasAcl;
  MockMidasDataFeed public depositMTokenFeed;
  MockMidasDataFeed public depositAssetFeed;
  MockMidasDataFeed public redemptionMTokenFeed;
  MockMidasDataFeed public redemptionAssetFeed;
  MockMidasDepositVault public depositVault;
  MockMidasRedemptionVault public redemptionVault;

  MidasFundHandler public handler;

  address public owner;

  function setUp() public {
    owner = makeAddr("owner");

    usdc = new MockERC20("USD Coin", "USDC", 6);
    mGlobal = new MockERC20("Midas Global", "mGLOBAL", 18);
    midasAcl = new MockMidasAccessControl();
    depositMTokenFeed = new MockMidasDataFeed();
    depositAssetFeed = new MockMidasDataFeed();
    redemptionMTokenFeed = new MockMidasDataFeed();
    redemptionAssetFeed = new MockMidasDataFeed();

    depositVault = new MockMidasDepositVault(address(mGlobal), address(depositMTokenFeed), address(midasAcl));
    redemptionVault = new MockMidasRedemptionVault(address(mGlobal), address(redemptionMTokenFeed), address(midasAcl));
    depositVault.setTokenConfig(address(usdc), address(depositAssetFeed), 0, type(uint256).max, true);
    redemptionVault.setTokenConfig(address(usdc), address(redemptionAssetFeed), 0, type(uint256).max, true);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    vm.prank(owner);
    wrappedShare.initialize(owner, owner, address(mGlobal), "wmGLOBAL", "Wrapped mGLOBAL");

    handler = new MidasFundHandler();

    factory = new MidasFundFactory(owner);
    address fundAddr = factory.createFund(
      owner, address(handler), address(depositVault), address(redemptionVault), address(wrappedShare), address(usdc)
    );
    fund = MidasFund(fundAddr);

    vm.prank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    vm.prank(owner);
    wrappedShare.grantRoles(address(handler), SENDER_ROLE);

    vm.prank(owner);
    fund.grantRoles(address(handler), OPERATOR_ROLE | HOLDBACK_ROLE);

    handler.initialize(fund, usdc, mGlobal, wrappedShare, depositVault, redemptionVault);

    bytes4[] memory selectors = new bytes4[](14);
    selectors[0] = handler.act_createDeposit.selector;
    selectors[1] = handler.act_createRedeem.selector;
    selectors[2] = handler.act_cancel.selector;
    selectors[3] = handler.act_commit.selector;
    selectors[4] = handler.act_approveRequest.selector;
    selectors[5] = handler.act_rejectRequest.selector;
    selectors[6] = handler.act_refund.selector;
    selectors[7] = handler.act_resolve.selector;
    selectors[8] = handler.act_recovering.selector;
    selectors[9] = handler.act_cancelRecovering.selector;
    selectors[10] = handler.act_unlock.selector;
    selectors[11] = handler.act_recover.selector;
    selectors[12] = handler.act_payHoldback.selector;
    selectors[13] = handler.act_confirmHoldback.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  function invariant_FundDoesNotHoldWrappedShares() public view {
    assertEq(wrappedShare.balanceOf(address(fund)), 0, "fund holds wrappedShare");
  }

  function invariant_WrappedShareSupplyMatchesUnderlying() public view {
    assertEq(wrappedShare.totalSupply(), mGlobal.balanceOf(address(wrappedShare)), "wShare supply mismatch");
  }

  function invariant_TotalAssetsConsistent() public view {
    // Rates are fixed at 1e18 and the asset is stable, so:
    // totalAssets = supply * 1e18 / 1e18 / 1e12
    uint256 supply = wrappedShare.totalSupply();
    assertEq(fund.totalAssets(), supply / ASSET_SCALE, "totalAssets mismatch");
  }

  function invariant_HoldbackGateBlocksUnlocking() public view {
    // A redeem order awaiting its holdback confirmation must never report UNLOCKING
    // (deposits never have a pending holdback: they are marked paid at creation).
    if (!fund.holdbackPending()) return;
    Order memory order = handler.getOrder();
    assertTrue(uint256(fund.state(order)) != uint256(State.UNLOCKING), "gated order reports UNLOCKING");
  }

  function invariant_PendingDepositRequestBlocksUnlocking() public view {
    // A committed deposit whose Midas mint request is still PENDING must never report
    // UNLOCKING or RECOVERING, whatever the fund's token balances are.
    if (handler.internalState() != State.PROCESSING) return;
    Order memory order = handler.getOrder();
    if (order.mode != Mode.DEPOSIT) return;
    (,, MidasRequestStatus status,,,) = depositVault.mintRequests(handler.requestId());
    if (status != MidasRequestStatus.PENDING) return;
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "pending request not PROCESSING");
  }

  function invariant_StateMatchesModel() public view {
    State stage = handler.internalState();
    if (stage == State.EMPTY) return;

    Order memory order = handler.getOrder();
    State actual = fund.state(order);

    if (stage == State.ACCEPTED) {
      assertEq(uint256(actual), uint256(State.ACCEPTED), "accepted");
      return;
    }

    if (stage == State.ENDED) {
      assertEq(uint256(actual), uint256(State.ENDED), "ended");
      return;
    }

    if (stage == State.PROCESSING) {
      // Dynamic checks may already report UNLOCKING (deposit: mint request approved;
      // redeem: output delivered and holdback confirmed) or RECOVERING (rejected
      // deposit request refunded off-band).
      assertTrue(
        uint256(actual) == uint256(State.PROCESSING) || uint256(actual) == uint256(State.UNLOCKING)
          || uint256(actual) == uint256(State.RECOVERING),
        "processing, unlocking or recovering"
      );
      return;
    }

    if (stage == State.RECOVERING) {
      // Falls back to PROCESSING while the refund has not covered the effective input.
      assertTrue(
        uint256(actual) == uint256(State.RECOVERING) || uint256(actual) == uint256(State.PROCESSING),
        "recovering or processing"
      );
      return;
    }
  }
}
