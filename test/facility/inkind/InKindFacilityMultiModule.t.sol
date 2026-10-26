// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibInKindView} from "src/libs/facility/inkind/LibInKindView.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {MarketParams, Position} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title InKindFacilityMultiModuleTest
/// @notice InKindFacility over a PM with two Morpho borrow modules: entry neutrality and preview
///         parity under a shared quote, the NonNeutralMint and zero-mint gates on a divergent
///         receiving quote and on an entry many times the pool, exact exit mirroring over the
///         full withdrawal queue, the round-trip shift to the supply-queue head, and a
///         strict-subset queue (exits and the exit views bounded by what the queue holds).
contract InKindFacilityMultiModuleTest is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;
  using MarketParamsLib for MarketParams;
  using LibClone for address;

  // Module A holds 6_000 units at 25% LTV, module B 4_000 at 50% (1:1 quote).
  uint256 constant COLLATERAL_A = 6_000e18;
  uint256 constant DEBT_A = 1_500e6;
  uint256 constant COLLATERAL_B = 4_000e18;
  uint256 constant DEBT_B = 2_000e6;
  // B's market runs at 20% utilization (20% APR on IrmMock), A's at ~0.2%.
  uint256 constant MARKET_B_LIQUIDITY = 10_000e6;
  uint256 constant ENTER_AMOUNT = 1_000e18;
  uint256 constant EXIT_CAP = 1_000_000e6;
  uint256 constant ENTRY_CAP = 10_000e6;
  uint256 constant SEIZED_FROM_B = 1_000e18;
  // With B quoting 1.1 on the split PM, this entry mints exactly the fair fraction plus tolerance.
  uint256 constant TOLERANCE_EDGE = 524_637_681_083_384;
  // One wei short of a quote unit: 1e12 collateral wei per debt unit at a 1:1 quote.
  uint256 constant CARRY = 1e12 - 1;

  PositionManager public pmMulti;
  MorphoBorrowPosition public moduleA;
  MorphoBorrowPosition public moduleB;
  MarketParams public marketParamsB;

  function setUp() public override {
    super.setUp();
    IrmMock irmB = new IrmMock();
    vm.prank(owner);
    morpho.enableIrm(address(irmB));
    // Same oracle as module A's market: the two modules share one price feed.
    marketParamsB = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irmB),
      lltv: DEFAULT_LLTV
    });
    morpho.createMarket(marketParamsB);
    _supplyLiquidity(marketParamsB, MARKET_B_LIQUIDITY);

    (pmMulti, moduleA, moduleB) = _deployTwoModulePm(marketParamsB);
    _seedModules(pmMulti, moduleA, moduleB, DEBT_A, DEBT_B);
    _setEntry(pmMulti, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(pmMulti, EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(LibCaps.MAX_ABSOLUTE);
    vm.label(address(pmMulti), "PositionManagerMulti");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Deploys a PM with module A on the base market and module B on `paramsB`.
  function _deployTwoModulePm(MarketParams memory paramsB)
    internal
    returns (PositionManager p, MorphoBorrowPosition a, MorphoBorrowPosition b)
  {
    p = PositionManager(address(new PositionManager()).clone());
    p.initialize(
      owner,
      PositionManagerMetadata({
        name: "Multi", symbol: "MULTI", collateralAsset: address(collateralToken), debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(transferGuard),
      0,
      0
    );
    vm.startPrank(owner);
    a = MorphoBorrowPosition(
      borrowPositionFactory.createBorrowPosition(marketId, address(p), BP_SAFE_LTV, BP_LIQUIDATION_LTV)
    );
    b = MorphoBorrowPosition(
      borrowPositionFactory.createBorrowPosition(paramsB.id(), address(p), BP_SAFE_LTV, BP_LIQUIDATION_LTV)
    );
    p.grantRoles(owner, PM_CURATOR_ROLE);
    p.addBorrowModule(address(a));
    p.addBorrowModule(address(b));
    p.grantRoles(address(facility), PM_MINTER_ROLE);
    p.grantRoles(seeder, PM_MINTER_ROLE);
    collateralToken.grantRoles(address(p), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(a), WA_SENDER_ROLE);
    collateralToken.grantRoles(address(b), WA_SENDER_ROLE);
    vm.stopPrank();
  }

  /// @dev Seeds B then A on their own, then sets both queues to [A, B].
  function _seedModules(PositionManager p, MorphoBorrowPosition a, MorphoBorrowPosition b, uint256 debtA, uint256 debtB)
    internal
  {
    _setSupplyQueue(p, address(b), address(0));
    _seedPool(p, COLLATERAL_B, debtB);
    _setSupplyQueue(p, address(a), address(0));
    _seedPool(p, COLLATERAL_A, debtA);
    _setSupplyQueue(p, address(a), address(b));
    _setWithdrawalQueue(p, address(a), address(b));
  }

  /// @dev Sets the supply queue to [head] or [head, tail] with unbounded max borrows.
  function _setSupplyQueue(PositionManager p, address head, address tail) internal {
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](tail == address(0) ? 1 : 2);
    queue[0] = SupplyQueueEntry({position: head, maxBorrow: type(uint96).max});
    if (tail != address(0)) queue[1] = SupplyQueueEntry({position: tail, maxBorrow: type(uint96).max});
    vm.prank(owner);
    p.setSupplyQueue(queue);
  }

  /// @dev Sets the withdrawal queue to [first] or [first, second].
  function _setWithdrawalQueue(PositionManager p, address first, address second) internal {
    address[] memory queue = new address[](second == address(0) ? 1 : 2);
    queue[0] = first;
    if (second != address(0)) queue[1] = second;
    vm.prank(owner);
    p.setWithdrawalQueue(queue);
  }

  /// @dev Supplies debt-asset liquidity into `params`.
  function _supplyLiquidity(MarketParams memory params, uint256 amount) internal {
    debtToken.setBalance(address(this), amount);
    debtToken.approve(address(morpho), amount);
    morpho.supply(params, amount, 0, address(this), "");
  }

  /// @dev Deploys a second two-module PM whose module B sits on a market with its own oracle,
  ///      seeded with the fixture's collateral, with B (the receiving module) at the head of the
  ///      supply queue.
  function _deploySplitQuotePm(uint256 debtA, uint256 debtB)
    internal
    returns (PositionManager split, OracleMock oracleB)
  {
    oracleB = new OracleMock();
    oracleB.setPrice(DEFAULT_ORACLE_PRICE);
    MarketParams memory paramsB = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracleB),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    morpho.createMarket(paramsB);
    _supplyLiquidity(paramsB, MORPHO_LIQUIDITY);
    MorphoBorrowPosition a;
    MorphoBorrowPosition b;
    (split, a, b) = _deployTwoModulePm(paramsB);
    _seedModules(split, a, b, debtA, debtB);
    _setSupplyQueue(split, address(b), address(a));
    _setEntry(split, ENTRY_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
  }

  /// @dev Burn's share denominator: post-accrual supply plus the virtual offset.
  function _adjustedSupply(PositionManager p) internal view returns (uint256) {
    (, uint256 supply, uint256 mgmtFeeShares, uint256 perfFeeShares) = p.pendingFees();
    return supply + mgmtFeeShares + perfFeeShares + p.virtualShareOffset();
  }

  /// @dev Redeemable value of `who`'s shares of the fixture PM at the current quote.
  function _claim(address who) internal view returns (uint256) {
    return pmMulti.balanceOf(who).mulDiv(pmMulti.totalAssets(), _adjustedSupply(pmMulti));
  }

  /// @dev Enables management and performance fees on the fixture PM.
  function _setMultiPmFees() internal {
    vm.prank(owner);
    pmMulti.setFeeData(pmFeeRecipient, 100, 1_000);
  }

  /// @dev Funds `user` with exactly `required` debt asset and approves an exit of `shares`.
  function _fundExit(uint256 shares, uint256 required) internal {
    debtToken.setBalance(user, required);
    vm.startPrank(user);
    debtToken.approve(address(facility), required);
    pmMulti.approve(address(facility), shares);
    vm.stopPrank();
  }

  /// @dev Exits `shares` of the fixture PM as `user` funded with exactly `required`, with
  ///      `maxDebtIn` at `required`.
  function _exitExact(uint256 shares, uint256 required, uint256 minOut) internal returns (uint256 out, uint256 debtIn) {
    _fundExit(shares, required);
    vm.prank(user);
    (out, debtIn) = facility.exit(address(pmMulti), shares, required, minOut, receiver, "");
  }

  /// @dev Liquidates SEIZED_FROM_B of module B on Morpho and returns the PM equity it cost.
  function _liquidateModuleB() internal returns (uint256 penalty) {
    uint256 totalAssetsBefore = pmMulti.totalAssets();
    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, MARKET_B_LIQUIDITY);
    vm.startPrank(liquidator);
    debtToken.approve(address(morpho), MARKET_B_LIQUIDITY);
    morpho.liquidate(marketParamsB, address(moduleB), SEIZED_FROM_B, 0, "");
    vm.stopPrank();
    penalty = totalAssetsBefore - pmMulti.totalAssets();
  }

  /// @dev Supplies `amount` collateral on Morpho on behalf of `module`, outside the PM.
  function _donateCollateral(MarketParams memory params, address module, uint256 amount) internal {
    underlyingToken.setBalance(seeder, underlyingToken.balanceOf(seeder) + amount);
    vm.startPrank(seeder);
    underlyingToken.approve(address(collateralToken), amount);
    collateralToken.mint(seeder, amount);
    collateralToken.approve(address(morpho), amount);
    morpho.supplyCollateral(params, amount, module, "");
    vm.stopPrank();
  }

  /// @dev Asserts the Morpho position of `module` on `params`.
  function _assertModule(MorphoBorrowPosition module, MarketParams memory params, uint256 collateral, uint256 debt)
    internal
    view
  {
    assertEq(morpho.position(params.id(), address(module)).collateral, collateral, "module collateral");
    assertEq(module.totalBorrowed(), debt, "module debt");
  }

  /// @dev Asserts the facility retains no token or allowance around `p`.
  function _assertCleanOn(PositionManager p) internal view {
    assertEq(underlyingToken.balanceOf(address(facility)), 0, "facility holds underlying");
    assertEq(collateralToken.balanceOf(address(facility)), 0, "facility holds wrapper");
    assertEq(debtToken.balanceOf(address(facility)), 0, "facility holds debt asset");
    assertEq(p.balanceOf(address(facility)), 0, "facility holds PM shares");
    assertEq(collateralToken.allowance(address(facility), address(p)), 0, "wrapper allowance");
    assertEq(debtToken.allowance(address(facility), address(p)), 0, "debt allowance");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ENTER                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_enter_sharedQuoteMintsTheRatioMatchedFraction() public {
    assertEq(pmMulti.collateralAmount(), 10_000e18, "seeded collateral");
    assertEq(pmMulti.debtAmount(), 3_500e6, "seeded debt");
    assertEq(pmMulti.totalAssets(), 6_500e6, "seeded equity");
    uint256 supplyAdj = _adjustedSupply(pmMulti);
    // c / C = 10%: the debt leg is 350e6 and the quoted equity added 1_000e6 - 350e6.
    uint256 minted = uint256(650e6).mulDiv(supplyAdj, 6_500e6 + 1);
    uint256 fee = minted.mulDivUp(DEFAULT_FEE_BPS, BPS);
    (uint256 previewDebt, uint256 previewShares, uint256 previewFee) =
      facility.previewEnter(address(pmMulti), ENTER_AMOUNT);
    uint256 supplyBefore = pmMulti.totalSupply();

    // The preview is exact under a shared quote: its figures pass as bounds at equality.
    _fundEntrant(user, ENTER_AMOUNT);
    vm.expectEmit(address(facility));
    emit IInKindFacility.Entered(address(pmMulti), user, user, ENTER_AMOUNT, 350e6, minted - fee, fee);
    vm.prank(user);
    (uint256 shares, uint256 debt) =
      facility.enter(address(pmMulti), ENTER_AMOUNT, previewDebt, previewDebt, previewShares, user);

    assertEq(debt, 350e6, "debt leg");
    assertEq(pmMulti.totalSupply() - supplyBefore, minted, "minted");
    assertEq(shares, minted - fee, "net shares");
    assertEq(previewDebt, debt, "preview debt");
    assertEq(previewShares, shares, "preview shares");
    assertEq(previewFee, fee, "preview fee");
    _assertCleanOn(pmMulti);
  }

  function testFuzz_enter_sharedQuoteStaysWithinTheFairFraction(
    uint256 amount,
    uint256 price,
    uint256 elapsed,
    bool headB
  ) public {
    _setMultiPmFees();
    if (headB) _setSupplyQueue(pmMulti, address(moduleB), address(moduleA));
    vm.warp(block.timestamp + bound(elapsed, 0, 90 days));
    oracle.setPrice(bound(price, 0.9e24, 1.5e24));
    amount = bound(amount, pmMulti.collateralAmount().divUp(pmMulti.debtAmount()), pmMulti.collateralAmount());

    uint256 supplyAdj = _adjustedSupply(pmMulti);
    uint256 totalAssets = pmMulti.totalAssets();
    uint256 fair = supplyAdj.mulDiv(amount, pmMulti.collateralAmount());
    // Each module floors its quote and the debt leg floors once: for c <= C the mint sits under
    // 3 quoted units above the fair fraction and the preview under 4 units off the mint.
    uint256 overMintSlack = supplyAdj.mulDivUp(3, totalAssets + 1);
    uint256 previewSlack = supplyAdj.mulDivUp(4, totalAssets + 1) + 1;
    (, uint256 previewShares, uint256 previewFee) = facility.previewEnter(address(pmMulti), amount);
    uint256 supplyBefore = pmMulti.totalSupply();
    uint256 pendingFeeShares = supplyAdj - supplyBefore - pmMulti.virtualShareOffset();

    _enter(pmMulti, user, amount, user);

    uint256 minted = pmMulti.totalSupply() - supplyBefore - pendingFeeShares;
    assertLe(minted, fair + overMintSlack, "over-mint beyond rounding");
    assertApproxEqAbs(previewShares + previewFee, minted, previewSlack, "preview mint");
    assertGe(pmMulti.totalAssets() * supplyAdj, totalAssets * _adjustedSupply(pmMulti), "holders diluted");
  }

  function test_enter_divergentReceivingQuoteRevertsNonNeutralMint() public {
    (PositionManager split, OracleMock oracleB) = _deploySplitQuotePm(DEBT_A, DEBT_B);
    oracleB.setPrice(1.2e24);
    assertFalse(split.hasBadDebt(), "bad debt");
    // A quotes 6_000e6 and B 4_800e6 against 3_500e6 of debt.
    assertEq(split.totalAssets(), 7_300e6, "equity");
    // One wei over a round fraction so the fair share floors.
    uint256 amount = ENTER_AMOUNT + 1;
    uint256 supplyAdj = _adjustedSupply(split);
    // B takes the collateral and quotes it 1_200e6 against the pool-ratio debt leg of 350e6.
    uint256 minted = uint256(850e6).mulDiv(supplyAdj, 7_300e6 + 1);
    uint256 expected = supplyAdj.mulDiv(amount, 10_000e18);

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonNeutralMint.selector, minted, expected));
    facility.enter(address(split), amount, 0, type(uint256).max, 0, user);
  }

  function test_enter_overQuoteAtTheToleranceMints() public {
    (PositionManager split, OracleMock oracleB) = _deploySplitQuotePm(DEBT_A, DEBT_B);
    oracleB.setPrice(1.1e24);
    assertEq(split.totalAssets(), 6_900e6, "equity");
    uint256 supplyAdj = _adjustedSupply(split);
    // B quotes the amount at 577 units against a 183-unit debt leg.
    uint256 minted = uint256(394).mulDiv(supplyAdj, 6_900e6 + 1);
    uint256 tolerance = supplyAdj.mulDivUp(32, 6_900e6 + 1) + 1;
    assertEq(minted, supplyAdj.mulDiv(TOLERANCE_EDGE, 10_000e18) + tolerance, "not at the tolerance");
    uint256 supplyBefore = split.totalSupply();

    (, uint256 debt) = _enter(split, user, TOLERANCE_EDGE, user);

    assertEq(debt, 183, "debt leg");
    assertEq(split.totalSupply() - supplyBefore, minted, "minted");
  }

  function test_enter_overQuoteOneShareAboveTheToleranceRevertsNonNeutralMint() public {
    (PositionManager split, OracleMock oracleB) = _deploySplitQuotePm(DEBT_A, DEBT_B);
    oracleB.setPrice(1.1e24);
    uint256 amount = TOLERANCE_EDGE - 1;
    uint256 supplyAdj = _adjustedSupply(split);
    // Same quote and debt leg as the edge, one wei less collateral: the fair fraction drops by one.
    uint256 minted = uint256(394).mulDiv(supplyAdj, 6_900e6 + 1);
    uint256 expected = supplyAdj.mulDiv(amount, 10_000e18);
    uint256 tolerance = supplyAdj.mulDivUp(32, 6_900e6 + 1) + 1;
    assertEq(minted, expected + tolerance + 1, "not one share above");

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonNeutralMint.selector, minted, expected));
    facility.enter(address(split), amount, 0, type(uint256).max, 0, user);
  }

  function test_enter_receivingQuoteAtTheDebtLegRevertsZeroMint() public {
    (PositionManager split, OracleMock oracleB) = _deploySplitQuotePm(3_500e6, 0);
    oracleB.setPrice(0.35e24);
    assertFalse(split.hasBadDebt(), "bad debt");
    // A quotes 6_000e6 and the unlevered B 1_400e6 against 3_500e6 of debt.
    assertEq(split.totalAssets(), 3_900e6, "equity");

    // B quotes the 1_000e18 at 350e6, exactly the debt leg: the deposit adds no equity.
    _fundEntrant(user, ENTER_AMOUNT);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, 0, 0));
    facility.enter(address(split), ENTER_AMOUNT, 0, type(uint256).max, 0, user);
  }

  function test_enter_divergentUnderQuoteMintsBelowTheFairFraction() public {
    (PositionManager split, OracleMock oracleB) = _deploySplitQuotePm(DEBT_A, DEBT_B);
    oracleB.setPrice(0.9e24);
    // A quotes 6_000e6 and B 3_600e6 against 3_500e6 of debt.
    assertEq(split.totalAssets(), 6_100e6, "equity");
    uint256 supplyAdj = _adjustedSupply(split);
    uint256 supplyBefore = split.totalSupply();

    _enter(split, user, ENTER_AMOUNT, user);

    // B quotes the 1_000e18 at 900e6 against the 350e6 debt leg: holders keep the gap.
    uint256 minted = split.totalSupply() - supplyBefore;
    assertEq(minted, uint256(550e6).mulDiv(supplyAdj, 6_100e6 + 1), "minted");
    assertGt(split.totalAssets() * supplyAdj, 6_100e6 * _adjustedSupply(split), "holders' equity per share");
  }

  function test_enter_divergentUnderQuoteRevertsAtThePreviewMinSharesOut() public {
    (PositionManager split, OracleMock oracleB) = _deploySplitQuotePm(DEBT_A, DEBT_B);
    oracleB.setPrice(0.9e24);
    uint256 supplyAdj = _adjustedSupply(split);
    (, uint256 previewShares, uint256 previewFee) = facility.previewEnter(address(split), ENTER_AMOUNT);
    // The preview prices the entry at the pool quote: 9_600e6 * 10% - 350e6.
    assertEq(previewShares + previewFee, uint256(610e6).mulDiv(supplyAdj, 6_100e6 + 1), "preview mint");
    uint256 minted = uint256(550e6).mulDiv(supplyAdj, 6_100e6 + 1);
    uint256 shares = minted - minted.mulDivUp(DEFAULT_FEE_BPS, BPS);

    _fundEntrant(user, ENTER_AMOUNT);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, shares, previewShares));
    facility.enter(address(split), ENTER_AMOUNT, 0, type(uint256).max, previewShares, user);
  }

  function test_enter_manyTimesThePoolRevertsNonNeutralMintAndFitsSplit() public {
    // both modules sit one wei short of their next quote unit: each floors almost a unit
    _donateCollateral(marketParams, address(moduleA), CARRY);
    _donateCollateral(marketParamsB, address(moduleB), CARRY);
    uint256 totalCollateral = 10_000e18 + 2 * CARRY;
    assertEq(pmMulti.collateralAmount(), totalCollateral, "collateral");
    assertEq(pmMulti.totalAssets(), 6_500e6, "equity");
    // 40 times the pool, all supplied to A and quoted at 400_000e6 against a 139_999_999_972 debt leg
    uint256 amount = 400_000e18;
    uint256 supplyAdj = _adjustedSupply(pmMulti);
    uint256 minted = uint256(260_000_000_028).mulDiv(supplyAdj, 6_500e6 + 1);
    uint256 expected = supplyAdj.mulDiv(amount, totalCollateral);
    uint256 tolerance = supplyAdj.mulDivUp(32, 6_500e6 + 1) + 1;
    assertGt(minted, expected + tolerance, "fixture: within the tolerance");

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonNeutralMint.selector, minted, expected));
    facility.enter(address(pmMulti), amount, 0, type(uint256).max, 0, user);

    vm.startPrank(user);
    (uint256 first, uint256 firstDebt) = facility.enter(address(pmMulti), amount / 2, 0, type(uint256).max, 0, user);
    (uint256 second, uint256 secondDebt) = facility.enter(address(pmMulti), amount / 2, 0, type(uint256).max, 0, user);
    vm.stopPrank();

    assertEq(underlyingToken.balanceOf(user), 0, "entered in full");
    assertEq(pmMulti.balanceOf(user), first + second, "shares");
    assertEq(pmMulti.collateralAmount(), totalCollateral + amount, "collateral entered");
    assertEq(pmMulti.debtAmount(), 3_500e6 + firstDebt + secondDebt, "debt borrowed");
    _assertCleanOn(pmMulti);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            EXIT                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_fullQueueMatchesPreviewToTheWeiAndRefundsExactly() public {
    _setMultiPmFees();
    (uint256 shares,) = _enter(pmMulti, user, ENTER_AMOUNT, user);
    vm.warp(block.timestamp + 90 days);
    oracle.setPrice(1.1e24);
    uint256 exitShares = shares / 2;
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee, uint256 required) =
      facility.previewExit(address(pmMulti), exitShares);
    assertEq(required - previewDebtIn, previewDebtIn.mulDivUp(10, 10_000) + 1, "10 bps + 1 headroom");
    uint256 collateralBefore = pmMulti.collateralAmount();
    uint256 feeSharesBefore = pmMulti.balanceOf(feeRecipient);

    _fundExit(exitShares, required);
    vm.expectEmit(address(facility));
    emit IInKindFacility.Exited(
      address(pmMulti), user, receiver, previewOut, previewDebtIn, exitShares - previewFee, previewFee
    );
    vm.prank(user);
    (uint256 out, uint256 debtIn) = facility.exit(address(pmMulti), exitShares, required, previewOut, receiver, "");

    assertEq(out, previewOut, "underlying out");
    assertEq(debtIn, previewDebtIn, "debt in");
    assertEq(debtToken.balanceOf(user), required - previewDebtIn, "refund");
    assertEq(underlyingToken.balanceOf(receiver), previewOut, "receiver underlying");
    assertEq(pmMulti.collateralAmount(), collateralBefore - previewOut, "PM collateral");
    assertEq(pmMulti.balanceOf(feeRecipient) - feeSharesBefore, previewFee, "fee shares");
    assertEq(facility.getExit(address(pmMulti)).cap, EXIT_CAP - previewDebtIn, "exit cap");
    _assertCleanOn(pmMulti);
  }

  function testFuzz_exit_fullQueueMirrorsBurnExactly(
    uint256 exitShares,
    uint256 elapsed,
    uint256 price,
    uint24 feeBps,
    bool queueBFirst
  ) public {
    _setMultiPmFees();
    feeBps = uint24(bound(feeBps, 0, MAX_FEE));
    _setExit(pmMulti, EXIT_CAP, FAR_EXPIRY, feeBps);
    if (queueBFirst) _setWithdrawalQueue(pmMulti, address(moduleB), address(moduleA));
    (uint256 shares,) = _enter(pmMulti, user, ENTER_AMOUNT, user);
    vm.warp(block.timestamp + bound(elapsed, 0, 180 days));
    oracle.setPrice(bound(price, 0.9e24, 2e24));
    exitShares = bound(exitShares, 2, shares);

    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee, uint256 required) =
      facility.previewExit(address(pmMulti), exitShares);
    uint256 collateralBefore = pmMulti.collateralAmount();
    uint256 feeSharesBefore = pmMulti.balanceOf(feeRecipient);

    (uint256 out, uint256 debtIn) = _exitExact(exitShares, required, previewOut);

    assertEq(out, previewOut, "underlying out");
    assertEq(debtIn, previewDebtIn, "debt in");
    assertEq(debtToken.balanceOf(user), required - previewDebtIn, "refund");
    assertEq(pmMulti.collateralAmount(), collateralBefore - previewOut, "PM collateral");
    assertEq(pmMulti.balanceOf(feeRecipient) - feeSharesBefore, previewFee, "fee shares");
    _assertCleanOn(pmMulti);
  }

  function test_exit_roundTripShiftsThePositionToTheSupplyQueueHead() public {
    _assertModule(moduleA, marketParams, COLLATERAL_A, DEBT_A);
    _assertModule(moduleB, marketParamsB, COLLATERAL_B, DEBT_B);

    (uint256 shares, uint256 debt) = _enter(pmMulti, user, ENTER_AMOUNT, user);

    // the supply-queue head takes the whole entry
    assertEq(debt, 350e6, "debt leg");
    _assertModule(moduleA, marketParams, 7_000e18, 1_850e6);
    _assertModule(moduleB, marketParamsB, COLLATERAL_B, DEBT_B);

    // the burn takes the same slice of every module
    uint256 burnShares = shares - shares.mulDivUp(DEFAULT_FEE_BPS, BPS);
    uint256 supplyAdj = _adjustedSupply(pmMulti);
    uint256 out = uint256(11_000e18).mulDiv(burnShares, supplyAdj);
    uint256 debtIn = uint256(3_850e6).mulDivUp(burnShares, supplyAdj);
    uint256 outA = uint256(7_000e18).mulDiv(out, 11_000e18);
    uint256 debtInA = uint256(1_850e6).mulDiv(debtIn, 3_850e6);
    _exitExact(shares, _required(debtIn), out);

    _assertModule(moduleA, marketParams, 7_000e18 - outA, 1_850e6 - debtInA);
    _assertModule(moduleB, marketParamsB, COLLATERAL_B - (out - outA), DEBT_B - (debtIn - debtInA));
    assertGt(7_000e18 - outA, COLLATERAL_A, "head collateral grew");
    assertGt(1_850e6 - debtInA, DEBT_A, "head debt grew");
    assertGt(out - outA, 0, "tail collateral shrank");
    assertGt(debtIn - debtInA, 0, "tail debt shrank");
    _assertCleanOn(pmMulti);
  }

  function test_exit_strictSubsetQueueLeavesTheExcludedModulePenaltyOnStayers() public {
    (uint256 shares,) = _enter(pmMulti, user, ENTER_AMOUNT, user);
    _setWithdrawalQueue(pmMulti, address(moduleA), address(0));
    // B (50% LTV) crosses the 80% LLTV at a 0.6 quote; A and the pool stay under the PM target.
    oracle.setPrice(0.6e24);
    assertFalse(pmMulti.hasBadDebt(), "bad debt");

    uint256 snapshot = vm.snapshotState();
    uint256 penalty = _liquidateModuleB();
    uint256 seederClaimStaying = _claim(seeder);
    vm.revertToState(snapshot);

    Position memory positionB = morpho.position(marketParamsB.id(), address(moduleB));
    uint256 supplyAdj = _adjustedSupply(pmMulti);
    uint256 burnShares = shares - shares.mulDivUp(DEFAULT_FEE_BPS, BPS);
    uint256 expectedOut = pmMulti.collateralAmount().mulDiv(burnShares, supplyAdj);
    uint256 expectedDebtIn = pmMulti.debtAmount().mulDivUp(burnShares, supplyAdj);
    uint256 required = _required(expectedDebtIn);
    (uint256 out, uint256 debtIn) = _exitExact(shares, required, 0);
    // The exiter takes its slice of the whole pool, the excluded module included, from A alone.
    assertEq(out, expectedOut, "underlying out");
    assertEq(debtIn, expectedDebtIn, "debt in");
    assertEq(debtToken.balanceOf(user), required - expectedDebtIn, "refund");
    Position memory positionBAfter = morpho.position(marketParamsB.id(), address(moduleB));
    assertEq(positionBAfter.collateral, positionB.collateral, "B collateral moved");
    assertEq(positionBAfter.borrowShares, positionB.borrowShares, "B debt moved");

    assertGt(penalty, 0, "no penalty");
    assertEq(_liquidateModuleB(), penalty, "penalty changed by the exit");
    // The seeder also carries its pro-rata of the part of the penalty the exiter left behind.
    uint256 exitersPart = penalty.mulDiv(burnShares, supplyAdj);
    uint256 seederExtra = pmMulti.balanceOf(seeder).mulDiv(exitersPart, _adjustedSupply(pmMulti));
    assertApproxEqAbs(seederClaimStaying - _claim(seeder), seederExtra, 2, "stayers' extra loss");
  }

  function test_exit_strictSubsetQueueNeedsTheRemainingModuleUnderTheTargetLtv() public {
    (uint256 shares,) = _enter(pmMulti, user, ENTER_AMOUNT, user);
    _setWithdrawalQueue(pmMulti, address(moduleB), address(0));
    // B (50% LTV) quotes 71.4% at 0.7: above the PM target, under its safeLtv
    oracle.setPrice(0.7e24);
    (uint256 debtIn,,, uint256 required) = facility.previewExit(address(pmMulti), shares);
    _fundExit(shares, required);

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibManagerErrors.InsufficientAvailableCollateral.selector));
    facility.exit(address(pmMulti), shares, required, 0, receiver, "");

    _setWithdrawalQueue(pmMulti, address(moduleA), address(moduleB));
    vm.prank(user);
    (, uint256 repaid) = facility.exit(address(pmMulti), shares, required, 0, receiver, "");
    assertEq(repaid, debtIn, "debt in");
  }

  function test_previewExit_strictSubsetQueueRevertsWhereBurnDoes() public {
    _setWithdrawalQueue(pmMulti, address(moduleA), address(0));
    // 60% of the supply repays ~2_100 of debt, above A's 1_500: burn cannot place it
    uint256 shares = pmMulti.balanceOf(seeder) * 6 / 10;
    uint256 debtA = moduleA.totalBorrowed();
    vm.expectRevert(LibManagerErrors.ExcessDebtRepay.selector);
    facility.previewExit(address(pmMulti), shares);

    // the debt it would repay, priced on the whole pool, is more than the queue holds
    uint256 burnShares = shares - shares.mulDivUp(DEFAULT_FEE_BPS, BPS);
    assertGt(pmMulti.debtAmount().mulDivUp(burnShares, _adjustedSupply(pmMulti)), debtA, "slice above the queue");
    uint256 required = _required(pmMulti.debtAmount().mulDivUp(burnShares, _adjustedSupply(pmMulti)));
    debtToken.setBalance(seeder, required);
    vm.startPrank(seeder);
    debtToken.approve(address(facility), required);
    pmMulti.approve(address(facility), shares);
    vm.expectRevert(LibManagerErrors.ExcessDebtRepay.selector);
    facility.exit(address(pmMulti), shares, required, 0, seeder, "");
    vm.stopPrank();
  }

  function test_maxExit_strictSubsetQueueIsBoundedByTheQueuedDebt() public {
    uint256 full = facility.maxExit(address(pmMulti));
    _setWithdrawalQueue(pmMulti, address(moduleA), address(0));
    uint256 max = facility.maxExit(address(pmMulti));
    assertLt(max, full, "the queue binds below the cap");

    // the cap is 1m, so A's debt is the bound: the largest burn whose rounded-up slice fits it
    uint256 burnable = moduleA.totalBorrowed().mulDiv(_adjustedSupply(pmMulti), pmMulti.debtAmount());
    assertEq(max, LibInKindView.grossForNet(burnable, DEFAULT_FEE_BPS), "maxExit");

    // the quote previews and executes, and one burnable share more does not preview
    (uint256 debtIn,,,) = facility.previewExit(address(pmMulti), max);
    assertLe(debtIn, moduleA.totalBorrowed(), "slice fits A");
    vm.expectRevert(LibManagerErrors.ExcessDebtRepay.selector);
    facility.previewExit(address(pmMulti), LibInKindView.grossForNet(burnable + 1, DEFAULT_FEE_BPS));
    _exit(pmMulti, seeder, max, seeder);
  }
}
