// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "test/facility/inkind/InKindFacilityBase.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {MockFlashLender, MockSwapVenue, MockExitRouter} from "test/mock/facility/FlashExitRouterMock.sol";
import {IMorpho} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {MorphoBalancesLib} from "lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title InKindLifecycleE2ETest
/// @notice Lifecycle of an in-kind PM on real contracts: operator setup on shared caps pools,
///         entries spilling from auths into the security pool, interest, NAV moves and PM fees,
///         a flash-funded router exit through the callback, re-arming, then a full exit.
contract InKindLifecycleE2ETest is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;
  using SharesMathLib for uint256;
  using MorphoBalancesLib for IMorpho;

  uint24 constant ENTRY_FEE_BPS = 25;
  uint24 constant REARMED_ENTRY_FEE_BPS = 10;
  uint24 constant EXIT_FEE_BPS = 30;
  uint24 constant PM_MANAGEMENT_FEE = 100;
  uint24 constant PM_PERFORMANCE_FEE = 1_000;
  uint128 constant CAPACITY = 4_000e6;
  uint128 constant CAPACITY_HARD_CAP = 8_000e6;
  uint128 constant SECURITY = 1_500e6;
  uint128 constant ALICE_AUTH = 300e6;
  uint256 constant FLASH_FEE_BPS = 5;
  uint256 constant ORACLE_SCALE = 1e36;
  // debt-wei an exit may shave off holder equity: the quoted-collateral floor and the floored Morpho debt view
  uint256 constant EQUITY_DUST = 2;

  address alice;
  address bob;
  address carol;
  address dave;

  MockFlashLender lender;
  MockSwapVenue venue;
  MockExitRouter router;

  /// @dev Pool reads taken right before a flow (post-accrual figures, as the PM settles at).
  struct PoolState {
    uint256 totalAssets;
    uint256 supply;
    uint256 pendingFeeShares;
    uint256 supplyAdj;
    uint256 collateral;
    uint256 debt;
    uint256 borrowAssets;
    uint256 borrowShares;
  }

  /// @dev Expected figures of one entry or exit (`amount` is the underlying in or the shares out).
  struct Flow {
    uint256 amount;
    uint256 debt;
    uint256 shares;
    uint256 feeShares;
    uint256 required;
    uint256 out;
  }

  /// @dev Balances read right before a flow.
  struct Balances {
    uint256 shares;
    uint256 debt;
    uint256 underlying;
    uint256 feeShares;
    uint256 pmFeeShares;
    uint256 poolCap;
    uint256 lender;
  }

  function setUp() public override {
    super.setUp();
    alice = makeAddr("alice");
    bob = makeAddr("bob");
    carol = makeAddr("carol");
    dave = makeAddr("dave");
    _seedPool(SEED_COLLATERAL, SEED_DEBT);

    vm.startPrank(owner);
    positionManager.setFeeData(pmFeeRecipient, PM_MANAGEMENT_FEE, PM_PERFORMANCE_FEE);
    absoluteCaps.setCap(POOL_ID, uint128(_capsUnits(CAPACITY)), uint128(_capsUnits(CAPACITY_HARD_CAP)));
    absoluteCaps.setCap(SECURITY_POOL_ID, uint128(_capsUnits(SECURITY)), uint128(_capsUnits(SECURITY)));
    vm.stopPrank();

    vm.startPrank(facilitator);
    facility.setEntry(address(positionManager), _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, ENTRY_FEE_BPS, false);
    facility.setExit(
      address(positionManager), _poolWord(POOL_ID, MULT_NEG_1X), uint40(block.timestamp + 30 days), EXIT_FEE_BPS
    );
    vm.stopPrank();

    vm.startPrank(operator);
    facility.setSecurityCap(address(underlyingToken), _poolWord(SECURITY_POOL_ID, MULT_1X));
    facility.setAuth(address(underlyingToken), alice, ALICE_AUTH, FAR_EXPIRY);
    vm.stopPrank();

    lender = new MockFlashLender(debtToken, FLASH_FEE_BPS);
    venue = new MockSwapVenue(underlyingToken, debtToken, DEFAULT_ORACLE_PRICE);
    router = new MockExitRouter(facility, lender, venue, debtToken, underlyingToken);
    debtToken.setBalance(address(lender), 10_000_000e6);
    debtToken.setBalance(address(venue), 10_000_000e6);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         LIFECYCLE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_lifecycle_fullCycle() public {
    uint256 capacityConsumed;
    uint256 capacityReleased;

    // alice: the auth absorbs the first 300e6, the security pool the rest
    Flow memory f = _prepareEntry(alice, 1_000e18);
    _expectPoolCharge(POOL_ID, f.debt, MULT_1X, CAPACITY - f.debt);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.AuthConsumed(address(underlyingToken), alice, ALICE_AUTH, 0);
    _expectPoolCharge(SECURITY_POOL_ID, f.debt - ALICE_AUTH, MULT_1X, SECURITY - (f.debt - ALICE_AUTH));
    _executeEntry(alice, f);
    assertEq(facility.getAuth(address(underlyingToken), alice).amount, 0, "alice auth left");
    capacityConsumed += f.debt;
    uint256 securityLeft = SECURITY - (f.debt - ALICE_AUTH);

    // bob: no auth, the security pool takes the whole debt
    f = _prepareEntry(bob, 2_000e18);
    _expectPoolCharge(SECURITY_POOL_ID, f.debt, MULT_1X, securityLeft - f.debt);
    _executeEntry(bob, f);
    capacityConsumed += f.debt;
    securityLeft -= f.debt;
    assertEq(_poolCap(POOL_ID), CAPACITY - capacityConsumed, "capacity after bob");

    // carol: the security pool alone falls short and the whole entry unwinds
    f = _prepareEntry(carol, 1_000e18);
    assertGt(f.debt, securityLeft, "carol must overflow the security pool");
    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, uint64(SECURITY_POOL_ID)));
    facility.enter(address(positionManager), f.amount, 0, type(uint256).max, 0, carol);
    assertEq(_poolCap(POOL_ID), CAPACITY - capacityConsumed, "capacity touched by the reverted entry");
    assertEq(_poolCap(SECURITY_POOL_ID), securityLeft, "security touched by the reverted entry");

    // the operator auths carol for the shortfall: auth first, then the pool drains to zero
    uint128 carolAuth = uint128(f.debt - securityLeft);
    vm.prank(operator);
    facility.setAuth(address(underlyingToken), carol, carolAuth, FAR_EXPIRY);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.AuthConsumed(address(underlyingToken), carol, carolAuth, 0);
    _expectPoolCharge(SECURITY_POOL_ID, securityLeft, MULT_1X, 0);
    _executeEntry(carol, f);
    assertEq(facility.getAuth(address(underlyingToken), carol).amount, 0, "carol auth left");
    capacityConsumed += f.debt;

    // interest, a NAV up-move and PM fees pending
    vm.warp(block.timestamp + 45 days);
    _movePrice(DEFAULT_ORACLE_PRICE * 104 / 100);
    {
      (,, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
      assertGt(mgmtShares, 0, "no pending management fee");
      assertGt(perfShares, 0, "no pending performance fee");
    }

    // bob leaves through the router; the exit offer expired and is re-armed first
    uint256 bobShares = positionManager.balanceOf(bob);
    vm.prank(bob);
    positionManager.approve(address(router), bobShares);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, address(positionManager)));
    router.exitToDebt(address(positionManager), bobShares, 1, 0, bob);
    vm.prank(facilitator);
    facility.setExit(address(positionManager), _poolWord(POOL_ID, MULT_NEG_1X), FAR_EXPIRY, EXIT_FEE_BPS);
    capacityReleased += _routerExitChecked(bob, bobShares);
    assertEq(router.callbackCount(), 1, "router callback count");
    assertEq(_poolCap(SECURITY_POOL_ID), 0, "exits refunded the security pool");

    // dave is blocked until the caps manager refills the security pool; the entry re-arms at a lower fee
    f = _prepareEntry(dave, 600e18);
    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, uint64(SECURITY_POOL_ID)));
    facility.enter(address(positionManager), f.amount, 0, type(uint256).max, 0, dave);
    vm.prank(owner);
    absoluteCaps.setCap(SECURITY_POOL_ID, uint128(_capsUnits(1_000e6)), uint128(_capsUnits(1_000e6)));
    vm.prank(facilitator);
    facility.setEntry(address(positionManager), _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, REARMED_ENTRY_FEE_BPS, false);
    assertEq(_poolCap(POOL_ID), CAPACITY - capacityConsumed + capacityReleased, "re-arm touched the shared pool");
    f = _quoteEntry(600e18);
    _expectPoolCharge(SECURITY_POOL_ID, f.debt, MULT_1X, 1_000e6 - f.debt);
    _executeEntry(dave, f);
    capacityConsumed += f.debt;

    // more interest and a NAV down-move, then everyone leaves
    vm.warp(block.timestamp + 30 days);
    _movePrice(DEFAULT_ORACLE_PRICE * 101 / 100);
    capacityReleased += _exitChecked(alice, positionManager.balanceOf(alice));
    uint256 carolShares = positionManager.balanceOf(carol);
    vm.prank(carol);
    positionManager.approve(address(router), carolShares);
    capacityReleased += _routerExitChecked(carol, carolShares);
    capacityReleased += _exitChecked(dave, positionManager.balanceOf(dave));

    assertEq(positionManager.balanceOf(alice), 0, "alice shares left");
    assertEq(positionManager.balanceOf(bob), 0, "bob shares left");
    assertEq(positionManager.balanceOf(carol), 0, "carol shares left");
    assertEq(positionManager.balanceOf(dave), 0, "dave shares left");
    assertEq(
      positionManager.totalSupply(),
      positionManager.balanceOf(seeder) + positionManager.balanceOf(feeRecipient)
        + positionManager.balanceOf(pmFeeRecipient),
      "supply outside seeder and fee recipients"
    );
    assertEq(_poolCap(POOL_ID), CAPACITY - capacityConsumed + capacityReleased, "capacity pool ledger");
    assertEq(router.callbackCount(), 2, "router callback count");
  }

  function testFuzz_lifecycle_flowsHoldEquityPerShare(
    uint256 amountA,
    uint256 amountB,
    uint256 elapsed,
    uint256 priceBps,
    uint256 exitFraction
  ) public {
    vm.startPrank(owner);
    // whole debt units, so _poolCap reads them back exactly
    uint128 half = uint128(_capsUnits(type(uint128).max / 2 / CAPS_SCALE));
    absoluteCaps.setCap(POOL_ID, half, type(uint128).max);
    absoluteCaps.setCap(SECURITY_POOL_ID, half, half);
    vm.stopPrank();
    vm.prank(facilitator);
    facility.setExit(address(positionManager), _poolWord(POOL_ID, MULT_NEG_1X), FAR_EXPIRY, EXIT_FEE_BPS);

    _executeEntry(alice, _prepareEntry(alice, bound(amountA, 4e12, 20_000e18)));
    _executeEntry(bob, _prepareEntry(bob, bound(amountB, 1e13, 20_000e18)));

    vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
    _movePrice(DEFAULT_ORACLE_PRICE * bound(priceBps, 9_000, 12_000) / BPS);

    uint256 aliceShares = positionManager.balanceOf(alice);
    uint256 firstExit = bound(exitFraction, 2, aliceShares - 2);
    _exitChecked(alice, firstExit);
    uint256 bobShares = positionManager.balanceOf(bob);
    vm.prank(bob);
    positionManager.approve(address(router), bobShares);
    _routerExitChecked(bob, bobShares);
    _exitChecked(alice, aliceShares - firstExit);

    assertEq(positionManager.balanceOf(alice), 0, "alice shares left");
    assertEq(positionManager.balanceOf(bob), 0, "bob shares left");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _poolWord(uint16 id, int24 multiplier) internal view returns (uint256) {
    return LibCaps.encodeExternal(address(absoluteCaps), id, multiplier);
  }

  /// @dev Remaining capacity of a pool, in debt units.
  function _poolCap(uint16 id) internal view returns (uint256) {
    return _absCap(id);
  }

  function _movePrice(uint256 price) internal {
    oracle.setPrice(price);
    venue.setPrice(price);
  }

  function _poolState() internal view returns (PoolState memory s) {
    uint256 mgmtShares;
    uint256 perfShares;
    (s.totalAssets, s.supply, mgmtShares, perfShares) = positionManager.pendingFees();
    s.pendingFeeShares = mgmtShares + perfShares;
    s.supply += s.pendingFeeShares;
    s.supplyAdj = s.supply + positionManager.virtualShareOffset();
    s.collateral = positionManager.collateralAmount();
    s.debt = positionManager.debtAmount();
    (,, s.borrowAssets, s.borrowShares) = morpho.expectedMarketBalances(marketParams);
  }

  /// @dev Expects one CapConsumed on the shared absolute caps for a whole-pool charge, in debt units.
  function _expectPoolCharge(uint16 id, uint256 amount, int24 multiplier, uint256 newCap) internal {
    vm.expectEmit(true, true, true, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(id, _capsUnits(amount), multiplier, _capsUnits(amount), uint128(_capsUnits(newCap)));
  }

  /// @dev Quotes the entry exactly and funds `who` for it.
  function _prepareEntry(address who, uint256 amount) internal returns (Flow memory f) {
    f = _quoteEntry(amount);
    _fundEntrant(who, amount);
  }

  /// @dev Exact entry: ratio debt, then the PM mint from the quoted equity delta (Morpho share
  ///      rounding on the borrow included) at the offer fee.
  function _quoteEntry(uint256 amount) internal view returns (Flow memory f) {
    PoolState memory s = _poolState();
    f.amount = amount;
    f.debt = amount.mulDiv(s.debt, s.collateral);
    uint256 newBorrowShares = f.debt.toSharesUp(s.borrowAssets, s.borrowShares);
    uint256 positionShares = morpho.position(marketId, address(borrowPosition)).borrowShares + newBorrowShares;
    uint256 debtAfter = positionShares.toAssetsDown(s.borrowAssets + f.debt, s.borrowShares + newBorrowShares);
    uint256 assetsAfter = (s.collateral + amount).mulDiv(oracle.price(), ORACLE_SCALE) - debtAfter;
    uint256 minted = (assetsAfter - s.totalAssets).mulDiv(s.supplyAdj, s.totalAssets + 1);
    f.feeShares = minted.mulDivUp(facility.getEntry(address(positionManager)).feeBps, BPS);
    f.shares = minted - f.feeShares;
  }

  /// @dev Runs a prepared entry with exact bounds and checks every leg.
  function _executeEntry(address who, Flow memory f) internal {
    PoolState memory s = _poolState();
    Balances memory b = _balances(who);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Entered(address(positionManager), who, who, f.amount, f.debt, f.shares, f.feeShares);
    vm.prank(who);
    facility.enter(address(positionManager), f.amount, f.debt, f.debt, f.shares, who);

    assertEq(positionManager.balanceOf(who) - b.shares, f.shares, "entrant shares");
    assertEq(debtToken.balanceOf(who) - b.debt, f.debt, "entrant debt");
    assertEq(b.underlying - underlyingToken.balanceOf(who), f.amount, "entrant underlying");
    assertEq(b.poolCap - _poolCap(POOL_ID), f.debt, "capacity leg");
    assertEq(positionManager.collateralAmount() - s.collateral, f.amount, "collateral leg");
    _assertDebtLeg(s, f.debt, true);
    _assertFeesAndHolders(s, b, f.feeShares);
  }

  /// @dev Expected exit of `shares` against the live pool: burn's mirrored slices at the offer fee.
  function _quoteExit(PoolState memory s, uint256 shares) internal view returns (Flow memory f) {
    f.amount = shares;
    f.feeShares = shares.mulDivUp(facility.getExit(address(positionManager)).feeBps, BPS);
    f.shares = shares - f.feeShares;
    f.debt = s.debt.mulDivUp(f.shares, s.supplyAdj);
    f.required = f.debt + f.debt.mulDivUp(10, BPS) + 1;
    f.out = s.collateral.mulDiv(f.shares, s.supplyAdj);
  }

  /// @dev Exits `shares` of `who` directly with an exact pre-funded pull and checks every leg.
  ///      Returns the debt leg, which the -1x exit word gives back to the shared pool.
  function _exitChecked(address who, uint256 shares) internal returns (uint256 released) {
    PoolState memory s = _poolState();
    Flow memory f = _quoteExit(s, shares);
    debtToken.setBalance(who, debtToken.balanceOf(who) + f.required);
    vm.startPrank(who);
    debtToken.approve(address(facility), f.required);
    positionManager.approve(address(facility), shares);
    vm.stopPrank();
    Balances memory b = _balances(who);

    // the exit word is charged after burn, so the pool event follows Exited
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Exited(address(positionManager), who, who, f.out, f.debt, f.shares, f.feeShares);
    _expectPoolCharge(POOL_ID, f.debt, MULT_NEG_1X, b.poolCap + f.debt);
    vm.prank(who);
    facility.exit(address(positionManager), shares, f.required, f.out, who, "");

    assertEq(b.shares - positionManager.balanceOf(who), shares, "exiter shares");
    assertEq(b.debt - debtToken.balanceOf(who), f.debt, "exiter debt net of refund");
    assertEq(debtToken.allowance(who, address(facility)), 0, "pull left allowance");
    assertEq(underlyingToken.balanceOf(who) - b.underlying, f.out, "exiter underlying");
    _assertExitLegs(s, f, b);
    _assertFeesAndHolders(s, b, f.feeShares);
    return f.debt;
  }

  /// @dev Exits all of `shares` of `who` through the flash router (already approved) and checks
  ///      the cash out: venue proceeds minus the debt repaid and the flash fee.
  function _routerExitChecked(address who, uint256 shares) internal returns (uint256 released) {
    PoolState memory s = _poolState();
    Flow memory f = _quoteExit(s, shares);
    uint256 flashFee = f.required.mulDivUp(FLASH_FEE_BPS, BPS);
    uint256 cash = venue.quote(f.out) - f.debt - flashFee;
    Balances memory b = _balances(who);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Exited(
      address(positionManager), address(router), address(router), f.out, f.debt, f.shares, f.feeShares
    );
    _expectPoolCharge(POOL_ID, f.debt, MULT_NEG_1X, b.poolCap + f.debt);
    vm.prank(who);
    router.exitToDebt(address(positionManager), shares, f.required, cash, who);

    assertEq(b.shares - positionManager.balanceOf(who), shares, "exiter shares");
    assertEq(debtToken.balanceOf(who) - b.debt, cash, "exiter cash");
    assertEq(debtToken.balanceOf(address(lender)) - b.lender, flashFee, "lender repaid with fee");
    assertEq(router.lastCallbackShares(), shares, "callback shares");
    assertEq(router.lastCallbackDebtIn(), f.required, "callback debt pull");
    assertEq(positionManager.balanceOf(address(router)), 0, "router holds shares");
    assertEq(debtToken.balanceOf(address(router)), 0, "router holds debt");
    assertEq(underlyingToken.balanceOf(address(router)), 0, "router holds underlying");
    assertEq(debtToken.allowance(address(router), address(facility)), 0, "router allowance to facility");
    _assertExitLegs(s, f, b);
    _assertFeesAndHolders(s, b, f.feeShares);
    return f.debt;
  }

  function _balances(address who) internal view returns (Balances memory b) {
    b.shares = positionManager.balanceOf(who);
    b.debt = debtToken.balanceOf(who);
    b.underlying = underlyingToken.balanceOf(who);
    b.feeShares = positionManager.balanceOf(feeRecipient);
    b.pmFeeShares = positionManager.balanceOf(pmFeeRecipient);
    b.poolCap = _poolCap(POOL_ID);
    b.lender = debtToken.balanceOf(address(lender));
  }

  function _assertExitLegs(PoolState memory s, Flow memory f, Balances memory b) internal view {
    assertEq(s.collateral - positionManager.collateralAmount(), f.out, "collateral leg");
    assertEq(_poolCap(POOL_ID) - b.poolCap, f.debt, "exit word release");
    _assertDebtLeg(s, f.debt, false);
  }

  /// @dev Fee shares landed exactly, holders kept their equity per share and the facility is clean.
  function _assertFeesAndHolders(PoolState memory s, Balances memory b, uint256 feeShares) internal view {
    assertEq(positionManager.balanceOf(feeRecipient) - b.feeShares, feeShares, "facility fee shares");
    assertEq(positionManager.balanceOf(pmFeeRecipient) - b.pmFeeShares, s.pendingFeeShares, "PM fee shares");
    _assertEquityPerShareHeld(s);
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /// @dev The PM's Morpho borrow moves by exactly the flow's debt leg (its module is the market's
  ///      only borrower; the PM's own debt view rounds the borrow shares down).
  function _assertDebtLeg(PoolState memory before, uint256 debt, bool borrowed) internal view {
    (,, uint256 borrowAssets,) = morpho.expectedMarketBalances(marketParams);
    if (borrowed) assertEq(borrowAssets - before.borrowAssets, debt, "borrow != debt leg");
    else assertEq(before.borrowAssets - borrowAssets, debt, "repay != debt leg");
  }

  /// @dev Holder equity per share, (totalAssets + 1) / (supply + offset) as the PM prices
  ///      shares, does not drop through the flow beyond EQUITY_DUST debt-wei.
  function _assertEquityPerShareHeld(PoolState memory before) internal view {
    PoolState memory a = _poolState();
    uint256 floorAssets = (before.totalAssets + 1).mulDivUp(a.supplyAdj, before.supplyAdj);
    assertGe(a.totalAssets + 1 + EQUITY_DUST, floorAssets, "holder equity per share dropped");
  }
}
