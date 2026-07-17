// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {RetargetterBaseTest} from "./RetargetterBase.t.sol";
import {IRetargetter} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibRequestErrors} from "src/libs/request/LibRequestErrors.sol";
import {LibFundsErrors} from "src/libs/funds/LibFundsErrors.sol";
import {Order, Mode, LibOrder} from "src/libs/funds/Order.sol";
import {RebalancingOperationType} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {IRequest} from "src/interfaces/request/IRequest.sol";
import {ITokenController} from "src/interfaces/request/ITokenController.sol";
import {IVaultController} from "src/interfaces/request/IVaultController.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

/// @title RetargetterAsyncTest
/// @notice Full ASYNC integration tests for the Retargetter: happy paths in both directions
///         (events and exact amounts), the loan clock, order wrappers, repayment and
///         resolution gates, and adversarial flows.
contract RetargetterAsyncTest is RetargetterBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     ASYNC UP HAPPY PATH                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Full LTV-up flow with every mirror event asserted and the makers redeeming
  ///         their principal and yield tokens against the Request after resolution.
  function test_async_upHappyPath_eventsAmountsAndRedemption() public {
    _seedPosition(10_000e18, 5_000e18);

    // Start: the request address is unknown before the call, skip its topic
    vm.expectEmit(true, false, true, true, address(retargetter));
    emit IRetargetter.RetargettingStarted(address(positionManager), address(0), address(fund), 6_000e18, 100);
    address request = _startAsync(6_000e18, 100);

    // Consume a 1% offer in full
    Offer memory offer = _createOffer(6_000e18, 60e18);
    bytes memory signature = _signOffer(offer, request);
    vm.prank(maker.addr);
    debtToken.approve(request, 6_000e18);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.OfferConsumed(request, maker.addr, 6_000e18, 60e18);
    vm.prank(consumer);
    retargetter.consume(offer, signature, 6_000e18);

    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestFundsPulled(request, 6_000e18);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(6_000e18);
    assertEq(debtToken.balanceOf(address(retargetter)), 6_000e18, "pulled principal");

    // Subscribe the principal into the fund
    Order memory order = _order(Mode.DEPOSIT, 6_000e18, 6_000e18, bytes32(uint256(1)));
    vm.startPrank(rebalancer);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.OrderCreated(address(fund), order);
    retargetter.create(order);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.OrderCommitted(address(fund), order);
    retargetter.commit();
    vm.stopPrank();
    assertEq(debtToken.allowance(address(retargetter), address(fund)), 0, "commit approval scrubbed");

    vm.warp(block.timestamp + 2 days);
    fund.settle();

    vm.expectEmit(address(retargetter));
    emit IRetargetter.OrderUnlocked(address(fund), order);
    vm.prank(rebalancer);
    uint256 shares = retargetter.unlock();
    assertEq(shares, 6_000e18, "shares out");

    // Two days elapsed with a one-day tick and a ten-hour threshold: two ticks owed
    uint256 expectedOwed = 6_000e18 + _ceilDiv(uint256(60e18) * 2 days, 365 days);
    assertEq(retargetter.owed(), expectedOwed, "owed after two ticks");

    // Tail in one transaction: supply everything, borrow the owed amount, repay, resolve
    vm.startPrank(rebalancer);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.Rebalanced(address(positionManager), 6_000e18, 0);
    retargetter.rebalance(
      _rebalancingData2(
        MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL, RebalancingOperationType.BORROW, expectedOwed
      )
    );
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestRepaid(request, expectedOwed, expectedOwed);
    assertEq(retargetter.repay(), expectedOwed, "repaid exactly the owed amount");
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RetargettingResolved(address(positionManager), request);
    retargetter.resolve();
    vm.stopPrank();

    assertFalse(retargetter.isActive(), "resolved");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "zero debt residual");
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "zero collateral residual");
    assertTrue(IRequest(request).isRepaid(), "request repaid");
    assertEq(debtToken.balanceOf(request), expectedOwed, "request holds the owed amount");
    assertLe(_currentLtv(), POSITION_MANAGER_LTV, "at or below target");

    // The maker redeems its principal and yield tokens against the Request directly
    {
      (uint128 ptBalance, uint128 ytBalance) = ITokenController(request).balancesOf(maker.addr);
      assertEq(uint256(ptBalance), 6_000e18, "maker principal tokens");
      assertEq(uint256(ytBalance), 60e18, "maker yield tokens");
      uint256 makerBalanceBefore = debtToken.balanceOf(maker.addr);
      vm.prank(maker.addr);
      (,, uint256 pAssets, uint256 yAssets) = IVaultController(request).burnAll(maker.addr, maker.addr);
      assertEq(pAssets, 6_000e18, "principal redeemed one to one");
      assertEq(yAssets, expectedOwed - 6_000e18, "yield redeems the excess");
      assertEq(debtToken.balanceOf(maker.addr), makerBalanceBefore + expectedOwed, "maker made whole");
      (uint128 ptSupply, uint128 ytSupply) = ITokenController(request).totalSupplies();
      assertEq(uint256(ptSupply) + uint256(ytSupply), 0, "supplies burned");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ASYNC DOWN HAPPY PATH                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Full LTV-down flow: repay and withdraw, redeem the freed collateral, repay the
  ///         Request from the proceeds and fold the surplus back into the position debt.
  function test_async_downHappyPath_exactOwedAndSurplusFold() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    // The withdraw leg extracts slightly more than the repay leg (yield coverage), so widen
    // the position manager's rebalance loss tolerance for this operation
    vm.prank(owner);
    positionManager.setRebalanceConfig(200, 0);

    // Zero estimates: cap = (debt - target * collateral) / (1 - target), plus the 1% buffer
    uint256 expectedCap = (uint256(2_000e18) * WAD / 0.7e18) * 10_100 / 10_000;
    assertEq(retargetter.maxPrincipal(address(positionManager)), expectedCap, "down principal cap");

    address request = _startAsync(2_857e18, 100);
    _consume(request, 2_857e18, 28e18, 2_857e18);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(2_857e18);

    // Repay part of the debt and free a bit more collateral than the bridge principal
    vm.prank(rebalancer);
    retargetter.rebalance(
      _rebalancingData2(
        0, 2_857e18, RebalancingOperationType.REPAY, 2_857e18, RebalancingOperationType.WITHDRAW, 2_900e18
      )
    );
    assertEq(collateralToken.balanceOf(address(retargetter)), 2_900e18, "freed collateral");

    // Redeem the freed collateral shares through the fund
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.REDEEM, 2_900e18, 2_900e18, bytes32(uint256(2))));
    retargetter.commit();
    vm.stopPrank();
    assertEq(collateralToken.allowance(address(retargetter), address(fund)), 0, "commit approval scrubbed");

    vm.warp(block.timestamp + 3 days);
    fund.settle();
    vm.prank(rebalancer);
    uint256 proceeds = retargetter.unlock();
    assertEq(proceeds, 2_900e18, "redemption proceeds");

    // Three days elapsed with a one-day tick and a ten-hour threshold: three ticks owed
    uint256 expectedOwed = 2_857e18 + _ceilDiv(uint256(28e18) * 3 days, 365 days);
    assertEq(retargetter.owed(), expectedOwed, "owed after three ticks");

    vm.startPrank(rebalancer);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestRepaid(request, expectedOwed, expectedOwed);
    retargetter.repay();

    // Fold the entire surplus into the position debt: below target is always allowed
    assertEq(debtToken.balanceOf(address(retargetter)), 2_900e18 - expectedOwed, "surplus before fold");
    retargetter.rebalance(_rebalancingData(0, MAX_SENTINEL, RebalancingOperationType.REPAY, MAX_SENTINEL));

    vm.expectEmit(address(retargetter));
    emit IRetargetter.RetargettingResolved(address(positionManager), request);
    retargetter.resolve();
    vm.stopPrank();

    assertFalse(retargetter.isActive(), "resolved");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "zero debt residual");
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "zero collateral residual");
    assertTrue(IRequest(request).isRepaid(), "request repaid");
    assertEq(debtToken.balanceOf(request), expectedOwed, "request holds the owed amount");
    // The surplus fold lands the aggregate at or below the new target despite three days of
    // interest accrual on the remaining market debt
    assertLe(_currentLtv(), 0.3e18, "at or below the new target");
    assertGt(_currentLtv(), 0.29e18, "position still levered");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         LOAN CLOCK                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The loan clock starts at the first consume, not at start, and later consumes
  ///         accrue from the same origin.
  function test_async_loanClock_startsAtFirstConsumeAndNeverResets() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    (,,, uint40 startedAt,,,,) = retargetter.operation();
    assertEq(uint256(startedAt), 0, "clock unset before the first consume");

    vm.warp(block.timestamp + 5 days);
    _consume(request, 3_000e18, 30e18, 3_000e18);
    (,,, startedAt,,,,) = retargetter.operation();
    assertEq(uint256(startedAt), block.timestamp, "first consume starts the clock");
    uint256 clockOrigin = uint256(startedAt);

    // A second consume inside the consumption window grows the supplies but does not reset
    // the clock
    vm.warp(block.timestamp + 5 hours);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    (,,, startedAt,,,,) = retargetter.operation();
    assertEq(uint256(startedAt), clockOrigin, "second consume keeps the origin");

    // Two days elapsed: paidTicks = floor((2 days + 1 day - 10 hours) / 1 day) = 2
    vm.warp(clockOrigin + 2 days);
    uint256 expectedOwed = 4_000e18 + _ceilDiv(uint256(40e18) * 2 days, 365 days);
    assertEq(retargetter.owed(), expectedOwed, "owed accrues both supplies from the origin");
    assertEq(
      retargetter.owed(),
      retargetterQuoter.repaymentOwed(
        4_000e18, 40e18, 2 days, DEFAULT_TICK_DURATION, DEFAULT_TICK_THRESHOLD, DEFAULT_HORIZON
      ),
      "owed matches the quoter on a two-day elapsed duration"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONSUMPTION WINDOW                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Consumption stays open through the tick threshold and closes right after, with
  ///         no owner bypass: late capital would be overpaid from the loan clock origin.
  function test_consume_windowClosesAtTickThreshold() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    uint256 origin = block.timestamp;

    // Still open exactly at the threshold boundary
    vm.warp(origin + DEFAULT_TICK_THRESHOLD);
    _consume(request, 1_000e18, 10e18, 1_000e18);

    // Closed one second past it; the gate fires before the Request is ever called, so the
    // offer needs no signature
    vm.warp(origin + DEFAULT_TICK_THRESHOLD + 1);
    Offer memory offer = _createOffer(1_000e18, 10e18);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.consume(offer, "", 1_000e18);

    // The owner has no bypass
    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.consume(offer, "", 1_000e18);
  }

  /// @notice The window is measured from the loan clock origin, not the operation start, so a
  ///         late first consume (within the deadline-buffer bound) simply starts its window
  ///         late.
  function test_consume_windowStartsAtFirstConsumeNotOperationStart() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);

    // Days between start and the first consume: fine, the window is not running yet
    vm.warp(block.timestamp + 3 days);
    _consume(request, 1_000e18, 10e18, 1_000e18);

    // And from that first consume the threshold applies
    vm.warp(block.timestamp + DEFAULT_TICK_THRESHOLD + 1);
    Offer memory offer = _createOffer(1_000e18, 10e18);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.consume(offer, "", 1_000e18);
  }

  /// @notice The loan clock can only start while at least MIN_DEADLINE_BUFFER (80 days)
  ///         remains before the Request's 90-day deadline: the first commitment is accepted
  ///         up to 10 days after the operation start and rejected past that, so a late clock
  ///         start cannot erode the settlement buffer the deadline is sized for.
  function test_consume_clockStartAtDeadlineBufferBoundary() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    uint256 operationStart = block.timestamp;

    // Exactly 80 days remain before the deadline: the clock may still start
    vm.warp(operationStart + 10 days);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    (,,, uint40 startedAt,,,,) = retargetter.operation();
    assertEq(uint256(startedAt), operationStart + 10 days, "clock started at the boundary");
  }

  /// @notice One second past the deadline-buffer boundary the clock can no longer start, for
  ///         consume and nonzero mint authorization alike; the zero-amount revocation skips
  ///         the gate as always.
  function test_consume_clockStartPastDeadlineBufferReverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);

    // The gate fires before the Request is ever called, so the offer needs no signature
    vm.warp(block.timestamp + 10 days + 1);
    Offer memory offer = _createOffer(1_000e18, 10e18);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.DeadlineTooClose.selector);
    retargetter.consume(offer, "", 1_000e18);

    // A nonzero authorization starts the same clock and hits the same gate
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.DeadlineTooClose.selector);
    retargetter.authorizeMinting(broker, 1_000e18, 10e18);

    // The zero-amount revocation only shrinks exposure and stays available
    vm.prank(consumer);
    retargetter.authorizeMinting(broker, 0, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MINT AUTHORIZATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A nonzero authorization starts the loan clock, lands on the Request, registers
  ///         the account, and its principal occupies the cap until minted or revoked.
  function test_authorizeMinting_startsClockAndCountsTowardCap() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    (,,, uint40 startedAt,,,,) = retargetter.operation();
    assertEq(uint256(startedAt), 0, "clock unset before the authorization");

    vm.prank(consumer);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.MintingAuthorized(request, broker, 2_000e18, 20e18);
    retargetter.authorizeMinting(broker, 2_000e18, 20e18);

    (,,, startedAt,,,,) = retargetter.operation();
    assertEq(uint256(startedAt), block.timestamp, "authorization starts the loan clock");
    assertEq(_outstandingAuthorizedPt(request), 2_000e18, "outstanding authorized principal");
    (uint128 ptAuth, uint128 ytAuth) = IRequest(request).mintAuthorization(broker);
    assertEq(uint256(ptAuth), 2_000e18, "request-side principal authorization");
    assertEq(uint256(ytAuth), 20e18, "request-side yield authorization");

    // The commitment occupies the principal cap: consume can fill up to it, not past it
    uint256 cap = retargetter.maxPrincipal(address(positionManager));
    Offer memory offer = _createOffer(cap, cap / 200);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.consume(offer, "", cap - 2_000e18 + 1);
    _consume(request, cap, cap / 200, cap - 2_000e18);
  }

  /// @notice The broker mints on the Request directly: the authorization clears, the account
  ///         is lazily pruned by the next write path, and the minted capital settles exactly
  ///         like consumed capital.
  function test_authorizeMinting_brokerMintsAndOperationSettles() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _authorize(broker, 2_000e18, 20e18);

    _mintAsBroker(request, 2_000e18);
    assertEq(_outstandingAuthorizedPt(request), 0, "mint cleared the outstanding principal");
    assertEq(retargetter.authorizedAccounts().length, 1, "minted account lingers until pruned");
    (uint128 ptSupply, uint128 ytSupply) = ITokenController(request).totalSupplies();
    assertEq(uint256(ptSupply), 2_000e18, "principal supply minted");
    assertEq(uint256(ytSupply), 20e18, "yield supply minted");
    assertEq(debtToken.balanceOf(request), 2_000e18, "broker capital landed on the request");

    // The next write path prunes the minted account from the set
    _consume(request, 100e18, 1e18, 100e18);
    assertEq(retargetter.authorizedAccounts().length, 0, "minted account pruned");

    // Trustless settlement of the whole supply: principal plus one tick of yield
    uint256 owedNow = retargetter.owed();
    assertEq(owedNow, 2_100e18 + _ceilDiv(uint256(21e18) * 1 days, 365 days), "one tick owed");
    _mintDebt(address(retargetter), owedNow - 2_100e18);
    vm.prank(rebalancer);
    assertEq(retargetter.repay(), owedNow, "trustless repay covers the minted capital");
    vm.prank(rebalancer);
    retargetter.resolve();
    assertFalse(retargetter.isActive(), "operation resolved");
  }

  /// @notice Yield gates on authorization: a ratio above the cap and the classic
  ///         zero-principal yield extraction shape both revert; the exact boundary passes.
  function test_authorizeMinting_revertYieldTooHigh() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);

    // One wei of yield above the 1% operation cap
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.YieldTooHigh.selector);
    retargetter.authorizeMinting(broker, 1_000e18, 10e18 + 1);

    // Zero principal with any yield is the exact shape the gate exists for
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.YieldTooHigh.selector);
    retargetter.authorizeMinting(broker, 0, 1);

    // The boundary ratio passes
    _authorize(broker, 1_000e18, 10e18);
  }

  /// @notice Replacing an account's authorization releases the old amount first, and distinct
  ///         accounts accumulate against the cap.
  function test_authorizeMinting_capAccountingAcrossAccounts() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    uint256 cap = retargetter.maxPrincipal(address(positionManager));

    _authorize(broker, 3_000e18, 0);
    assertEq(_outstandingAuthorizedPt(request), 3_000e18, "first authorization outstanding");

    // Replacing at the full cap passes because the account's old amount is released first
    _authorize(broker, uint128(cap), 0);
    assertEq(_outstandingAuthorizedPt(request), cap, "replaced, not added");
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.authorizeMinting(broker, uint128(cap + 1), 0);

    // A second account accumulates on top of the first
    _authorize(broker, 3_000e18, 0);
    address secondBroker = makeAddr("secondBroker");
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.authorizeMinting(secondBroker, uint128(cap - 3_000e18 + 1), 0);
    _authorize(secondBroker, uint128(cap - 3_000e18), 0);
    assertEq(_outstandingAuthorizedPt(request), cap, "both accounts outstanding");
    assertEq(retargetter.authorizedAccounts().length, 2, "both accounts registered");
  }

  /// @notice The registered-account set is capped: the seventeenth distinct account reverts,
  ///         and revoking one frees a slot.
  function test_authorizeMinting_accountCapBoundsTheSet() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);

    for (uint256 i; i < 16; ++i) {
      _authorize(makeAddr(string(abi.encodePacked("capBroker", i))), 1e18, 0);
    }
    vm.prank(consumer);
    vm.expectRevert(EnumerableSetLib.ExceedsCapacity.selector);
    retargetter.authorizeMinting(broker, 1e18, 0);

    // Revoking any registered account frees a slot for a new one
    _authorize(makeAddr(string(abi.encodePacked("capBroker", uint256(0)))), 0, 0);
    _authorize(broker, 1e18, 0);
    assertEq(retargetter.authorizedAccounts().length, 16, "set back at capacity");
  }

  /// @notice Pulling funds ends the funding round: every pending authorization is revoked and
  ///         swept from the set, the revoked brokers' mints are no-ops, and neither consume
  ///         nor a nonzero authorization can enter afterwards, threshold notwithstanding.
  function test_pullRequestFunds_closesConsumptionAndRevokes() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _consume(request, 2_000e18, 20e18, 2_000e18);
    address secondBroker = makeAddr("secondBroker");
    address thirdBroker = makeAddr("thirdBroker");
    _authorize(broker, 1_000e18, 10e18);
    _authorize(secondBroker, 500e18, 5e18);
    _authorize(thirdBroker, 250e18, 0);

    vm.prank(rebalancer);
    retargetter.pullRequestFunds(1_000e18);

    // Every pending authorization died with the pull
    assertEq(retargetter.authorizedAccounts().length, 0, "authorization set swept");
    (uint128 ptAuth, uint128 ytAuth) = IRequest(request).mintAuthorization(broker);
    assertEq(uint256(ptAuth), 0, "first principal authorization revoked");
    assertEq(uint256(ytAuth), 0, "first yield authorization revoked");
    (ptAuth,) = IRequest(request).mintAuthorization(secondBroker);
    assertEq(uint256(ptAuth), 0, "second principal authorization revoked");
    (ptAuth,) = IRequest(request).mintAuthorization(thirdBroker);
    assertEq(uint256(ptAuth), 0, "third principal authorization revoked");
    _mintAsBroker(request, 1_000e18);
    (uint128 ptSupply,) = ITokenController(request).totalSupplies();
    assertEq(uint256(ptSupply), 2_000e18, "revoked broker minted nothing");

    // Capital entry is shut even though the tick threshold has not elapsed
    Offer memory offer = _createOffer(1_000e18, 10e18);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.consume(offer, "", 1_000e18);
    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.authorizeMinting(broker, 1_000e18, 10e18);

    // Revocation calls stay harmless no-ops, and so does a second pull (idempotent close)
    _authorize(broker, 0, 0);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(500e18);
    assertEq(debtToken.balanceOf(address(retargetter)), 1_500e18, "second pull still moves funds");
  }

  /// @notice A pulled (closed) operation does not poison the next one: resolve resets the
  ///         flag, so the following operation can consume again.
  function test_resolve_reopensConsumptionForNextOperation() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(1_000e18, 100);
    _consume(request, 100e18, 1, 100e18);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(MAX_SENTINEL);

    // Settle: return the pulled principal plus the one-tick yield wei, then resolve
    debtToken.mint(address(retargetter), 1);
    vm.prank(rebalancer);
    assertEq(retargetter.repay(), 100e18 + 1, "owed settled");
    vm.prank(rebalancer);
    retargetter.resolve();

    // The next operation starts with the window open
    address secondRequest = _startAsync(1_000e18, 100);
    _consume(secondRequest, 100e18, 1e18, 100e18);
    (,,, uint40 startedAt,,,,) = retargetter.operation();
    assertEq(uint256(startedAt), block.timestamp, "fresh loan clock on the next operation");
  }

  /// @notice The full-balance sentinel pulls the Request's whole balance and the emitted
  ///         amount is the resolved one.
  function test_pullRequestFunds_sentinelPullsFullBalance() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _consume(request, 2_500e18, 25e18, 2_500e18);

    vm.prank(rebalancer);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestFundsPulled(request, 2_500e18);
    retargetter.pullRequestFunds(MAX_SENTINEL);

    assertEq(debtToken.balanceOf(address(retargetter)), 2_500e18, "full balance pulled");
    assertEq(debtToken.balanceOf(request), 0, "request emptied");
  }

  /// @notice Nonzero authorizations respect the consumption window; revocation stays open past
  ///         it, removes the account eagerly, and a revoked broker's mint is a harmless no-op.
  function test_authorizeMinting_windowGateAndLateRevocation() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _authorize(broker, 2_000e18, 20e18);
    uint256 origin = block.timestamp;

    // Still open exactly at the threshold boundary
    vm.warp(origin + DEFAULT_TICK_THRESHOLD);
    _authorize(broker, 2_500e18, 20e18);

    // One second past: increases are shut, for the owner too
    vm.warp(origin + DEFAULT_TICK_THRESHOLD + 1);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.authorizeMinting(broker, 3_000e18, 20e18);
    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.ConsumptionWindowClosed.selector);
    retargetter.authorizeMinting(broker, 3_000e18, 20e18);

    // Revocation stays open past the window and removes the account eagerly
    vm.prank(owner);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.MintingAuthorized(request, broker, 0, 0);
    retargetter.authorizeMinting(broker, 0, 0);
    assertEq(retargetter.authorizedAccounts().length, 0, "revoked account removed");
    assertEq(_outstandingAuthorizedPt(request), 0, "nothing outstanding after revocation");

    // The revoked broker's mint is the Request's zero-authorization no-op
    _mintAsBroker(request, 2_500e18);
    (uint128 ptSupply, uint128 ytSupply) = ITokenController(request).totalSupplies();
    assertEq(uint256(ptSupply), 0, "nothing minted after revocation");
    assertEq(uint256(ytSupply), 0, "no yield minted after revocation");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ABANDONED OPERATION                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice An operation with nothing consumed owes nothing: repay marks the Request repaid
  ///         with a zero transfer and resolve clears the operation.
  function test_async_abandonedOperation_repayZeroThenResolve() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(1_000e18, 100);

    vm.warp(block.timestamp + 10 days);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestRepaid(request, 0, 0);
    vm.prank(rebalancer);
    assertEq(retargetter.repay(), 0, "nothing owed");
    assertTrue(IRequest(request).isRepaid(), "request marked repaid");

    vm.prank(rebalancer);
    retargetter.resolve();
    assertFalse(retargetter.isActive(), "operation cleared");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ORDER WRAPPERS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_create_storesPartialOrderAndEmits() public {
    _startDefault();
    Order memory order = _order(Mode.DEPOSIT, 123e18, 120e18, bytes32(uint256(7)));
    vm.expectEmit(address(retargetter));
    emit IRetargetter.OrderCreated(address(fund), order);
    vm.prank(rebalancer);
    retargetter.create(order);

    (,,,,,, Order memory stored, bool orderLive) = retargetter.operation();
    assertTrue(orderLive, "order live");
    assertEq(uint8(stored.mode), uint8(Mode.DEPOSIT), "mode stored");
    assertEq(stored.owner, address(retargetter), "owner rebuilt");
    assertEq(stored.receiver, address(retargetter), "receiver rebuilt");
    assertEq(stored.input, 123e18, "input stored");
    assertEq(stored.output, 120e18, "output stored");
    assertEq(stored.salt, bytes32(uint256(7)), "salt stored");
  }

  function test_create_ownerOrReceiverNotRetargetter_reverts() public {
    _startDefault();
    Order memory order = _order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(6)));

    order.owner = maker.addr;
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.InvalidOrder.selector);
    retargetter.create(order);

    order.owner = address(retargetter);
    order.receiver = maker.addr;
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.InvalidOrder.selector);
    retargetter.create(order);
  }

  function test_create_orderAlreadyStored_reverts() public {
    _startDefault();
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(8))));
    vm.expectRevert(LibRetargetterErrors.OrderActive.selector);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(9))));
    vm.stopPrank();
  }

  function test_orderSteps_withoutStoredOrder_revertNoOrder() public {
    _startDefault();
    vm.startPrank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.NoOrder.selector);
    retargetter.commit();
    vm.expectRevert(LibRetargetterErrors.NoOrder.selector);
    retargetter.unlock();
    vm.expectRevert(LibRetargetterErrors.NoOrder.selector);
    retargetter.cancelOrder();
    vm.expectRevert(LibRetargetterErrors.NoOrder.selector);
    retargetter.recoverOrder();
    vm.stopPrank();
  }

  function test_orderSteps_idle_revertNoActiveOperation() public {
    Order memory order = _order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(10)));
    vm.startPrank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.create(order);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.commit();
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.unlock();
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.cancelOrder();
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.recoverOrder();
    vm.stopPrank();
  }

  function test_cancelOrder_clearsStoredOrderAndAllowsNewCreate() public {
    _startDefault();
    Order memory order = _order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(11)));
    vm.startPrank(rebalancer);
    retargetter.create(order);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.OrderCanceled(address(fund), order);
    retargetter.cancelOrder();

    (,,,,,,, bool orderLive) = retargetter.operation();
    assertFalse(orderLive, "order cleared");

    // The slot is free again for a fresh order
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(12))));
    (,,,,,,, orderLive) = retargetter.operation();
    assertTrue(orderLive, "new order live");
    vm.stopPrank();
  }

  function test_unlock_partialFill_keepsOrderLiveUntilFullyPaid() public {
    _startDefault();
    _mintDebt(address(retargetter), 100e18);
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(13))));
    retargetter.commit();
    vm.stopPrank();
    fund.settle();

    // The first unlock pays only half and leaves the order live
    fund.setPartialUnlockBps(5000);
    vm.prank(rebalancer);
    assertEq(retargetter.unlock(), 50e18, "first partial payout");
    (,,,,,,, bool orderLive) = retargetter.operation();
    assertTrue(orderLive, "order still live after a partial fill");

    // The second unlock pays the rest and clears the order
    vm.prank(rebalancer);
    assertEq(retargetter.unlock(), 50e18, "second payout");
    (,,,,,,, orderLive) = retargetter.operation();
    assertFalse(orderLive, "order cleared once fully paid");
    assertEq(collateralToken.balanceOf(address(retargetter)), 100e18, "full output received");
  }

  function test_recoverOrder_returnsInputAndClears() public {
    _startDefault();
    _mintDebt(address(retargetter), 100e18);
    Order memory order = _order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(14)));
    vm.startPrank(rebalancer);
    retargetter.create(order);
    retargetter.commit();
    vm.stopPrank();
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "input pulled by the fund");

    fund.failProcessing();
    vm.expectEmit(address(retargetter));
    emit IRetargetter.OrderRecovered(address(fund), order);
    vm.prank(rebalancer);
    assertEq(retargetter.recoverOrder(), 100e18, "input recovered");
    assertEq(debtToken.balanceOf(address(retargetter)), 100e18, "input back on the retargetter");
    (,,,,,,, bool orderLive) = retargetter.operation();
    assertFalse(orderLive, "order cleared after recovery");
  }

  /// @notice The commit approval is scrubbed to zero for both order modes: the debt asset on
  ///         DEPOSIT and the collateral asset on REDEEM.
  function test_commit_scrubsApprovalForBothModes() public {
    _startDefault();
    fund.setSyncSettlement(true);
    _mintDebt(address(retargetter), 100e18);

    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(15))));
    retargetter.commit();
    assertEq(debtToken.allowance(address(retargetter), address(fund)), 0, "deposit approval scrubbed");
    retargetter.unlock();

    // Redeem the shares the deposit just minted
    retargetter.create(_order(Mode.REDEEM, 100e18, 100e18, bytes32(uint256(16))));
    retargetter.commit();
    assertEq(collateralToken.allowance(address(retargetter), address(fund)), 0, "redeem approval scrubbed");
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       RESOLVE GATES                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_resolve_requestNotRepaid_reverts() public {
    _startDefault();
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.RequestNotRepaid.selector);
    retargetter.resolve();
  }

  /// @notice A stored order that has not reached a final state blocks resolve even after the
  ///         Request is repaid.
  function test_resolve_pendingOrder_revertsAfterRepay() public {
    _startDefault();
    vm.prank(rebalancer);
    retargetter.repay();

    _mintDebt(address(retargetter), 100e18);
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(17))));
    retargetter.commit();
    vm.expectRevert(LibRetargetterErrors.OrderPending.selector);
    retargetter.resolve();
    vm.stopPrank();
  }

  /// @notice A fund-side force-end lets resolve clear the stored order automatically.
  function test_resolve_fundForceEnd_clearsOrderAndResolves() public {
    _startDefault();
    vm.prank(rebalancer);
    retargetter.repay();

    _mintDebt(address(retargetter), 100e18);
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.DEPOSIT, 100e18, 100e18, bytes32(uint256(18))));
    retargetter.commit();
    vm.stopPrank();

    fund.forceEnd();
    vm.prank(rebalancer);
    retargetter.resolve();
    assertFalse(retargetter.isActive(), "resolved");
    (,,,,,,, bool orderLive) = retargetter.operation();
    assertFalse(orderLive, "force-ended order cleared by resolve");
  }

  /// @notice One donated wei of either bound asset blocks resolve until it is folded into the
  ///         position through the full-balance rebalance sentinels (there is no owner sweep).
  function test_resolve_residualBalance_revertsUntilFoldedIntoPosition() public {
    _startDefault();
    vm.prank(rebalancer);
    retargetter.repay();

    collateralToken.mint(address(retargetter), 1);
    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.ResidualBalance.selector, address(collateralToken), 1));
    retargetter.resolve();
    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL));
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "collateral wei folded as supply");

    debtToken.mint(address(retargetter), 1);
    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.ResidualBalance.selector, address(debtToken), 1));
    retargetter.resolve();
    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(0, MAX_SENTINEL, RebalancingOperationType.REPAY, MAX_SENTINEL));
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "debt wei folded as repayment");

    vm.prank(rebalancer);
    retargetter.resolve();
    assertFalse(retargetter.isActive(), "resolved once residuals are gone");
  }

  /// @notice Balances strictly below 2^exponent on both assets pass the residual gate; the
  ///         tolerated dust stays behind for the next operation. Asymmetric exponents with
  ///         debt dust above the collateral tolerance pin each check to its own exponent.
  function test_resolve_dustWithinResidualTolerance_resolves() public {
    _startDefault();
    _setResidualExponents(4, 20);
    vm.prank(rebalancer);
    retargetter.repay();

    collateralToken.mint(address(retargetter), (1 << 4) - 1);
    debtToken.mint(address(retargetter), (1 << 20) - 1);
    vm.prank(rebalancer);
    retargetter.resolve();

    assertFalse(retargetter.isActive(), "resolved with tolerated dust");
    assertEq(collateralToken.balanceOf(address(retargetter)), (1 << 4) - 1, "collateral dust stays");
    assertEq(debtToken.balanceOf(address(retargetter)), (1 << 20) - 1, "debt dust stays");
  }

  /// @notice A collateral balance reaching 2^exponent exactly is above the tolerance.
  function test_resolve_collateralAtToleranceBoundary_reverts() public {
    _startDefault();
    _setResidualExponents(20, 20);
    vm.prank(rebalancer);
    retargetter.repay();

    collateralToken.mint(address(retargetter), 1 << 20);
    vm.prank(rebalancer);
    vm.expectRevert(
      abi.encodeWithSelector(LibRetargetterErrors.ResidualBalance.selector, address(collateralToken), 1 << 20)
    );
    retargetter.resolve();
  }

  /// @notice A debt balance reaching 2^exponent exactly is above the tolerance.
  function test_resolve_debtAtToleranceBoundary_reverts() public {
    _startDefault();
    _setResidualExponents(20, 20);
    vm.prank(rebalancer);
    retargetter.repay();

    debtToken.mint(address(retargetter), 1 << 20);
    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.ResidualBalance.selector, address(debtToken), 1 << 20));
    retargetter.resolve();
  }

  /// @notice Resolve zeroes every operation field, including the loan clock origin.
  function test_resolve_clearsOperationState() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(1_000e18, 100);
    // A one-wei-yield offer keeps the owed amount at the unpulled principal plus one wei
    _consume(request, 100e18, 1, 100e18);
    (,,, uint40 startedAt,,,,) = retargetter.operation();
    assertGt(uint256(startedAt), 0, "clock running");
    // An unminted leftover authorization dies with the repaid Request and must not survive
    // into the next operation
    _authorize(broker, 50e18, 0);
    assertEq(retargetter.authorizedAccounts().length, 1, "authorization registered");

    // Donate the single owed yield wei so the trustless repay settles with zero residual
    debtToken.mint(request, 1);
    vm.prank(rebalancer);
    assertEq(retargetter.repay(), 100e18 + 1, "owed is the principal plus the one-tick yield wei");
    vm.prank(rebalancer);
    retargetter.resolve();

    (
      address operationPositionManager,
      address operationRequest,
      address operationFund,
      uint40 clearedStartedAt,
      uint40 clearedRepaymentDeadline,
      uint16 operationMaxYieldBps,
      Order memory order,
      bool orderLive
    ) = retargetter.operation();
    assertEq(operationPositionManager, address(0), "position manager cleared");
    assertEq(operationRequest, address(0), "request cleared");
    assertEq(operationFund, address(0), "fund cleared");
    assertEq(uint256(clearedStartedAt), 0, "clock cleared");
    assertEq(uint256(clearedRepaymentDeadline), 0, "repayment deadline cleared");
    assertEq(uint256(operationMaxYieldBps), 0, "yield cap cleared");
    assertFalse(orderLive, "no order");
    assertEq(order.input, 0, "order input cleared");
    assertEq(order.output, 0, "order output cleared");
    assertEq(order.salt, bytes32(0), "order salt cleared");
    assertEq(retargetter.authorizedAccounts().length, 0, "authorized account set cleared");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         YIELD CAP                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The yield gate checks the offer's ratio, so partial fills cannot dodge it.
  function test_consume_yieldAboveCap_revertsRegardlessOfPtAmount() public {
    address request = _startDefault();
    // One wei of expected return above the 1% cap on the full offer amount
    Offer memory offer = _createOffer(1_000e18, 10e18 + 1);
    bytes memory signature = _signOffer(offer, request);

    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.YieldTooHigh.selector);
    retargetter.consume(offer, signature, 1e18);

    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.YieldTooHigh.selector);
    retargetter.consume(offer, signature, 1_000e18);
  }

  /// @notice An offer exactly at the cap passes: expectedReturn * BPS == amount * cap.
  function test_consume_yieldExactlyAtCap_passes() public {
    address request = _startDefault();
    // 10e18 * 10_000 == 1_000e18 * 100: exactly at the effective 1% cap
    uint256 ytAmount = _consume(request, 1_000e18, 10e18, 100e18);
    assertEq(ytAmount, 1e18, "pro-rata yield on the partial fill");
    (uint128 ptSupply, uint128 ytSupply) = ITokenController(request).totalSupplies();
    assertEq(uint256(ptSupply), 100e18, "principal supply");
    assertEq(uint256(ytSupply), 1e18, "yield supply");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  SHORTFALL AND FORCE REPAY                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice When redemption proceeds fall short of the owed amount, the trustless repay
  ///         fails, the rebalancer cannot borrow the difference while at or above target, and
  ///         the owner completes the operation with forceRepay.
  function test_async_downShortfall_blockedForRebalancerCompletedByOwner() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    vm.prank(owner);
    positionManager.setRebalanceConfig(200, 0);

    address request = _startAsync(2_857e18, 100);
    _consume(request, 2_857e18, 28e18, 2_857e18);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(2_857e18);
    vm.prank(rebalancer);
    retargetter.rebalance(
      _rebalancingData2(
        0, 2_857e18, RebalancingOperationType.REPAY, 2_857e18, RebalancingOperationType.WITHDRAW, 2_870e18
      )
    );
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.REDEEM, 2_870e18, 2_870e18, bytes32(uint256(19))));
    retargetter.commit();
    vm.stopPrank();

    // The share price drops one percent before settlement: proceeds no longer cover the owed
    vm.warp(block.timestamp + 3 days);
    fund.setSharePrice(0.99e18);
    fund.settle();
    vm.prank(rebalancer);
    uint256 proceeds = retargetter.unlock();
    assertEq(proceeds, 2_870e18 * 99 / 100, "discounted proceeds");
    uint256 owedAmount = retargetter.owed();
    assertEq(owedAmount, 2_857e18 + _ceilDiv(uint256(28e18) * 3 days, 365 days), "owed after three ticks");
    assertGt(owedAmount, proceeds, "shortfall exists");

    // Trustless repay pulls more than the retargetter holds and fails
    vm.prank(rebalancer);
    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    retargetter.repay();

    // Borrowing the difference means increasing an above-target LTV: blocked for the rebalancer
    vm.prank(rebalancer);
    vm.expectPartialRevert(LibRetargetterErrors.AboveTargetLtv.selector);
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, owedAmount - proceeds));

    // The owner covers the gap out of band and settles the Request with owner-chosen bounds
    debtToken.mint(address(retargetter), owedAmount - proceeds);
    vm.expectEmit(request);
    emit IRequest.Repaid(owedAmount);
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestForceRepaid(request, owedAmount, owedAmount, type(uint256).max);
    vm.prank(owner);
    retargetter.forceRepay(owedAmount, owedAmount, type(uint256).max);
    assertTrue(IRequest(request).isRepaid(), "force repaid");
    assertEq(debtToken.balanceOf(request), owedAmount, "request made whole");

    // Nothing left over: the rebalancer resolves
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "no leftover");
    vm.prank(rebalancer);
    retargetter.resolve();
    assertFalse(retargetter.isActive(), "resolved");
  }

  function test_forceRepay_unauthorized_reverts() public {
    _startDefault();
    vm.prank(rebalancer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    retargetter.forceRepay(0, 0, type(uint256).max);
  }

  function test_forceRepay_withoutOperation_reverts() public {
    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.forceRepay(0, 0, type(uint256).max);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      DEADLINE EXPIRY                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Past the 90-day deadline the Request auto-expires: the trustless repay reverts,
  ///         resolve settles through syncRepaidStatus and holders redeem what sits there.
  function test_async_deadlineExpiry_autoRepaidThenResolve() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(3_000e18, 100);
    _consume(request, 3_000e18, 30e18, 3_000e18);
    // Pull only part of the principal: the rest stays in the Request for its holders
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(2_000e18);

    vm.warp(block.timestamp + 91 days);
    vm.prank(rebalancer);
    vm.expectRevert(LibRequestErrors.AlreadyRepaid.selector);
    retargetter.repay();

    // Fold the pulled funds back into the position debt (below target is always allowed),
    // then resolve through the state-mutating repaid sync
    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(0, MAX_SENTINEL, RebalancingOperationType.REPAY, MAX_SENTINEL));
    vm.prank(rebalancer);
    retargetter.resolve();
    assertFalse(retargetter.isActive(), "resolved");
    assertTrue(IRequest(request).isRepaid(), "auto-expired to repaid");

    // Holders redeem whatever sits in the Request: principal first, no yield left
    uint256 makerBalanceBefore = debtToken.balanceOf(maker.addr);
    vm.prank(maker.addr);
    (,, uint256 pAssets, uint256 yAssets) = IVaultController(request).burnAll(maker.addr, maker.addr);
    assertEq(pAssets, 1_000e18, "principal holders take the remaining balance");
    assertEq(yAssets, 0, "no yield assets in a default");
    assertEq(debtToken.balanceOf(maker.addr), makerBalanceBefore + 1_000e18, "maker recovered the residual");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ADVERSARIAL                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Once a rebalance brings the position near target, the recomputed cap collapses
  ///         below the already-consumed principal and any further consume reverts.
  function test_consume_afterCapCollapsed_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    fund.setSyncSettlement(true);
    address request = _startAsync(6_000e18, 100);
    _consume(request, 6_000e18, 60e18, 6_000e18);

    vm.startPrank(rebalancer);
    retargetter.pullRequestFunds(6_000e18);
    retargetter.create(_order(Mode.DEPOSIT, 6_000e18, 6_000e18, bytes32(uint256(20))));
    retargetter.commit();
    retargetter.unlock();
    uint256 owedAmount = retargetter.owed();
    retargetter.rebalance(
      _rebalancingData2(
        MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL, RebalancingOperationType.BORROW, owedAmount
      )
    );
    vm.stopPrank();

    // The live cap now sits below the consumed principal: the cumulative gate blocks any size
    (uint128 ptSupply,) = ITokenController(request).totalSupplies();
    assertLt(retargetter.maxPrincipal(address(positionManager)), uint256(ptSupply), "cap collapsed");

    Offer memory offer = _createOffer(100e18, 1e18);
    bytes memory signature = _signOffer(offer, request);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.consume(offer, signature, 100e18);
  }

  /// @notice One operation at a time: starting while active reverts for everyone, including
  ///         the owner.
  function test_startRetargetting_whileActive_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.startRetargetting(address(positionManager), 1_000e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);

    vm.prank(owner);
    vm.expectRevert(LibRetargetterErrors.OperationActive.selector);
    retargetter.startRetargetting(address(positionManager), 1_000e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  /// @notice After resolve a fresh operation starts; the fund archives ended order ids, so
  ///         identical re-submissions need a fresh salt.
  function test_startRetargetting_afterResolve_startsFreshWithFreshSalt() public {
    _seedPosition(10_000e18, 5_000e18);
    fund.setSyncSettlement(true);
    address firstRequest = _startAsync(1_000e18, 100);

    // Run one full order lifecycle so its id gets archived by the fund, then settle exactly
    bytes32 salt = bytes32(uint256(21));
    _mintDebt(address(retargetter), 10e18);
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.DEPOSIT, 10e18, 10e18, salt));
    retargetter.commit();
    retargetter.unlock();
    retargetter.rebalance(_rebalancingData(MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL));
    retargetter.repay();
    retargetter.resolve();
    vm.stopPrank();
    assertFalse(retargetter.isActive(), "first operation resolved");

    address secondRequest = _startAsync(1_000e18, 100);
    assertTrue(retargetter.isActive(), "fresh operation started");
    assertTrue(secondRequest != firstRequest, "fresh request deployed");

    // The archived salt is rejected by the fund; a fresh salt goes through
    Order memory reused = _order(Mode.DEPOSIT, 10e18, 10e18, salt);
    vm.prank(rebalancer);
    vm.expectRevert(
      abi.encodeWithSelector(LibFundsErrors.OrderAlreadyExists.selector, LibOrder.toId(reused, address(fund)))
    );
    retargetter.create(reused);

    reused.salt = bytes32(uint256(22));
    vm.prank(rebalancer);
    retargetter.create(reused);
    (,,,,,,, bool orderLive) = retargetter.operation();
    assertTrue(orderLive, "fresh-salt order created");
  }

  /// @notice A third-party donation to the Request only reduces the shortfall the trustless
  ///         repay transfers; the repaid balance still covers the owed amount exactly.
  function test_repay_requestDonation_reducesShortfall() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(1_000e18, 100);
    _consume(request, 1_000e18, 10e18, 1_000e18);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(1_000e18);

    // Third-party donation straight to the Request
    debtToken.mint(request, 400e18);

    // Same-transaction repay: the one-tick minimum prices the yield
    uint256 expectedOwed = 1_000e18 + _ceilDiv(uint256(10e18) * 1 days, 365 days);
    uint256 expectedShortfall = expectedOwed - 400e18;
    vm.expectEmit(address(retargetter));
    emit IRetargetter.RequestRepaid(request, expectedOwed, expectedShortfall);
    vm.prank(rebalancer);
    assertEq(retargetter.repay(), expectedOwed, "owed unchanged by the donation");

    assertTrue(IRequest(request).isRepaid(), "repaid");
    assertEq(debtToken.balanceOf(request), expectedOwed, "balance covers the owed amount exactly");
    assertEq(
      debtToken.balanceOf(address(retargetter)), 1_000e18 - expectedShortfall, "only the shortfall left the retargetter"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Seeds the default below-target position and starts a standard ASYNC operation with
  ///      a 1% effective yield cap.
  function _startDefault() internal returns (address request) {
    _seedPosition(10_000e18, 5_000e18);
    request = _startAsync(6_000e18, 100);
  }

  /// @dev Ceiling division mirroring the quoter's rounding-up yield math.
  function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    return (a + b - 1) / b;
  }
}
