// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WildcatFund} from "src/funds/wildcat/WildcatFund.sol";
import {WildcatFundFactory} from "src/funds/wildcat/WildcatFundFactory.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";
import {IWildcatMarket, WithdrawalBatch} from "src/interfaces/integrations/wildcat/IWildcatMarket.sol";
import {IWildcat4626Wrapper} from "src/interfaces/integrations/wildcat/IWildcat4626Wrapper.sol";

/// @dev Extended interface for the market's OpenTermHooks instance used in fork tests.
interface IOpenTermHooksFork {
  function isKnownLenderOnMarket(address lender, address market) external view returns (bool);
}

/// @dev Fork tests against the live Wintermute Trading USD Coin (wmtUSDC) Wildcat V2 market.
///      Run with: FOUNDRY_PROFILE=ci forge test --match-path test/funds/wildcat/WildcatFund.fork.t.sol
///      (requires ETH_RPC_URL).
contract WildcatFundForkTest is Test {
  using LibOrder for Order;

  // Mainnet addresses
  address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  /// @dev Wintermute Trading USD Coin (wmtUSDC) Wildcat V2 market.
  address internal constant WMT_USDC_MARKET = 0xC9499006a149C553d18171747ED19Aa7C6Dd19E2;
  /// @dev Official Wildcat4626Wrapper for wmtUSDC (deployed via Wildcat4626WrapperFactory).
  address internal constant WMT_USDC_4626_WRAPPER = 0xF65460B84c13eeb911303336Ab0f9D63CC79839f;
  /// @dev The market's OpenTermHooks instance ("Open Term Permissionless"). Its pull role
  ///      provider grants a deposit credential to any non-sanctioned account, so no borrower
  ///      onboarding is required; the enforced constraint is the 1,000 USDC minimum deposit.
  address internal constant WMT_USDC_HOOKS = 0xec6F30250269069B62D7b969a6AF731214D20AF9;

  uint256 internal constant ONE_USDC = 1e6;
  uint256 internal constant RAY = 1e27;

  // WrappedAsset roles
  uint256 internal constant ISSUER_ROLE = 1 << 0;
  uint256 internal constant SENDER_ROLE = 1 << 1;

  WildcatFund internal fund;
  WrappedAsset internal wrappedShare;
  IWildcatMarket internal market;
  IWildcat4626Wrapper internal wrapper;

  address internal owner;
  address internal operator;

  function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC_URL"), 25_451_400);

    owner = makeAddr("owner");
    operator = makeAddr("operator");

    market = IWildcatMarket(WMT_USDC_MARKET);
    wrapper = IWildcat4626Wrapper(WMT_USDC_4626_WRAPPER);

    WrappedAsset implementation = new WrappedAsset();
    address proxy = LibClone.deployERC1967(address(implementation));
    wrappedShare = WrappedAsset(proxy);
    wrappedShare.initialize(owner, owner, WMT_USDC_4626_WRAPPER, "wv-wmtUSDC", "Wrapped v-wmtUSDC");

    WildcatFundFactory factory = new WildcatFundFactory(owner);
    fund = WildcatFund(factory.createFund(owner, address(this), WMT_USDC_4626_WRAPPER, address(wrappedShare)));

    vm.startPrank(owner);
    wrappedShare.grantRoles(address(fund), ISSUER_ROLE);
    wrappedShare.grantRoles(address(this), SENDER_ROLE);
    fund.grantRoles(operator, 1 << 0); // OPERATOR_ROLE
    vm.stopPrank();

    deal(USDC, address(this), 1_000_000 * ONE_USDC);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Fork_Initialization() public view {
    assertEq(fund.asset(), USDC, "asset");
    assertEq(fund.market(), WMT_USDC_MARKET, "market");
    assertEq(fund.wrapper(), WMT_USDC_4626_WRAPPER, "wrapper");
    assertEq(fund.share(), address(wrappedShare), "share");
    assertEq(wrappedShare.decimals(), 6, "decimals");
  }

  function test_Fork_FullDepositLifecycle() public {
    // Above the market's 1,000 USDC minimum deposit
    uint256 input = 100_000 * ONE_USDC;
    uint256 expectedShares = wrapper.convertToShares(input);
    Order memory order = _order(Mode.DEPOSIT, input, expectedShares, bytes32(uint256(1)));

    assertEq(uint256(fund.create(order)), uint256(State.ACCEPTED), "created");

    IERC20(USDC).approve(address(fund), input);
    (State committedState, uint256 committed) = fund.commit(order);
    assertEq(uint256(committedState), uint256(State.PROCESSING), "committed");
    assertEq(committed, input, "committed amount");

    // Deposits are synchronous: immediately unlockable, with the in-flight shares visible
    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking");
    assertApproxEqAbs(fund.pendingDepositShares(), expectedShares, 1, "pending deposit visible");

    (State unlockedState, uint256 shares) = fund.unlock(order);
    assertEq(uint256(unlockedState), uint256(State.ENDED), "ended");
    assertApproxEqAbs(shares, expectedShares, 1, "shares at market rate");
    assertEq(wrappedShare.balanceOf(address(this)), shares, "wrapped shares minted");

    // The fund became a known lender on the market through its first deposit
    assertTrue(
      IOpenTermHooksFork(WMT_USDC_HOOKS).isKnownLenderOnMarket(address(fund), WMT_USDC_MARKET), "fund is known lender"
    );

    // AUM matches the deposited value (1 market token = 1 USDC normalized)
    assertApproxEqAbs(fund.totalAssets(), input, 2, "totalAssets");
  }

  function test_Fork_TotalAssetsAccruesInterest() public {
    uint256 input = 50_000 * ONE_USDC;
    _deposit(input, bytes32(uint256(1)));

    uint256 aumBefore = fund.totalAssets();
    vm.warp(block.timestamp + 30 days);
    assertGt(fund.totalAssets(), aumBefore, "interest accrued to AUM");
  }

  function test_Fork_FullRedeemLifecycle() public {
    uint256 input = 100_000 * ONE_USDC;
    uint256 shares = _deposit(input, bytes32(uint256(1)));

    uint256 expectedAssets = wrapper.convertToAssets(shares);
    Order memory order = _order(Mode.REDEEM, shares, expectedAssets, bytes32(uint256(2)));

    assertEq(uint256(fund.create(order)), uint256(State.ACCEPTED), "created");

    wrappedShare.approve(address(fund), shares);
    (State committedState,) = fund.commit(order);
    assertEq(uint256(committedState), uint256(State.PROCESSING), "committed");

    uint32 expiry = fund.currentBatchExpiry();
    assertEq(expiry, uint32(block.timestamp + market.withdrawalBatchDuration()), "batch expiry");

    // The in-flight claim (excluded from totalAssets) is visible via pendingRedeemAssets
    assertApproxEqAbs(fund.pendingRedeemAssets(), expectedAssets, 2, "pending redeem visible");

    // Before expiry the order is not claimable
    assertEq(uint256(fund.state(order)), uint256(State.PROCESSING), "processing before expiry");
    vm.expectRevert(abi.encodeWithSelector(LibFundsErrors.InvalidState.selector, State.PROCESSING));
    fund.unlock(order);

    vm.warp(uint256(expiry) + 1);

    // Ensure the market has enough reserves to pay the batch in full (donations count as liquidity)
    deal(USDC, WMT_USDC_MARKET, IERC20(USDC).balanceOf(WMT_USDC_MARKET) + 2_000_000 * ONE_USDC);

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking after expiry");

    uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
    (State finalState, uint256 assetsOut) = fund.unlock(order);

    assertEq(uint256(finalState), uint256(State.ENDED), "ended");
    assertEq(IERC20(USDC).balanceOf(address(this)) - balanceBefore, assetsOut, "receiver paid");
    // Queued amount keeps accruing interest until the batch is paid, so the payout is at least
    // the value at commit time.
    assertGe(assetsOut, expectedAssets, "payout >= value at commit");
    assertEq(fund.pendingRedeemAssets(), 0, "nothing pending after settlement");
  }

  function test_Fork_Redeem_SweepsThirdPartyExecutedWithdrawals() public {
    uint256 input = 10_000 * ONE_USDC;
    uint256 shares = _deposit(input, bytes32(uint256(1)));

    Order memory order = _order(Mode.REDEEM, shares, wrapper.convertToAssets(shares), bytes32(uint256(2)));
    fund.create(order);
    wrappedShare.approve(address(fund), shares);
    fund.commit(order);

    uint32 expiry = fund.currentBatchExpiry();
    vm.warp(uint256(expiry) + 1);
    deal(USDC, WMT_USDC_MARKET, IERC20(USDC).balanceOf(WMT_USDC_MARKET) + 1_000_000 * ONE_USDC);

    // Anyone can execute the withdrawal, pushing USDC into the fund
    market.executeWithdrawal(address(fund), expiry);
    assertGt(IERC20(USDC).balanceOf(address(fund)), 0, "usdc pushed to fund");

    assertEq(uint256(fund.state(order)), uint256(State.UNLOCKING), "unlocking from pushed balance");
    uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
    (State finalState, uint256 assetsOut) = fund.unlock(order);
    assertEq(uint256(finalState), uint256(State.ENDED), "ended");
    assertGt(assetsOut, 0, "swept");
    assertEq(IERC20(USDC).balanceOf(address(this)) - balanceBefore, assetsOut, "receiver got swept funds");
  }

  function test_Fork_Commit_RevertWhen_BelowMinimumDeposit() public {
    // The market's hooks enforce a 1,000 USDC minimum deposit; the fund does not pre-check
    // hook-level policies, so the commit reverts and the order can be canceled.
    uint256 input = 500 * ONE_USDC;
    Order memory order = _order(Mode.DEPOSIT, input, wrapper.convertToShares(input), bytes32(uint256(1)));
    fund.create(order);
    IERC20(USDC).approve(address(fund), input);

    // OpenTermHooks reverts DepositBelowMinimum() inside market.deposit
    vm.expectRevert();
    fund.commit(order);

    // The order is not stuck: it can be canceled
    assertEq(uint256(fund.cancel(order)), uint256(State.EMPTY), "canceled");
  }

  function test_Fork_Create_RevertWhen_DepositCapExceeded() public {
    uint256 tooMuch = market.maximumDeposit() + ONE_USDC;
    Order memory order = _order(Mode.DEPOSIT, tooMuch, wrapper.convertToShares(tooMuch), bytes32(uint256(1)));
    vm.expectRevert(LibFundsErrors.DepositCapExceeded.selector);
    fund.create(order);
  }

  function test_Fork_Create_RevertWhen_OutputTooLow() public {
    uint256 input = 10_000 * ONE_USDC;
    uint256 expectedShares = wrapper.convertToShares(input);
    Order memory order = _order(Mode.DEPOSIT, input, expectedShares * 90 / 100, bytes32(uint256(1)));
    vm.expectRevert(LibFundsErrors.InvalidOutput.selector);
    fund.create(order);
  }

  function test_Fork_MultipleSequentialOrders() public {
    uint256 sharesA = _deposit(50_000 * ONE_USDC, bytes32(uint256(1)));
    uint256 sharesB = _deposit(25_000 * ONE_USDC, bytes32(uint256(2)));
    assertEq(wrappedShare.balanceOf(address(this)), sharesA + sharesB, "cumulative shares");
    assertApproxEqAbs(fund.totalAssets(), 75_000 * ONE_USDC, 3, "aggregate AUM");
  }

  function test_Fork_SharedWrappedAsset_AcrossFunds() public {
    // A second fund instance sharing the same WrappedAsset (multi-settlement pattern)
    WildcatFundFactory factory = new WildcatFundFactory(owner);
    WildcatFund fundB =
      WildcatFund(factory.createFund(owner, address(this), WMT_USDC_4626_WRAPPER, address(wrappedShare)));
    vm.prank(owner);
    wrappedShare.grantRoles(address(fundB), ISSUER_ROLE);

    _deposit(50_000 * ONE_USDC, bytes32(uint256(1)));

    uint256 inputB = 25_000 * ONE_USDC;
    Order memory orderB = _order(Mode.DEPOSIT, inputB, wrapper.convertToShares(inputB), bytes32(uint256(2)));
    fundB.create(orderB);
    IERC20(USDC).approve(address(fundB), inputB);
    fundB.commit(orderB);
    fundB.unlock(orderB);

    // Both funds report the same wrapper-wide aggregate AUM
    assertApproxEqAbs(fund.totalAssets(), 75_000 * ONE_USDC, 3, "fund A aggregate AUM");
    assertEq(fund.totalAssets(), fundB.totalAssets(), "shared total assets");
  }

  function test_Fork_RecoverAlwaysReverts() public {
    Order memory order = _order(Mode.DEPOSIT, ONE_USDC, ONE_USDC, bytes32(uint256(1)));
    vm.expectRevert(LibFundsErrors.RecoverNotSupported.selector);
    fund.recover(order);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _order(Mode mode, uint256 input, uint256 output, bytes32 salt) internal view returns (Order memory) {
    return Order({mode: mode, owner: address(this), receiver: address(this), input: input, output: output, salt: salt});
  }

  function _deposit(uint256 input, bytes32 salt) internal returns (uint256 shares) {
    Order memory order = _order(Mode.DEPOSIT, input, wrapper.convertToShares(input), salt);
    fund.create(order);
    IERC20(USDC).approve(address(fund), input);
    fund.commit(order);
    (, shares) = fund.unlock(order);
  }
}
