// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {STORAGE_SLOT} from "src/libs/manager/LibConstants.sol";
import {IPositionManagerAdmin, WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManagerFeeReferenceTest
/// @notice Tests for the held performance reference (high-water mark) and the basis-preserving
///         flow rebase.
/// @dev Reproduces the "periodic oracle, continuous debt" cadence that exposed the debt-carry
///      write-off: the collateral quote is held flat while Morpho debt accrues (market 1 uses
///      IrmMock, so warping time grows the debt), then the quote is stepped once. The performance
///      fee at the step must be charged net of the full flat-period debt carry, not just the last
///      accrual interval's, and a drawdown must not reset the reference downward.
contract PositionManagerFeeReferenceTest is PositionManagerBaseTest {
  using FixedPointMathLib for uint256;

  uint24 constant PERF_FEE = 1500; // 15%, mirrors the production vault
  uint24 constant MGMT_FEE = 15; // 15 bps per year, mirrors the production vault

  uint24 internal currentMgmtFee;
  uint24 internal currentPerfFee;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _setFees(uint24 managementFee, uint24 performanceFee) internal {
    currentMgmtFee = managementFee;
    currentPerfFee = performanceFee;
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);
  }

  /// @dev Triggers a fee accrual without any capital flow by re-applying the same fee config.
  function _accrue() internal {
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, currentMgmtFee, currentPerfFee);
  }

  function _leveredDeposit(uint256 collateral, uint256 debt) internal {
    _mintCollateral(minter, collateral);
    vm.prank(minter);
    positionManager.deposit(collateral, debt);
  }

  /// @dev Signed pending performance basis against the stored reference, replicating the
  ///      `_pendingFees` math (`mulDivUp(lastDebt, currentCollat, lastCollat) - currentDebt`).
  ///      Only valid while no position is in bad debt (aggregates are unfiltered here).
  function _pendingBasis() internal view returns (int256) {
    uint256 refDebt = positionManager.lastDebt();
    if (refDebt == 0) return 0;
    uint256 refCollat = _lastTotalAssets() + refDebt;
    uint256 currentDebt = positionManager.debtAmount();
    uint256 currentCollat = positionManager.totalAssets() + currentDebt;
    uint256 scaledRefDebt = refDebt.mulDivUp(currentCollat, refCollat);
    return int256(scaledRefDebt) - int256(currentDebt);
  }

  /// @dev The held management fee accumulator (management fees charged and not yet netted
  ///      against a crystallized basis, deducted from the next positive basis).
  function _heldManagementFees() internal view returns (uint256) {
    (,,,,, uint256 held) = positionManager.feeData();
    return held;
  }

  /// @dev Permissionless dust repay on the interest-free module: anyone can repay on the
  ///      module's behalf through the underlying market, nudging its debt down (and NAV up)
  ///      by 1e6 — enough to flip a flat basis dust-positive.
  function _dustRepayMarket2() internal {
    debtToken.setBalance(user, 1e6);
    vm.startPrank(user);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.repay(marketParams2, 1e6, 0, address(borrowPosition2), "");
    vm.stopPrank();
  }

  /// @dev Expected management fee assets for one accrual interval, replicating `_pendingFees`.
  function _expectedMgmtAssets(uint256 elapsed) internal view returns (uint256) {
    uint256 collatQuoted = positionManager.totalAssets() + positionManager.debtAmount();
    return collatQuoted.mulDiv(uint256(currentMgmtFee) * elapsed, 10_000 * 365 days);
  }

  /// @dev Expected perf fee shares for a given basis under a perf-only config, replicating the
  ///      `_pendingFees` share conversion against the fee-adjusted base.
  function _expectedPerfShares(uint256 basis) internal view returns (uint256) {
    uint256 perfAssets = basis * currentPerfFee / 10_000;
    uint256 totalAssets_ = positionManager.totalAssets();
    if (perfAssets >= totalAssets_) return 0;
    uint256 supply = positionManager.totalSupply();
    uint256 offset = positionManager.virtualShareOffset();
    return perfAssets * (supply + offset) / (totalAssets_ - perfAssets + 1);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*             PROBLEM 1: DEBT-CARRY WRITE-OFF                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Core fix: during a flat-quote stretch the reference is held, so the fee charged at
  ///         the repricing step nets the FULL flat-period debt carry, not just the last interval.
  function test_debtCarry_fullPeriodNettedAtRepricing() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 refTotalAssets = _lastTotalAssets();
    uint256 refDebt = positionManager.lastDebt();
    assertEq(refDebt, DEBT_AMOUNT, "reference seeded by the deposit");

    // Flat month: several accruals while debt grows. Each one must HOLD the reference.
    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    assertEq(positionManager.lastDebt(), refDebt, "reference debt held through flat accruals");
    assertEq(_lastTotalAssets(), refTotalAssets, "reference NAV held through flat accruals");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no perf fee while the quote is flat");

    uint256 debtPreJump = positionManager.debtAmount();
    assertGt(debtPreJump, refDebt, "debt accrued during the flat period");
    uint256 collatPreJump = positionManager.totalAssets() + debtPreJump;

    // The oracle finally reprices: +2% step.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);

    uint256 currentDebt = positionManager.debtAmount();
    uint256 currentCollat = positionManager.totalAssets() + currentDebt;

    // Fixed behavior: basis against the month-old reference nets the full month of carry.
    uint256 fixedBasis = refDebt.mulDivUp(currentCollat, refTotalAssets + refDebt) - currentDebt;
    // Old (ratcheted) behavior: the reference would have advanced to the pre-jump state, writing
    // the accrued carry off the basis.
    uint256 ratchetedBasis = debtPreJump.mulDivUp(currentCollat, collatPreJump) - currentDebt;
    assertLt(fixedBasis, ratchetedBasis, "held reference must net more carry than the ratcheted one");
    // The written-off carry is exactly the flat-period debt growth (up to scaling), so the gap
    // must be at least the raw interest the old behavior forgot.
    assertGe(ratchetedBasis - fixedBasis, debtPreJump - refDebt, "gap covers the flat-period interest");

    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(fixedBasis), "fee charged on the carry-netted basis");
    assertGt(perfShares, 0, "genuine levered gain still crystallizes");
  }

  /// @notice The crystallized fee is invariant to how many accruals ran during the flat period.
  function test_debtCarry_invariantToAccrualCount() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 start = block.timestamp;
    uint256 snap = vm.snapshotState();

    // Variant A: a single accrual mid-period.
    vm.warp(start + 15 days);
    _accrue();
    vm.warp(start + 30 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    _accrue();
    uint256 feeSharesA = positionManager.balanceOf(feeRecipient);

    vm.revertToState(snap);

    // Variant B: ten accruals through the same period.
    for (uint256 i = 1; i <= 10; ++i) {
      vm.warp(start + i * 3 days);
      _accrue();
    }
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    _accrue();
    uint256 feeSharesB = positionManager.balanceOf(feeRecipient);

    assertGt(feeSharesA, 0, "fee crystallizes at the step");
    assertEq(feeSharesA, feeSharesB, "fee is invariant to the number of flat-period accruals");
  }

  /// @notice High-water mark: after a fee crystallizes at a peak, a drawdown and recovery back to
  ///         the same peak must not be charged again; only gains above the peak are.
  function test_highWaterMark_noRefeeOnRecovery() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Crystallize at the peak.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    _accrue();
    uint256 feeSharesAtPeak = positionManager.balanceOf(feeRecipient);
    assertGt(feeSharesAtPeak, 0, "fee crystallized at the peak");
    uint256 refDebtAtPeak = positionManager.lastDebt();

    // Drawdown: the reference must hold, not reset down to the trough.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 95 / 100);
    vm.warp(block.timestamp + 10 days);
    _accrue();
    assertEq(positionManager.lastDebt(), refDebtAtPeak, "reference held through the drawdown");
    assertEq(positionManager.balanceOf(feeRecipient), feeSharesAtPeak, "no fee in the trough");

    // Recovery to the same peak: debt accrued meanwhile, so the basis is still negative.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), feeSharesAtPeak, "recovery to the peak is not re-charged");

    // A genuine new high crystallizes only the increment above the held reference.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 125 / 100);
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "new high produces a positive basis");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(uint256(basis)), "only the increment above the HWM is charged");
  }

  /// @notice A bad-debt dip (all positions underwater) neither crystallizes a fee nor breaks
  ///         accrual, and the recovery is only charged above the pre-dip reference.
  function test_badDebt_dipAndRecoveryRespectsReference() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    uint256 refDebt = positionManager.lastDebt();

    // Crash far below water: collateral quote 40% => 4_000 quoted vs 5_000 debt.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);
    assertEq(positionManager.totalAssets(), 0, "all positions excluded as bad debt");
    _accrue();
    assertEq(positionManager.lastDebt(), refDebt, "reference held through the bad-debt dip");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no fee while underwater");

    // Recover to the starting quote: debt has grown, basis still negative, no fee.
    vm.warp(block.timestamp + 5 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "recovery to the reference is not charged");

    // Only a genuine gain above the pre-dip reference crystallizes.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    _accrue();
    assertGt(positionManager.balanceOf(feeRecipient), 0, "gain above the pre-dip reference is charged");
  }

  /// @notice A flow executed while every position is underwater must hold the reference (there is
  ///         no good-debt state to re-anchor on), so the recovery after the dip is still measured
  ///         against the pre-dip high-water mark instead of being re-charged from the trough.
  function test_badDebt_flowDuringDipHoldsReference() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    uint256 refDebt = positionManager.lastDebt();
    uint256 refTotalAssets = _lastTotalAssets();

    // Crash far below water: every position is excluded as bad debt.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);
    assertEq(positionManager.totalAssets(), 0, "all positions excluded as bad debt");

    // A dust deposit during the dip is a flow through the rebase (it mints zero shares at zero
    // NAV, i.e. a donation), and must not collapse the reference to the trough.
    _leveredDeposit(1, 0);
    assertEq(positionManager.lastDebt(), refDebt, "reference debt held across the underwater flow");
    assertEq(_lastTotalAssets(), refTotalAssets, "reference NAV held across the underwater flow");

    // Recovery back to the starting quote: still at the reference-implied high-water mark.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "recovery after the dip is not re-charged");

    // A genuine gain above the pre-dip reference still crystallizes.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    _accrue();
    assertGt(positionManager.balanceOf(feeRecipient), 0, "gain above the pre-dip reference is charged");
  }

  /// @notice Pins the documented limitation: a rescue flow that brings the pool back above water
  ///         re-anchors the reference at the post-flow state (the pre-flow basis is not measurable
  ///         against empty aggregates), so the recovery beyond that point is charged.
  function test_badDebt_rescueFlowReanchorsAtPostFlowState() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Crash below water, then rescue by repaying 2_000 debt: 4_000 quoted vs 3_000 debt is back
    // above water.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);
    uint256 repay = 2_000e18;
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: repay
    });
    RebalancingData memory data = RebalancingData({collateral: 0, debt: repay, operations: ops});
    _mintDebt(rebalancer, repay);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), repay);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    // Reference re-anchored at the post-rescue state.
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference debt re-anchored");
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference NAV re-anchored");
  }

  /// @notice Partial bad debt: one module dropping out of (and back into) the good-debt aggregate
  ///         around a flow must not manufacture a spurious positive basis on its recovery.
  function test_badDebt_partialModuleExclusionNoSpuriousFee() public {
    _setFees(0, PERF_FEE);

    // Two modules at different LTVs: bp1 at 40%, bp2 at 68%.
    SupplyQueueEntry[] memory queue1 = new SupplyQueueEntry[](1);
    queue1[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue1);
    _leveredDeposit(5_000e18, 2_000e18);

    SupplyQueueEntry[] memory queue2 = new SupplyQueueEntry[](1);
    queue2[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue2);
    _leveredDeposit(5_000e18, 3_400e18);

    // Price 0.65: bp2 (3_250 quoted vs 3_400 debt) is excluded, bp1 stays good.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 65 / 100);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no fee on the partial drawdown");

    // A flow against the reduced universe (routed to the healthy module).
    vm.prank(curator);
    positionManager.setSupplyQueue(queue1);
    _leveredDeposit(100e18, 0);
    assertEq(positionManager.balanceOf(feeRecipient), 0, "flow does not crystallize");

    // The excluded module re-enters the aggregates on recovery: the raw levered read can be
    // positive against the flow-preserved reference, but NAV still sits below the preserved
    // mark, so the capped basis is zero and nothing is pending or minted.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    assertLt(positionManager.totalAssets(), _lastTotalAssets(), "NAV below the preserved mark at re-entry");
    (,,, uint256 reentryShares) = positionManager.pendingFees();
    assertEq(reentryShares, 0, "module re-entry does not manufacture a fee");
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no fee on the module re-entry");

    // A genuine gain still crystallizes.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    _accrue();
    assertGt(positionManager.balanceOf(feeRecipient), 0, "genuine gain above the reference charges");
  }

  /// @dev Two-module fixture for the partial bad-debt window: module A holds little debt
  ///      (10_000 collat / 1_000 debt), module B is debt-heavy (10_000 / 5_000). The aggregate
  ///      reference is (20_000, 6_000), 30% LTV. A price drop to 0.45 excludes B
  ///      (4_500 quoted < 5_000 debt) while A stays good, leaving visible aggregates
  ///      (4_500, 1_000): the visible LTV (22%) sits below the reference LTV, so the naive basis
  ///      reads +350 although NAV fell 14_000 -> 3_500.
  function _setupDebtHeavyExclusionWindow() internal {
    SupplyQueueEntry[] memory queue1 = new SupplyQueueEntry[](1);
    queue1[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue1);
    _leveredDeposit(10_000e18, 1_000e18);

    SupplyQueueEntry[] memory queue2 = new SupplyQueueEntry[](1);
    queue2[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue2);
    _leveredDeposit(10_000e18, 5_000e18);

    assertEq(positionManager.lastDebt(), 6_000e18, "reference debt seeded on the full universe");
    assertEq(_lastTotalAssets(), 14_000e18, "reference NAV seeded on the full universe");
  }

  /// @notice Partial bad debt, debt-heavy module excluded (PR #202 review comment): the exclusion
  ///         deleverages the visible aggregate and the naive basis reads positive at the trough.
  ///         The accrual must not mint and must hold the reference until the module re-enters.
  function test_badDebt_partialExclusionOfDebtHeavyModuleMintsNoPhantomFee() public {
    _setFees(0, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    // 55% drop: B excluded, visible NAV collapses to A's 4_500 - 1_000.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);
    assertEq(positionManager.totalAssets(), 3_500e18, "visible NAV is the healthy module only");

    // The naive basis reads +350 here; nothing may be pending and nothing may mint.
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no phantom perf fee pending at the trough");
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no phantom perf fee minted at the trough");
    assertEq(positionManager.lastDebt(), 6_000e18, "reference debt held through the exclusion");
    assertEq(_lastTotalAssets(), 14_000e18, "reference NAV held through the exclusion");

    // Module A recovers inside the window (B still excluded): still frozen, still no fee.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 49 / 100);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "in-window recovery is not fresh alpha");
    assertEq(positionManager.lastDebt(), 6_000e18, "reference debt held through the in-window recovery");

    // Full recovery: B re-enters, the basis against the frozen reference is exactly zero.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "recovery to the mark is not charged");
    assertEq(positionManager.lastDebt(), 6_000e18, "zero basis does not advance the reference");

    // Only a genuine gain above the pre-dip mark crystallizes: basis = 6_000 * 21/20 - 6_000.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    (,,, perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(300e18), "only the increment above the pre-dip mark is charged");
    assertGt(perfShares, 0, "genuine gain still crystallizes after the window");
  }

  /// @notice The management fee is unaffected by a partial bad-debt window: it accrues on the
  ///         good-debt collateral, joins the held accumulator, and nets from the post-window
  ///         crystallization.
  function test_badDebt_partialExclusionManagementFeeStillAccruesAndNets() public {
    _setFees(MGMT_FEE, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    // Trough accrual after 10 days: management fee mints on A's collateral (4_500 quoted), the
    // reference stays frozen, and the charge joins the held accumulator.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);
    vm.warp(block.timestamp + 10 days);
    _accrue();
    uint256 mgmtSharesAtTrough = positionManager.balanceOf(feeRecipient);
    assertGt(mgmtSharesAtTrough, 0, "management fee still charged during the window");
    assertEq(positionManager.lastDebt(), 6_000e18, "reference held despite the management fee mint");
    uint256 expectedHeld = uint256(4_500e18).mulDiv(uint256(MGMT_FEE) * 10 days, 10_000 * 365 days);
    assertEq(_heldManagementFees(), expectedHeld, "window management fee joins the held accumulator");

    // Post-window gain: the crystallizing basis nets the held deduction, then the accumulator
    // clears with the advance.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    int256 basis = _pendingBasis();
    assertGt(basis, int256(expectedHeld), "gain above the mark exceeds the pending deduction");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(uint256(basis) - expectedHeld), "crystallization nets the held charge");
    _accrue();
    assertEq(_heldManagementFees(), 0, "accumulator clears when the reference advances");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference advanced with the crystallization");
  }

  /// @notice A window flow with a zero visible carry converts the deficit measured against the
  ///         reduced universe into the mark. Even though the deficit exceeds the post-flow debt,
  ///         the oversized-carry encoding keeps the reference out of the bootstrap sentinel, so
  ///         the window recovery is charged only past the preserved (per-share) mark instead of
  ///         being reseeded, and forgiven, at the trough.
  function test_badDebt_partialExclusionFlowPreservesMarkViaOversizedCarry() public {
    _setFees(0, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);

    // Unlevered deposit routed to the healthy module: the flow's accrual must not mint. The
    // visible carry reads zero (visible LTV 22% below reference LTV 30%), so the conversion
    // takes the deficit against the reduced universe (14_000 + 1_000 - 4_500 = 10_500, scaled
    // to 11_850); it exceeds the post-flow debt (1_000), so the mark re-anchors at
    // NAV + deficit (3_950 + 11_850) with the reference debt at the 30% pre-flow reference
    // LTV instead of collapsing to the sentinel.
    SupplyQueueEntry[] memory queue1 = new SupplyQueueEntry[](1);
    queue1[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue1);
    _leveredDeposit(1_000e18, 0);
    assertEq(positionManager.balanceOf(feeRecipient), 0, "window flow does not crystallize the phantom");
    uint256 mark = _lastTotalAssets();
    assertApproxEqAbs(mark, 15_800e18, 2, "mark preserved at NAV + the scaled deficit");
    assertEq(
      positionManager.lastDebt(),
      mark.mulDivUp(6_000e18, 14_000e18),
      "reference debt at the pre-flow reference LTV, not the sentinel"
    );

    // B re-enters on recovery: NAV (15_000) still sits below the preserved mark, so the
    // accrual holds and mints nothing.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "recovery below the preserved mark mints nothing");
    assertEq(_lastTotalAssets(), mark, "the accrual holds the preserved mark");

    // Fees resume only past the preserved mark, on the capped basis.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    uint256 navGain = positionManager.totalAssets() - _lastTotalAssets();
    assertGt(navGain, 0, "NAV cleared the preserved mark");
    uint256 basisUsed = uint256(_pendingBasis()).min(navGain);
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(basisUsed), "fees resume only above the preserved mark");
    assertGt(perfShares, 0, "genuine gain above the mark still charges");
  }

  /// @notice The bootstrap seed is also gated: a sentinel reference (`lastDebt == 0`) must not
  ///         reseed against the reduced universe mid-window, or the mark would anchor on
  ///         aggregates that misrepresent the pool and mis-measure the basis at re-entry.
  function test_badDebt_partialExclusionHoldsBootstrapSeed() public {
    _setFees(0, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);

    // Force the bootstrap sentinel (reachable via full repayment or the rebase carry clamp).
    // `lastDebt` occupies the 13th storage slot of the ERC-7201 struct (offset 12); the assert
    // below validates the offset.
    vm.store(address(positionManager), bytes32(uint256(STORAGE_SLOT) + 12), bytes32(0));
    assertEq(positionManager.lastDebt(), 0, "sentinel forced");

    // A mid-window accrual must hold the sentinel instead of seeding the reduced universe.
    _accrue();
    assertEq(positionManager.lastDebt(), 0, "no bootstrap seed against the reduced universe");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "sentinel accrual mints nothing");

    // The first post-window accrual seeds on the full universe; fees then resume normally.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertEq(positionManager.lastDebt(), 6_000e18, "reference reseeded on the full universe");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "the reseeding accrual mints nothing");

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(300e18), "post-reseed gains charge normally");
  }

  /// @notice A rescue repayment mid-window pulls the excluded module back above water. The
  ///         visible carry reads zero, so the conversion takes the deficit measured against the
  ///         reduced universe; it exceeds the post-rescue debt, and the oversized-carry
  ///         encoding re-anchors the mark at the post-rescue NAV plus the deficit (the
  ///         pre-episode mark adjusted for the rescue's own contribution) instead of writing
  ///         the sentinel, so the window recovery is charged only past that mark.
  function test_badDebt_partialExclusionRescueFlowPreservesMark() public {
    _setFees(0, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);

    // Rescue: the rebalancer repays 2_500 of B's debt, pulling B (4_500 quoted vs 2_500 debt)
    // back above water mid-flow. The visible carry reads zero, so the conversion picks up the
    // deficit (14_000 + 1_000 - 4_500 = 10_500); it exceeds the post-rescue debt (3_500), so
    // the mark re-anchors at NAV + deficit (5_500 + 10_500, the supply is unchanged) with the
    // reference debt at the 30% pre-flow reference LTV.
    uint256 repay = 2_500e18;
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.REPAY, amount: repay
    });
    RebalancingData memory data = RebalancingData({collateral: 0, debt: repay, operations: ops});
    _mintDebt(rebalancer, repay);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), repay);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "the rescue flow itself does not crystallize");
    assertEq(_lastTotalAssets(), 16_000e18, "mark preserved at the rescue-adjusted pre-episode level");
    assertEq(
      positionManager.lastDebt(),
      uint256(16_000e18).mulDivUp(6_000e18, 14_000e18),
      "reference debt at the pre-flow reference LTV, not the sentinel"
    );

    // Recovery to the original quote: NAV (16_500) clears the preserved mark by 500, and only
    // that excess is charged, not the trough-measured recovery.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    uint256 navGain = positionManager.totalAssets() - _lastTotalAssets();
    assertEq(navGain, 500e18, "recovery past the preserved mark");
    uint256 basisUsed = uint256(_pendingBasis()).min(navGain);
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(basisUsed), "only the excess above the preserved mark is charged");
    assertGt(perfShares, 0, "the excess above the mark charges");
  }

  /// @notice A flow that empties the good-debt universe (the owner removes the last healthy
  ///         module while the other stays underwater) must hold the reference: re-anchoring on
  ///         the empty aggregates would write the bootstrap sentinel, and the first
  ///         post-recovery accrual would then reseed the high-water mark at the trough and
  ///         charge the rest of the recovery as fresh gain.
  function test_badDebt_flowEmptyingGoodDebtUniverseHoldsReference() public {
    _setFees(0, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    // 55% drop: B (4_500 quoted vs 5_000 debt) is excluded, A stays good.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);

    // Post-crash cleanup: the owner removes the healthy module A mid-window (queues cleared
    // first; removal has no underwater precondition). The post-flow good-debt universe is empty
    // because only the underwater module B remains.
    vm.prank(curator);
    positionManager.setSupplyQueue(new SupplyQueueEntry[](0));
    vm.prank(curator);
    positionManager.setWithdrawalQueue(new address[](0));
    vm.prank(owner);
    positionManager.removeBorrowModule(address(borrowPosition1));
    assertEq(positionManager.totalAssets(), 0, "good-debt universe empty after the removal");
    assertEq(positionManager.lastDebt(), 6_000e18, "reference debt held across the emptying flow");
    assertEq(_lastTotalAssets(), 14_000e18, "reference NAV held across the emptying flow");

    // B re-enters on recovery: measured against the held full-universe mark, B alone
    // (10_000 / 5_000) sits below it, so the re-entry accrual neither charges nor reseeds.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "module re-entry is not charged");
    assertEq(positionManager.lastDebt(), 6_000e18, "reference still held after the re-entry");

    // Further recovery below the held mark is not charged either (with the sentinel written the
    // reseeded reference would have read this +500 gain as fresh alpha).
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "recovery below the held mark is not charged");
    assertEq(positionManager.lastDebt(), 6_000e18, "reference held through the recovery");

    // The levered read clears the held mark's LTV line once B's collateral clears 16_667
    // (price ~1.67), but the pool shrank permanently when A was removed: NAV at 1.70 is
    // 12_000, still below the held NAV mark of 14_000, so the NAV-gain cap keeps holding.
    // The owner escape hatch for such a permanent loss is resetPerformanceReference.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 170 / 100);
    assertGt(_pendingBasis(), 0, "the levered read clears the LTV line");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no fee while NAV sits below the held mark");
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "held accrual mints nothing");
    assertEq(positionManager.lastDebt(), 6_000e18, "reference held below the NAV mark");

    // Fees resume once NAV clears the held mark too: at price 2.05, NAV is 15_500 against the
    // 14_000 mark (gain 1_500) and the levered basis (6_000 * 20_500 / 20_000 - 5_000 = 1_150)
    // sits below that gain, so the levered slice is charged.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 205 / 100);
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "a genuine new high clears both marks");
    (,,, uint256 perfSharesResumed) = positionManager.pendingFees();
    assertEq(perfSharesResumed, _expectedPerfShares(uint256(basis)), "only the levered gain above the mark is charged");
  }

  /// @notice Bootstrap sentinel: a full debt repayment zeroes `lastDebt`; the next accrual must
  ///         skip the performance fee and reseed cleanly once leverage returns.
  function test_bootstrap_reseedsAfterFullRepayment() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Fully repay the debt: the flow rebase floors the reference debt at the sentinel.
    _mintDebt(minter, DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.withdraw(0, DEBT_AMOUNT, WithdrawalStrategy.PROPORTIONAL);
    assertEq(positionManager.lastDebt(), 0, "sentinel after full repayment");

    // A gain with the sentinel set must not charge a performance fee, only reseed.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    _leveredDeposit(1e18, DEBT_AMOUNT);
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no perf fee on the reseeding accrual");
    assertGt(positionManager.lastDebt(), 0, "reference reseeded with the new debt");

    // From the reseeded reference, the next gain charges normally.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    _accrue();
    assertGt(positionManager.balanceOf(feeRecipient), 0, "post-reseed gains charge normally");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 FLOWS PRESERVE THE BASIS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.°:°•.°+.*•´.*:˚.°*.˚•´.°•*/

  /// @notice A partial exit mid-flat-period takes its proportional slice of the carried basis:
  ///         the stayers' per-share pending basis is unchanged, and the fee at the step scales
  ///         with the remaining pool.
  function test_exit_takesItsCarrySliceWithoutDumpingOnStayers() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 15 days);
    _accrue();
    assertLt(_pendingBasis(), 0, "carry accumulated during the flat stretch");

    uint256 snap = vm.snapshotState();

    // Control: no exit; step and crystallize.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    _accrue();
    uint256 feeControl = positionManager.balanceOf(feeRecipient);
    assertGt(feeControl, 0, "control crystallizes");

    vm.revertToState(snap);

    // Exit half the pool, then the same step.
    int256 basisBefore = _pendingBasis();
    uint256 supplyBefore = positionManager.totalSupply();
    uint256 sharesToBurn = positionManager.balanceOf(minter) / 2;
    _mintDebt(minter, DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.burn(sharesToBurn, WithdrawalStrategy.PROPORTIONAL);

    int256 basisAfter = _pendingBasis();
    uint256 supplyAfter = positionManager.totalSupply();
    // Per-share pending basis is preserved across the exit (both bases are negative here).
    uint256 scaledCarry = uint256(-basisBefore).mulDiv(supplyAfter, supplyBefore);
    assertApproxEqAbs(uint256(-basisAfter), scaledCarry, 2, "per-share carry preserved by the exit");

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    _accrue();
    uint256 feeExit = positionManager.balanceOf(feeRecipient);
    // Half the pool remains, so the crystallized fee is about half the control's: the exit took
    // its carry slice along and did not shed it onto the stayers.
    assertApproxEqRel(feeExit, feeControl / 2, 0.001e18, "fee scales with the remaining pool");
  }

  /// @notice An exit-and-reenter round trip mid-flat-period cannot shed the accrued debt carry:
  ///         re-entering re-attaches the per-share carry, so the fee at the step matches a
  ///         continuous holder's.
  function test_exitAndReenter_cannotShedCarry() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 15 days);
    _accrue();

    uint256 snap = vm.snapshotState();

    // Control: continuous holder.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    _accrue();
    uint256 feeControl = positionManager.balanceOf(feeRecipient);

    vm.revertToState(snap);

    // Round trip: withdraw a slice, immediately redeposit the same amounts.
    uint256 outCollateral = 2_000e18;
    uint256 outDebt = 1_000e18;
    _mintDebt(minter, outDebt);
    vm.prank(minter);
    positionManager.withdraw(outCollateral, outDebt, WithdrawalStrategy.PROPORTIONAL);
    vm.prank(minter);
    positionManager.deposit(outCollateral, outDebt);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    _accrue();
    uint256 feeRoundTrip = positionManager.balanceOf(feeRecipient);

    assertApproxEqRel(feeRoundTrip, feeControl, 0.001e18, "round trip does not shed the carry");
  }

  /// @notice A pure flow mid-flat-period (at any LTV) preserves the per-share pending basis and
  ///         neither charges a fee nor creates a spurious pending gain.
  function test_flow_preservesPerShareBasisAtAnyLtv() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 15 days);
    _accrue();

    // Unlevered deposit (LTV below the pool's).
    int256 basisBefore = _pendingBasis();
    uint256 supplyBefore = positionManager.totalSupply();
    _leveredDeposit(1_000e18, 0);
    int256 basisAfter = _pendingBasis();
    uint256 supplyAfter = positionManager.totalSupply();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "flow does not charge a fee");
    assertLe(basisAfter, 0, "no spurious pending gain created by the flow");
    assertApproxEqAbs(
      uint256(-basisAfter),
      uint256(-basisBefore).mulDiv(supplyAfter, supplyBefore),
      2,
      "per-share carry preserved by an unlevered deposit"
    );

    // Levered deposit (LTV above the pool's).
    basisBefore = basisAfter;
    supplyBefore = supplyAfter;
    _leveredDeposit(1_000e18, 700e18);
    basisAfter = _pendingBasis();
    supplyAfter = positionManager.totalSupply();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "flow does not charge a fee");
    assertLe(basisAfter, 0, "no spurious pending gain created by the flow");
    assertApproxEqAbs(
      uint256(-basisAfter),
      uint256(-basisBefore).mulDiv(supplyAfter, supplyBefore),
      2,
      "per-share carry preserved by a levered deposit"
    );
  }

  /// @notice A rebalance is a flow, not a gain: it must not crystallize a fee and must preserve
  ///         the carried pending basis (share supply is unchanged).
  function test_rebalance_preservesCarry() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 15 days);
    _accrue();

    int256 basisBefore = _pendingBasis();
    assertLt(basisBefore, 0, "carry accumulated before the rebalance");

    // Move half the position from market 1 to market 2.
    uint256 moveDebt = 2_000e18;
    uint256 moveCollateral = 4_000e18;
    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: moveDebt
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: moveCollateral
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: moveCollateral
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: moveDebt
    });
    RebalancingData memory data = RebalancingData({collateral: 0, debt: moveDebt, operations: ops});

    _mintDebt(rebalancer, moveDebt);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), moveDebt);
    positionManager.rebalance(data, rebalancer);
    vm.stopPrank();

    assertEq(positionManager.balanceOf(feeRecipient), 0, "rebalance does not crystallize a fee");
    int256 basisAfter = _pendingBasis();
    assertLe(basisAfter, 0, "no spurious pending gain created by the rebalance");
    // Morpho share rounding can move the aggregates by a few wei during the round trip.
    assertApproxEqAbs(
      uint256(-basisAfter), uint256(-basisBefore), 10, "dollar carry preserved by a supply-neutral flow"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CROSS-CHECKS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice `pendingFees()` stays in lockstep with the shares actually minted by an accrual,
  ///         both while the reference is held and at crystallization.
  function test_pendingFees_lockstepWithAccrualUnderHeldReference() public {
    _setFees(MGMT_FEE, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Mid-flat: pending = mgmt only; accrual must mint exactly that.
    vm.warp(block.timestamp + 15 days);
    (,, uint256 mgmtPending, uint256 perfPending) = positionManager.pendingFees();
    assertEq(perfPending, 0, "no pending perf fee while the basis is negative");
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), mgmtPending, "held-reference accrual matches pendingFees");

    // At the step: pending = mgmt + perf; accrual must mint exactly that.
    vm.warp(block.timestamp + 15 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 103 / 100);
    (,, mgmtPending, perfPending) = positionManager.pendingFees();
    assertGt(perfPending, 0, "perf fee pending at the step");
    uint256 balanceBefore = positionManager.balanceOf(feeRecipient);
    _accrue();
    assertEq(
      positionManager.balanceOf(feeRecipient) - balanceBefore,
      mgmtPending + perfPending,
      "crystallizing accrual matches pendingFees"
    );
  }

  /// @notice A positive basis crystallizes at a zero rate while no fee recipient is set: the
  ///         reference advances, so enabling fees later never retroactively charges prior gains.
  function test_advance_noRecipientForgivesPriorGains() public {
    // No fee data configured at all: feeRecipient is address(0).
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);

    // Enabling fees accrues under the old (recipient-less) config first: the positive basis
    // advances the reference without minting.
    _setFees(0, PERF_FEE);
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no mint while the recipient was unset");
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference advanced at a zero rate");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference debt advanced");

    // No new gains: nothing to charge under the newly enabled fee.
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "prior gains are not retroactively charged");

    // Only gains made after enabling are charged.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 130 / 100);
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "post-enable gain produces a positive basis");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(uint256(basis)), "fee covers only post-enable gains");
  }

  /// @notice A positive basis crystallizes at a zero rate while performanceFee == 0 (management
  ///         fee only): the reference advances, so raising the rate later is not retroactive.
  function test_advance_zeroPerformanceRateStillAdvances() public {
    _setFees(MGMT_FEE, 0);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    vm.warp(block.timestamp + 10 days);
    _accrue();

    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference advanced despite zero perf rate");
    uint256 mgmtOnlyShares = positionManager.balanceOf(feeRecipient);
    assertGt(mgmtOnlyShares, 0, "management fee still minted");

    // Raising the performance rate afterwards charges nothing for the already-advanced gain.
    _setFees(MGMT_FEE, PERF_FEE);
    (,,, uint256 perfPending) = positionManager.pendingFees();
    assertEq(perfPending, 0, "prior gain is not charged after raising the rate");
  }

  /// @notice A small positive basis fully absorbed by the management-fee deduction still advances
  ///         the reference (the gain is written off the high-water mark, not carried forward).
  function test_advance_gainBelowManagementFeeStillAdvances() public {
    // Route to the interest-free market so the debt stays fixed and the basis stays small.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, 2000); // 2% per year mgmt so the deduction dominates the tiny gain
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 1001 / 1000); // +0.1%: basis ~5e18
    vm.warp(block.timestamp + 30 days); // mgmt deduction ~16e18 exceeds the basis

    int256 basis = _pendingBasis();
    assertGt(basis, 0, "basis is positive");
    (,,, uint256 perfPending) = positionManager.pendingFees();
    assertEq(perfPending, 0, "perf fee fully absorbed by the mgmt deduction");

    _accrue();
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference advanced despite zero perf mint");
  }

  /// @notice The fee-cap early return (management fee capped at totalAssets) mints nothing but
  ///         still advances the reference on a positive basis, and its back-out persists the
  ///         basis-consumed remainder of the held deduction, not a cleared one.
  function test_advance_feeCapEarlyReturnStillAdvances() public {
    // Route to the interest-free market so the position survives a long dormancy.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, 2000);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // A flat held stretch seeds the deduction before the cap binds.
    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();
    assertGt(held, 0, "management fees accumulated while held");

    // Dust-positive basis, then dormancy long enough for the mgmt fee cap to bind: the accrual
    // must advance on the basis, mint nothing, and consume only the basis slice of the deduction.
    _dustRepayMarket2();
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "dust repay flips the basis positive");
    assertLt(uint256(basis), held, "basis is dust next to the pending deduction");
    vm.warp(block.timestamp + 100 * 365 days);

    (,, uint256 mgmtPending, uint256 perfPending) = positionManager.pendingFees();
    assertEq(mgmtPending + perfPending, 0, "cap binds: no shares pending");

    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), feeSharesBefore, "no shares minted when the cap binds");
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference NAV advanced despite zero mint");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference debt advanced");
    assertEq(_heldManagementFees(), held - uint256(basis), "back-out persists the basis-consumed remainder");
  }

  /// @notice The management fee is time-based and independent of the performance reference: it
  ///         keeps accruing at the full rate while the reference is held.
  function test_managementFee_unaffectedByHeldReference() public {
    _setFees(MGMT_FEE, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 elapsed = 30 days;
    vm.warp(block.timestamp + elapsed);

    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "reference held, no perf fee");

    uint256 currentCollat = totalAssets_ + positionManager.debtAmount();
    uint256 expectedMgmtAssets = currentCollat.mulDiv(uint256(MGMT_FEE) * elapsed, 10_000 * 365 days);
    uint256 offset = positionManager.virtualShareOffset();
    uint256 expectedMgmtShares = expectedMgmtAssets * (totalSupply_ + offset) / (totalAssets_ - expectedMgmtAssets + 1);
    assertEq(mgmtShares, expectedMgmtShares, "management fee accrues at the full rate while held");

    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), mgmtShares, "management fee minted while held");
    assertEq(_lastFeeAccrualTimestamp(), block.timestamp, "timestamp advances on every accrual");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              MANAGEMENT FEE NETTING (HELD)                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Management fees minted while the reference is held accumulate and are deducted from
  ///         the next crystallization's basis, so the performance fee is net of the WHOLE
  ///         period's management fees, not only the last interval's.
  function test_managementFee_heldChargesDeductAtCrystallization() public {
    _setFees(200, PERF_FEE); // 2% per year management fee amplifies the netting signal
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Flat stretch: each accrual mints the management fee, holds the reference, and must add the
    // charged assets to the held accumulator.
    uint256 expectedHeld;
    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      expectedHeld += _expectedMgmtAssets(6 days);
      _accrue();
    }
    assertEq(_heldManagementFees(), expectedHeld, "held accumulator equals the charged management fees");
    assertGt(positionManager.balanceOf(feeRecipient), 0, "management fees still minted while held");

    // One more interval, then the oracle steps: the crystallizing fee nets held plus current.
    vm.warp(block.timestamp + 6 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);

    uint256 mgmtAssets = _expectedMgmtAssets(6 days);
    uint256 deduction = mgmtAssets + _heldManagementFees();
    int256 basis = _pendingBasis();
    assertGt(basis, int256(deduction), "gain clears the deduction");

    uint256 perfAssets = (uint256(basis) - deduction).mulDiv(uint256(PERF_FEE), 10_000);
    // The netting removes exactly perfRate x heldManagementFees relative to the single-interval
    // deduction of the unfixed accounting.
    uint256 perfAssetsIgnoringHeld = (uint256(basis) - mgmtAssets).mulDiv(uint256(PERF_FEE), 10_000);
    assertApproxEqAbs(
      perfAssetsIgnoringHeld - perfAssets,
      _heldManagementFees().mulDiv(uint256(PERF_FEE), 10_000),
      1,
      "netting removes exactly the held share of the fee"
    );

    // Replicate the share conversion of `_pendingFees` (combined first, then split).
    uint256 supply = positionManager.totalSupply();
    uint256 offset = positionManager.virtualShareOffset();
    uint256 feeAdjusted = positionManager.totalAssets() - mgmtAssets - perfAssets;
    uint256 expectedMgmtShares = mgmtAssets * (supply + offset) / (feeAdjusted + 1);
    uint256 expectedPerfShares = (mgmtAssets + perfAssets) * (supply + offset) / (feeAdjusted + 1) - expectedMgmtShares;
    (,, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    assertEq(mgmtShares, expectedMgmtShares, "management fee unaffected by the netting");
    assertEq(perfShares, expectedPerfShares, "perf fee nets the whole period's management fees");

    _accrue();
    assertEq(_heldManagementFees(), 0, "crystallization clears the accumulator");
  }

  /// @notice Whatever the accrual cadence through the flat period, the crystallized performance
  ///         fee equals perfRate x (basis - management fees charged since the last advance): a
  ///         mid-period accrual can no longer write its management fee out of the deduction.
  function test_managementFee_perfNetsChargedMgmtAtAnyCadence() public {
    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 start = block.timestamp;
    uint256[3] memory cadences = [uint256(1), 5, 10];

    for (uint256 c = 0; c < cadences.length; ++c) {
      uint256 snap = vm.snapshotState();
      uint256 accruals = cadences[c];

      uint256 chargedMgmt;
      for (uint256 i = 1; i <= accruals; ++i) {
        vm.warp(start + i * 30 days / accruals);
        chargedMgmt += _expectedMgmtAssets(30 days / accruals);
        _accrue();
      }
      assertEq(_heldManagementFees(), chargedMgmt, "accumulator tracks the charged fees");

      // Step at the period end; the crystallizing accrual is zero-elapsed, so the deduction is
      // the accumulator alone and the perf-only share conversion applies exactly.
      oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
      (,,, uint256 perfShares) = positionManager.pendingFees();
      assertEq(
        perfShares,
        _expectedPerfShares(uint256(_pendingBasis()) - chargedMgmt),
        "perf fee nets exactly the charged management fees"
      );
      assertGt(perfShares, 0, "gain crystallizes");

      vm.revertToState(snap);
      oracle.setPrice(DEFAULT_ORACLE_PRICE);
    }
  }

  /// @notice A positive basis smaller than the pending management fee deduction advances the
  ///         reference without a performance fee; the deduction is consumed only up to the basis
  ///         and the excess carries past the new mark (Cantina #6).
  function test_managementFee_heldDeductionAbsorbsSmallGain() public {
    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();

    // A small step: positive basis, but below the accumulated deduction.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 1005 / 1000);
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "gain is positive");
    assertLt(uint256(basis), held, "gain is below the pending deduction");

    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "deduction absorbs the whole gain");

    _accrue();
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference advances on the positive basis");
    assertEq(_heldManagementFees(), held - uint256(basis), "excess deduction carries past the new mark");
  }

  /// @notice Cantina #6: a dust-sized positive basis (a permissionless repay through the market)
  ///         advances the reference but consumes the held deduction only up to the basis; the
  ///         excess is carried instead of being written off, so the next crystallization is
  ///         still charged net of the fees already minted.
  function test_managementFee_dustBasisCarriesHeldDeductionExcess() public {
    // Route to the interest-free market so the basis stays exactly at the mark while held.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();
    assertGt(held, 0, "management fees accumulated while held");

    // Anyone can repay dust on behalf of the module: the next basis flips dust-positive.
    _dustRepayMarket2();

    int256 basis = _pendingBasis();
    assertGt(basis, 0, "dust repay flips the basis positive");
    assertLt(uint256(basis), held, "basis is dust next to the pending deduction");

    // Zero-elapsed accrual: no perf fee mints, the reference advances, and only the dust slice
    // of the deduction is consumed.
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "deduction absorbs the dust gain");
    _accrue();
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference advances on the dust basis");
    assertEq(_heldManagementFees(), held - uint256(basis), "only the basis slice of the deduction is consumed");

    // The next real gain is still charged net of the carried deduction.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    uint256 deduction = _heldManagementFees();
    (,,, uint256 stepShares) = positionManager.pendingFees();
    assertEq(
      stepShares,
      _expectedPerfShares(uint256(_pendingBasis()) - deduction),
      "crystallization nets the carried deduction"
    );
    assertGt(stepShares, 0, "the real gain still charges");
  }

  /// @notice A deposit/exit round trip must hand the pending deduction back whole: neither leg
  ///         rescales it, or reversible capital could repeat the cycle to grind the deduction
  ///         toward zero and overcharge the next crystallization.
  function test_flow_roundTripKeepsHeldManagementFeesNominal() public {
    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 15 days);
    _accrue();
    uint256 heldBefore = _heldManagementFees();
    assertGt(heldBefore, 0, "management fees accumulated while held");

    // Deposit doubling the pool, then burn exactly the minted shares in the same block (the
    // internal accruals are zero-elapsed): the vault returns to its pre-flow state and the
    // deduction must come back whole, not halved.
    uint256 supplyBefore = positionManager.totalSupply();
    uint256 balanceBefore = positionManager.balanceOf(minter);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    uint256 minted = positionManager.balanceOf(minter) - balanceBefore;
    assertEq(_heldManagementFees(), heldBefore, "deposit leaves the deduction nominal");

    _mintDebt(minter, 2 * DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.burn(minted, WithdrawalStrategy.PROPORTIONAL);

    assertEq(positionManager.totalSupply(), supplyBefore, "round trip restored the share supply");
    assertEq(_heldManagementFees(), heldBefore, "round trip hands the deduction back whole");
  }

  /// @notice A rescue deposit out of a full bad-debt episode mints shares against a zero asset
  ///         base (unmoored supply ratio); the pending deduction must stay nominal so the
  ///         post-recovery crystallization still charges, netting only fees actually minted.
  function test_managementFee_rescueDepositKeepsHeldDeductionNominal() public {
    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();
    assertGt(held, 0, "management fees accumulated while held");

    // Crash below water, then rescue with a collateral deposit that lifts the pool back above.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);
    assertEq(positionManager.totalAssets(), 0, "all positions excluded as bad debt");
    _leveredDeposit(4_000e18, 0);
    assertGt(positionManager.totalAssets(), 0, "rescue lifts the pool above water");
    assertEq(_heldManagementFees(), held, "deduction stays nominal across the rescue");

    // Recovery from the re-anchored trough: the crystallization charges net of the nominal
    // deduction only (an inflated deduction would swallow the whole gain).
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(
      perfShares,
      _expectedPerfShares(uint256(_pendingBasis()) - held),
      "crystallization nets exactly the fees actually charged"
    );
    assertGt(perfShares, 0, "recovery gain above the re-anchor still charges");
  }

  /// @notice Cantina #30: a dust deposit made while the pool is pinned at zero NAV (collateral
  ///         exactly equal to debt, still inside the good-debt universe) mints against the
  ///         virtual asset base and roughly doubles the supply; the held deduction must stay
  ///         nominal instead of scaling with that unmoored supply ratio.
  function test_managementFee_zeroNavDepositKeepsHeldDeductionNominal() public {
    // Route to the interest-free market so the debt stays put and NAV can be pinned exactly.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();
    assertGt(held, 0, "management fees accumulated while held");

    // Halve the price: quoted collateral == debt exactly, so NAV is zero while the module is
    // still included as good debt (the exclusion filter is `collateral >= debt`).
    oracle.setPrice(DEFAULT_ORACLE_PRICE / 2);
    assertEq(positionManager.totalAssets(), 0, "pool pinned at zero NAV");

    // A dust deposit mints against the virtual asset base and roughly doubles the supply.
    uint256 supplyBefore = positionManager.totalSupply();
    _leveredDeposit(2, 0);
    assertGe(positionManager.totalSupply(), 2 * supplyBefore, "dust deposit doubled the supply");
    assertEq(_heldManagementFees(), held, "deduction stays nominal across the zero-NAV deposit");
  }

  /// @notice Cantina #30, dust-positive variant: a permissionless dust repay lifts NAV one atom
  ///         off zero, so a zero-NAV guard alone would readmit the scaling; the mint denominator
  ///         is still virtually the offset base, and a matching dust deposit nearly doubles the
  ///         supply. The credit must stay nominal on any deposit.
  function test_managementFee_dustPositiveNavDepositKeepsHeldDeductionNominal() public {
    // Route to the interest-free market so the debt stays put and NAV can be pinned exactly.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();
    assertGt(held, 0, "management fees accumulated while held");

    // Pin NAV to zero, then dust-repay on the module: NAV is now dust-positive.
    oracle.setPrice(DEFAULT_ORACLE_PRICE / 2);
    _dustRepayMarket2();
    uint256 nav = positionManager.totalAssets();
    assertGt(nav, 0, "dust repay lifts NAV off zero");
    assertLt(nav, held, "NAV is dust next to the credit");

    // A NAV-sized dust deposit still mints against the virtual base and ~doubles the supply.
    uint256 supplyBefore = positionManager.totalSupply();
    _leveredDeposit(2 * nav, 0);
    assertGe(positionManager.totalSupply(), supplyBefore * 3 / 2, "dust deposit blew up the supply");
    assertEq(_heldManagementFees(), held, "deduction stays nominal across the dust-NAV deposit");
  }

  /// @notice A flow that burns the last share clears the pending deduction in the same
  ///         transaction: the empty-vault reseed clear only runs on a later accrual — and not
  ///         at all while bad debt is present — so the terminal clear in `rebaseSnapshot`
  ///         keeps a departed cohort's credit from sitting in storage for a future cohort
  ///         that never paid the fees (Cantina #7).
  function test_managementFee_fullExitClearsHeldDeduction() public {
    // Route to the interest-free market so the exit's proportional repay is exact: accrued
    // interest would leave wei-level debt dust that blocks the all-but-dust collateral
    // withdrawal on the way out.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    assertGt(_heldManagementFees(), 0, "management fees accumulated while held");

    // Consolidate every share on the minter (burn is MINTER_ROLE-gated), then exit fully.
    uint256 recipientShares = positionManager.balanceOf(feeRecipient);
    vm.prank(feeRecipient);
    positionManager.transfer(minter, recipientShares);

    _mintDebt(minter, 2 * DEBT_AMOUNT);
    uint256 minterShares = positionManager.balanceOf(minter);
    vm.prank(minter);
    positionManager.burn(minterShares, WithdrawalStrategy.PROPORTIONAL);

    assertEq(positionManager.totalSupply(), 0, "every share exited");
    assertEq(_heldManagementFees(), 0, "the last burn clears the deduction");

    // A fresh cohort starts with a clean slate.
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    assertEq(_heldManagementFees(), 0, "the new cohort inherits no deduction");
  }

  /// @notice A fee holiday (no recipient) neither wipes nor grows the deduction: it survives
  ///         held holiday accruals and still nets the crystallization once fees are re-enabled,
  ///         while a positive-basis advance during the holiday consumes it only up to the basis
  ///         (the no-recipient path honors the Cantina #6 carry too).
  function test_managementFee_holidayPreservesHeldDeduction() public {
    // Route to the interest-free market so the reference sits exactly at the mark while held
    // and a dust repay can flip the basis positive.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();
    assertGt(held, 0, "management fees accumulated while held");

    uint256 snap = vm.snapshotState();

    // Holiday: a held accrual on the no-recipient path charges nothing and keeps the deduction.
    vm.prank(owner);
    positionManager.setFeeData(address(0), 200, PERF_FEE);
    vm.warp(block.timestamp + 6 days);
    vm.prank(owner);
    positionManager.setFeeData(address(0), 200, PERF_FEE);
    assertEq(_heldManagementFees(), held, "holiday accrual neither wipes nor grows the deduction");

    // Re-enable fees (management rate zero isolates the pre-holiday deduction), then step: the
    // crystallization still nets the fees charged before the holiday.
    _setFees(0, PERF_FEE);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 102 / 100);
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(
      perfShares, _expectedPerfShares(uint256(_pendingBasis()) - held), "crystallization nets the pre-holiday charges"
    );

    // Variant: a dust-positive basis during the holiday advances without a mint and consumes
    // the deduction only up to the basis; the excess survives the holiday advance.
    vm.revertToState(snap);
    vm.prank(owner);
    positionManager.setFeeData(address(0), 200, PERF_FEE);
    _dustRepayMarket2();
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "dust repay flips the basis positive");
    assertLt(uint256(basis), held, "basis is dust next to the pending deduction");
    uint256 supplyBefore = positionManager.totalSupply();
    vm.prank(owner);
    positionManager.setFeeData(address(0), 200, PERF_FEE);
    assertEq(positionManager.totalSupply(), supplyBefore, "holiday advance mints nothing");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference advances on the dust basis");
    assertEq(_heldManagementFees(), held - uint256(basis), "holiday advance consumes only the basis slice");
  }

  /// @notice Accruals during a full bad-debt dip charge nothing (empty aggregates) and preserve
  ///         the deduction, so the post-recovery crystallization still nets the pre-dip fees.
  function test_managementFee_badDebtDipPreservesHeldDeduction() public {
    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    for (uint256 i = 0; i < 5; ++i) {
      vm.warp(block.timestamp + 6 days);
      _accrue();
    }
    uint256 held = _heldManagementFees();
    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);
    assertGt(held, 0, "management fees accumulated while held");

    // Crash below water; an accrual during the dip mints nothing and keeps the deduction.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);
    vm.warp(block.timestamp + 6 days);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), feeSharesBefore, "no management fee on empty aggregates");
    assertEq(_heldManagementFees(), held, "dip accrual preserves the deduction");

    // Recovery above the mark: the crystallization nets the pre-dip charges.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(
      perfShares, _expectedPerfShares(uint256(_pendingBasis()) - held), "crystallization nets the pre-dip charges"
    );
    assertGt(perfShares, 0, "gain above the pre-dip mark still charges");
  }

  /// @notice When the management fee cap binds on a held accrual (nothing is minted), the
  ///         unminted interval fee does not join the deduction.
  function test_managementFee_capGuardDoesNotGrowHeldDeduction() public {
    // Route to the interest-free market so the basis stays exactly at the mark through dormancy.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // A normal held accrual seeds the accumulator.
    vm.warp(block.timestamp + 30 days);
    _accrue();
    uint256 held = _heldManagementFees();
    assertGt(held, 0, "management fees accumulated while held");

    // Dormancy long enough for the cap to bind: the accrual mints nothing and must not grow the
    // deduction with a fee that was never charged.
    vm.warp(block.timestamp + 100 * 365 days);
    (,, uint256 mgmtPending, uint256 perfPending) = positionManager.pendingFees();
    assertEq(mgmtPending + perfPending, 0, "cap binds: no shares pending");
    _accrue();
    assertEq(_heldManagementFees(), held, "unminted interval fee does not join the deduction");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              OWNER RESET (ESCAPE HATCH)                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice After a drawdown the owner can force-advance the reference to the current state,
  ///         forgiving the carried negative basis so fees resume on gains from the trough onward
  ///         (a permanent loss would otherwise suppress performance fees indefinitely).
  function test_reset_forgivesCarryAfterDrawdown() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Crystallize at a peak, then draw down: the reference holds at the peak.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    _accrue();
    uint256 feeSharesAtPeak = positionManager.balanceOf(feeRecipient);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 95 / 100);
    vm.warp(block.timestamp + 10 days);
    assertLt(_pendingBasis(), 0, "carried basis is negative in the trough");

    // Owner accepts the loss and resets: the reference re-anchors at the trough.
    uint256 expectedAssets = positionManager.totalAssets();
    uint256 expectedDebt = positionManager.debtAmount();
    vm.expectEmit();
    emit IPositionManagerAdmin.PerformanceReferenceReset(expectedAssets, expectedDebt);
    vm.prank(owner);
    positionManager.resetPerformanceReference();
    assertEq(_lastTotalAssets(), expectedAssets, "reference NAV re-anchored at the current state");
    assertEq(positionManager.lastDebt(), expectedDebt, "reference debt re-anchored at the current state");
    assertEq(positionManager.balanceOf(feeRecipient), feeSharesAtPeak, "the reset itself mints nothing");

    // A gain that stays below the old peak now crystallizes against the reset reference.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "gain above the reset reference produces a positive basis");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(uint256(basis)), "fee charged from the trough onward");
    assertGt(perfShares, 0, "fees resume without recovering past the old mark");
  }

  /// @notice The reset starts a fresh fee period: the pending management fee deduction
  ///         (management fees charged and not yet netted against a crystallized basis) is
  ///         forgiven with it.
  function test_reset_clearsHeldManagementFees() public {
    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 15 days);
    _accrue();
    assertGt(_heldManagementFees(), 0, "management fees accumulated while held");

    vm.prank(owner);
    positionManager.resetPerformanceReference();
    assertEq(_heldManagementFees(), 0, "reset clears the pending management fee deduction");
  }

  /// @notice The reset is owner-only.
  function test_reset_onlyOwner() public {
    vm.prank(minter);
    vm.expectRevert();
    positionManager.resetPerformanceReference();
  }

  /// @notice A positive pending basis crystallizes through the accrual inside the reset, at the
  ///         configured rate and to the current recipient; the reset never forgives or double
  ///         charges a pending gain.
  function test_reset_positiveBasisCrystallizesBeforeReset() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    (,,, uint256 perfPending) = positionManager.pendingFees();
    assertGt(perfPending, 0, "gain pending before the reset");

    vm.prank(owner);
    positionManager.resetPerformanceReference();
    assertEq(positionManager.balanceOf(feeRecipient), perfPending, "pending gain crystallized by the accrual");
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference NAV at the current state");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference debt at the current state");

    // Nothing left to charge at the same state.
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), perfPending, "no double charge after the reset");
  }

  /// @notice The management fee (time-based) settles through the accrual inside the reset and the
  ///         accrual timestamp advances; the reset only touches the performance reference.
  function test_reset_managementFeeSettlesAndTimestampAdvances() public {
    _setFees(MGMT_FEE, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Drawdown plus elapsed time: the perf basis is negative but a management fee is pending.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 95 / 100);
    vm.warp(block.timestamp + 30 days);
    (,, uint256 mgmtPending, uint256 perfPending) = positionManager.pendingFees();
    assertGt(mgmtPending, 0, "management fee pending before the reset");
    assertEq(perfPending, 0, "no perf fee pending in the trough");

    vm.prank(owner);
    positionManager.resetPerformanceReference();
    assertEq(positionManager.balanceOf(feeRecipient), mgmtPending, "management fee settled through the reset");
    assertEq(_lastFeeAccrualTimestamp(), block.timestamp, "accrual timestamp advances with the reset");
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference NAV re-anchored");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference debt re-anchored");
  }

  /// @notice A reset during PARTIAL bad debt anchors on the reduced good-debt universe: the
  ///         excluded module's later recovery re-enters the basis as new gain and is charged
  ///         (the reset accepted that module's loss).
  function test_reset_duringPartialBadDebtAnchorsOnGoodDebtUniverse() public {
    _setFees(0, PERF_FEE);

    // Two modules at different LTVs: bp1 at 40%, bp2 at 68%.
    SupplyQueueEntry[] memory queue1 = new SupplyQueueEntry[](1);
    queue1[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue1);
    _leveredDeposit(5_000e18, 2_000e18);

    SupplyQueueEntry[] memory queue2 = new SupplyQueueEntry[](1);
    queue2[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue2);
    _leveredDeposit(5_000e18, 3_400e18);

    // Price 0.65: bp2 (3_250 quoted vs 3_400 debt) is excluded, bp1 stays good.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 65 / 100);
    vm.prank(owner);
    positionManager.resetPerformanceReference();
    assertEq(
      positionManager.lastDebt(), borrowPosition1.totalBorrowed(), "reference anchors on the good-debt module only"
    );
    assertLt(positionManager.lastDebt(), positionManager.debtAmount(), "excluded debt stays out of the reference");

    // Recovery: the excluded module re-enters above the reset reference and is charged as new gain.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertGt(positionManager.balanceOf(feeRecipient), 0, "re-entry above the reset reference is charged");
  }

  /// @notice A reset while every position is underwater writes the bootstrap sentinel: the next
  ///         accrual reseeds the reference at the state it observes, skipping the performance fee.
  function test_reset_duringBadDebtWritesSentinel() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);
    assertEq(positionManager.totalAssets(), 0, "all positions excluded as bad debt");
    vm.prank(owner);
    positionManager.resetPerformanceReference();
    assertEq(positionManager.lastDebt(), 0, "sentinel written while underwater");
    assertEq(_lastTotalAssets(), 0, "reference NAV zeroed while underwater");

    // Recovery reseeds through the sentinel without charging, then gains charge normally.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "reseeding accrual skips the perf fee");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference reseeded");
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100);
    _accrue();
    assertGt(positionManager.balanceOf(feeRecipient), 0, "post-reseed gains charge normally");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       NAV-GAIN CAP                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A liquidation cuts collateral and debt in a ratio that leaves the survivor below
  ///         the reference LTV, so the levered read turns positive while NAV fell. The NAV-gain
  ///         cap must zero the basis and hold the reference; the recovery is then charged only
  ///         past the pre-loss mark, capped at the true NAV gain.
  function test_navCap_liquidationLossMintsNoFee() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    uint256 refNav = _lastTotalAssets();
    uint256 refDebt = positionManager.lastDebt();

    // Crash the quote, liquidate part of the position natively on Morpho, restore the quote.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);
    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.startPrank(liquidator);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.liquidate(marketParams1, address(borrowPosition1), 2_000e18, 0, "");
    vm.stopPrank();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    // NAV fell, yet the levered read alone is positive (the seizure deleveraged the survivor).
    assertLt(positionManager.totalAssets(), refNav, "NAV fell across the liquidation");
    assertGt(_pendingBasis(), 0, "the levered read alone would charge a fee on the loss");

    // The cap zeroes the basis: nothing pending, nothing minted, reference held.
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no perf fee pending on a NAV loss");
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no perf fee minted on a NAV loss");
    assertEq(positionManager.lastDebt(), refDebt, "reference debt held across the loss");
    assertEq(_lastTotalAssets(), refNav, "reference NAV held across the loss");

    // Recovery: fees resume only past the pre-loss mark and are capped at the true NAV gain,
    // which post-seizure sits below the levered read.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 115 / 100);
    uint256 navGain = positionManager.totalAssets() - refNav;
    assertGt(navGain, 0, "NAV recovered past the pre-loss mark");
    assertGt(uint256(_pendingBasis()), navGain, "the levered read overstates the recovery after a seizure");
    (,,, uint256 resumedShares) = positionManager.pendingFees();
    assertEq(resumedShares, _expectedPerfShares(navGain), "the fee is capped at the gain past the old mark");
  }

  /// @notice After a held-carry rebase the carried drawdown sits inside `lastTotalAssets`, so
  ///         the cap keeps fees suspended until NAV recovers past the carried mark, not merely
  ///         past the post-flow NAV.
  function test_navCap_heldCarryRecoveryChargedPastCarriedMark() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Flat month: debt accrues while the quote is flat; the accrual holds the reference.
    vm.warp(block.timestamp + 30 days);
    _accrue();

    // A supply-changing flow rebases the reference: the carried debt cost folds into the mark.
    _mintCollateral(minter, 100e18);
    vm.prank(minter);
    positionManager.deposit(100e18, 0);
    uint256 carriedMark = _lastTotalAssets();
    assertGt(carriedMark, positionManager.totalAssets(), "the carried drawdown sits inside the mark");

    // A partial liquidation keeps the levered read positive through the recovery below.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);
    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.startPrank(liquidator);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.liquidate(marketParams1, address(borrowPosition1), 2_000e18, 0, "");
    vm.stopPrank();

    // Price at which NAV exactly reaches the carried mark.
    uint256 collatUnits = positionManager.collateralAmount();
    uint256 debtNow = positionManager.debtAmount();
    uint256 markPrice = (carriedMark + debtNow) * ORACLE_PRICE_SCALE / collatUnits;

    // Just below the carried mark: the levered read is positive, but no fee may accrue.
    oracle.setPrice(markPrice * 99 / 100);
    assertGt(_pendingBasis(), 0, "the levered read is positive below the carried mark");
    assertLt(positionManager.totalAssets(), carriedMark, "NAV still below the carried mark");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no fee until NAV clears the carried mark");
    uint256 refDebt = positionManager.lastDebt();
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "held accrual mints nothing");
    assertEq(positionManager.lastDebt(), refDebt, "reference held below the carried mark");

    // Past the carried mark: the fee covers min(levered read, gain above the mark).
    oracle.setPrice(markPrice * 105 / 100);
    uint256 navGain = positionManager.totalAssets() - carriedMark;
    assertGt(navGain, 0, "NAV cleared the carried mark");
    uint256 basis = FixedPointMathLib.min(uint256(_pendingBasis()), navGain);
    (,,, uint256 resumedShares) = positionManager.pendingFees();
    assertEq(resumedShares, _expectedPerfShares(basis), "charged only past the carried mark");
    assertGt(resumedShares, 0, "fees resume past the carried mark");
  }

  /// @notice A direct repay on Morpho on behalf of a module is fee-bearing at its true size:
  ///         the levered read equals the NAV gain when collateral is unchanged, so the cap
  ///         binds the fee to the donated relief.
  function test_navCap_externalRepayChargedAtTrueGain() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    uint256 refNav = _lastTotalAssets();

    // Anyone can repay for a module; 100 of debt relief is donated to the pool.
    debtToken.setBalance(user, 100e18);
    vm.startPrank(user);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.repay(marketParams1, 100e18, 0, address(borrowPosition1), "");
    vm.stopPrank();

    uint256 navGain = positionManager.totalAssets() - refNav;
    assertApproxEqAbs(navGain, 100e18, 2, "the donation is the whole NAV gain");
    uint256 levered = uint256(_pendingBasis());
    assertLe(levered, navGain, "with collateral unchanged the levered read cannot exceed the gain");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(levered), "the donation is charged as performance");
    assertGt(perfShares, 0, "donated debt relief is fee-bearing");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  CHECKPOINT SPLITTING                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Splitting one gain across many checkpoints must not erase the fee: a checkpoint
  ///         whose entitlement converts to zero shares holds the reference, so the basis keeps
  ///         accumulating and the split path mints exactly what a single checkpoint would.
  function test_checkpointSplitting_conservesEntitlement() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Lift the share price so one raw share is worth tens of asset wei, then crystallize once
    // so the reference is fresh at the lifted state.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 11);
    _accrue();
    uint256 mintedAtLift = positionManager.balanceOf(feeRecipient);
    assertGt(mintedAtLift, 0, "the lift itself crystallizes");
    uint256 refDebt = positionManager.lastDebt();
    uint256 refNav = _lastTotalAssets();

    uint256 snap = vm.snapshotState();

    // Split path: four tiny checkpoints, each with a positive entitlement that converts to
    // zero shares. Every one must hold the reference instead of consuming the gain.
    uint256 price = DEFAULT_ORACLE_PRICE * 11;
    for (uint256 i = 0; i < 4; ++i) {
      price += 1.5e16;
      oracle.setPrice(price);
      assertGt(_pendingBasis(), 0, "the entitlement is positive at a split checkpoint");
      (,,, uint256 pendingSplit) = positionManager.pendingFees();
      assertEq(pendingSplit, 0, "the split checkpoint rounds to zero shares");
      _accrue();
      assertEq(positionManager.lastDebt(), refDebt, "reference debt held at a zero-share checkpoint");
      assertEq(_lastTotalAssets(), refNav, "reference NAV held at a zero-share checkpoint");
    }
    assertEq(positionManager.balanceOf(feeRecipient), mintedAtLift, "split checkpoints minted nothing");

    // A real step follows: the accumulated split gains are inside the charged basis.
    oracle.setPrice(price + 3e34);
    _accrue();
    uint256 mintedSplitPath = positionManager.balanceOf(feeRecipient);
    assertGt(mintedSplitPath, mintedAtLift, "the step crystallizes the accumulated gain");

    // Straight path from the same start: one checkpoint over the same total gain must mint
    // exactly the same amount.
    vm.revertToState(snap);
    oracle.setPrice(price + 3e34);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), mintedSplitPath, "splitting conserved the fee");
  }

  /// @notice A zero-share hold with a management fee active: the management fee still mints and
  ///         this interval's charge joins the held accumulator, so the eventual crystallization
  ///         nets it from the basis.
  function test_checkpointSplitting_heldAccumulatorGrowsOnZeroShareHold() public {
    // Route the deposit to the no-interest market so debt stays flat across the warp.
    SupplyQueueEntry[] memory queue2 = new SupplyQueueEntry[](1);
    queue2[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue2);

    _setFees(MGMT_FEE, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Lift and crystallize: reference lands at collat 30_000, debt 5_000, NAV 25_000.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 3);
    _accrue();
    uint256 refDebt = positionManager.lastDebt();
    uint256 refNav = _lastTotalAssets();
    assertEq(refDebt, DEBT_AMOUNT, "reference debt at the lift");
    assertEq(refNav, 25_000e18, "reference NAV at the lift");
    uint256 mintedAtLift = positionManager.balanceOf(feeRecipient);

    // A flat day first: the accrual holds (zero basis) and the day's management fee seeds the
    // accumulator, so the zero-share hold below must add to a nonzero stored value.
    vm.warp(block.timestamp + 1 days);
    _accrue();
    uint256 heldSeed = _heldManagementFees();
    assertGt(heldSeed, 0, "the flat-day management fee seeds the accumulator");
    uint256 balanceAfterSeed = positionManager.balanceOf(feeRecipient);
    assertGt(balanceAfterSeed, mintedAtLift, "the flat-day management fee minted");

    // Another day, and a quote lift sized so the levered basis lands ~20 wei above the full
    // management deduction (stored seed plus this interval): the perf entitlement survives in
    // assets but converts to zero shares. Solving basis - m - heldSeed = 20 with
    // basis = C/6 - D and m = C * MGMT_FEE * elapsed / denom. Whether a wei-scale entitlement
    // crosses a share boundary also depends on the management fee's own rounding alignment, so
    // scan one-second offsets for an alignment where it does not.
    vm.warp(block.timestamp + 1 days);
    uint256 m;
    uint256 mgmtSharesPending;
    uint256 perfSharesPending;
    bool found;
    for (uint256 i = 0; i < 64 && !found; ++i) {
      vm.warp(block.timestamp + 1);
      uint256 elapsed = block.timestamp - _lastFeeAccrualTimestamp();
      uint256 denom = 10_000 * 365 days;
      uint256 targetCollat = (DEBT_AMOUNT + heldSeed + 20) * 6 * denom / (denom - 6 * uint256(MGMT_FEE) * elapsed);
      oracle.setPrice(targetCollat * ORACLE_PRICE_SCALE / COLLATERAL_AMOUNT);
      uint256 collatNow = positionManager.totalAssets() + positionManager.debtAmount();
      m = collatNow.mulDiv(uint256(MGMT_FEE) * elapsed, denom);
      uint256 basis = uint256(_pendingBasis());
      (,, mgmtSharesPending, perfSharesPending) = positionManager.pendingFees();
      found = basis > m + heldSeed && (basis - m - heldSeed) * PERF_FEE / 10_000 > 0 && perfSharesPending == 0;
    }
    assertTrue(found, "an alignment with a nonzero zero-share entitlement exists");
    assertGt(mgmtSharesPending, 0, "the management fee mints");

    _accrue();
    assertEq(positionManager.lastDebt(), refDebt, "reference debt held on the zero-share hold");
    assertEq(_lastTotalAssets(), refNav, "reference NAV held on the zero-share hold");
    assertEq(_heldManagementFees(), heldSeed + m, "the interval's fee joins the stored accumulator");
    assertEq(
      positionManager.balanceOf(feeRecipient), balanceAfterSeed + mgmtSharesPending, "only the management fee minted"
    );
  }

  /// @notice The confirmed review scenario: a routine flow between a seizure loss and the
  ///         recovery must carry the NAV mark (per-share) instead of re-anchoring it at the
  ///         trough, so the recovery below the pre-loss mark still mints nothing.
  function test_navCap_markSurvivesFlowAfterLiquidation() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    uint256 refNav = _lastTotalAssets();

    // Crash, liquidate part of the position natively on Morpho, restore the quote: NAV sits
    // below the mark while the levered read is positive.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);
    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.startPrank(liquidator);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.liquidate(marketParams1, address(borrowPosition1), 2_000e18, 0, "");
    vm.stopPrank();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    assertGt(_pendingBasis(), 0, "positive levered read after the seizure");
    uint256 navBefore = positionManager.totalAssets();
    assertLt(navBefore, refNav, "NAV below the pre-loss mark");

    // A routine flow: the rebase must preserve the per-share NAV deficit inside the mark.
    uint256 supplyBefore = positionManager.totalSupply();
    _mintCollateral(minter, 100e18);
    vm.prank(minter);
    positionManager.deposit(100e18, 0);
    uint256 expectedMark =
      positionManager.totalAssets() + (refNav - navBefore).mulDiv(positionManager.totalSupply(), supplyBefore);
    assertApproxEqAbs(_lastTotalAssets(), expectedMark, 2, "the flow carries the NAV deficit into the mark");

    // Recovery below the carried mark mints nothing: the converted carry keeps the levered
    // read negative until well past the mark (a conservative overshoot; the recipient charges
    // only the levered slice measured from the flow state).
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    assertLt(positionManager.totalAssets(), _lastTotalAssets(), "still below the carried mark");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no fee on recovery below the carried mark");
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "nothing minted below the carried mark");

    // Past the carried mark the charge is the levered slice of the gain above it.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 130 / 100);
    uint256 navGain = positionManager.totalAssets() - _lastTotalAssets();
    assertGt(navGain, 0, "NAV cleared the carried mark");
    uint256 basisUsed = uint256(_pendingBasis()).min(navGain);
    assertGt(basisUsed, 0, "positive capped basis past the carried mark");
    (,,, uint256 resumedShares) = positionManager.pendingFees();
    assertEq(resumedShares, _expectedPerfShares(basisUsed), "charged only above the carried mark");
  }

  /// @notice The owner escape hatch composes with the cap: a reset taken while the cap holds
  ///         (positive levered read, NAV below the mark) must not crystallize the capped read;
  ///         it re-anchors mintlessly at the live state.
  function test_navCap_resetDoesNotCrystallizeCappedRead() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);
    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.startPrank(liquidator);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.liquidate(marketParams1, address(borrowPosition1), 2_000e18, 0, "");
    vm.stopPrank();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    assertGt(_pendingBasis(), 0, "cap-held state: positive levered read");
    assertLt(positionManager.totalAssets(), _lastTotalAssets(), "cap-held state: NAV below the mark");

    vm.prank(owner);
    positionManager.resetPerformanceReference();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "the reset does not crystallize the capped read");
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "mark re-anchored at the live NAV");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference debt re-anchored");
  }

  /// @notice A flow during a zero-share hold preserves the sub-share pending entitlement: the
  ///         rebase re-encodes it as reference debt above the live debt (scaled with the
  ///         supply), so the capped basis reads back unchanged after the flow and checkpoint
  ///         splitting cannot erase the fee through the flow path either.
  function test_checkpointSplitting_flowPreservesSubShareEntitlement() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 11);
    _accrue();
    uint256 refDebt = positionManager.lastDebt();
    uint256 refNav = _lastTotalAssets();

    // Enter the zero-share hold with a tiny gain.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 11 + 1.5e16);
    assertGt(_pendingBasis(), 0, "positive entitlement");
    (,,, uint256 pending) = positionManager.pendingFees();
    assertEq(pending, 0, "entitlement converts to zero shares");
    _accrue();
    assertEq(positionManager.lastDebt(), refDebt, "reference held on the zero-share hold");
    assertEq(_lastTotalAssets(), refNav, "mark held on the zero-share hold");

    // The capped pending entitlement right before the flow.
    uint256 supplyBefore = positionManager.totalSupply();
    uint256 gainBefore = uint256(_pendingBasis()).min(positionManager.totalAssets() - refNav);
    assertGt(gainBefore, 0, "held entitlement pending at the flow");

    // The flow preserves the entitlement: the mark lands below the live NAV by exactly the
    // supply-scaled gain and the reference debt re-encodes it above the live debt.
    _mintCollateral(minter, 1_000e18);
    vm.prank(minter);
    positionManager.deposit(1_000e18, 0);
    uint256 gainScaled = gainBefore.mulDiv(positionManager.totalSupply(), supplyBefore);
    assertEq(
      _lastTotalAssets(),
      positionManager.totalAssets() - gainScaled,
      "the mark sits below the live NAV by the preserved gain"
    );
    assertEq(
      positionManager.lastDebt(),
      positionManager.debtAmount() + gainScaled,
      "the entitlement is re-encoded as reference debt above the live debt"
    );
    assertEq(
      uint256(_pendingBasis()).min(positionManager.totalAssets() - _lastTotalAssets()),
      gainScaled,
      "the capped entitlement reads back unchanged after the flow"
    );
  }

  /// @notice The flow-path attack from the 3F-481 review: repeated economically empty
  ///         rebalances during a zero-share hold must not erase the entitlement. Each empty
  ///         rebalance is supply-neutral, so the preservation is exact, and the eventual mint
  ///         matches a single checkpoint over the same aggregate gain.
  function test_checkpointSplitting_emptyRebalancesConserveEntitlement() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 11);
    _accrue();
    uint256 refDebt = positionManager.lastDebt();
    uint256 refNav = _lastTotalAssets();
    uint256 balanceAtLift = positionManager.balanceOf(feeRecipient);

    // Enter the zero-share hold with a tiny gain.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 11 + 1.5e16);
    (,,, uint256 pending) = positionManager.pendingFees();
    assertEq(pending, 0, "entitlement converts to zero shares");
    uint256 gainHeld = uint256(_pendingBasis()).min(positionManager.totalAssets() - refNav);
    assertGt(gainHeld, 0, "nonzero held entitlement");

    // Zero-op rebalances at will (supply-neutral flows): the entitlement survives each one.
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: new RebalancingOperation[](0)});
    for (uint256 i = 0; i < 5; ++i) {
      vm.prank(rebalancer);
      positionManager.rebalance(data, rebalancer);
      assertEq(
        uint256(_pendingBasis()).min(positionManager.totalAssets() - _lastTotalAssets()),
        gainHeld,
        "empty rebalance preserves the held entitlement"
      );
    }
    assertEq(positionManager.balanceOf(feeRecipient), balanceAtLift, "nothing minted during the hold");

    // The next real gain mints over the whole accumulated basis, matching (to ceil dust) a
    // single checkpoint against the pre-hold reference.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 12);
    uint256 basisUsed = uint256(_pendingBasis()).min(positionManager.totalAssets() - _lastTotalAssets());
    uint256 singleCheckpointBasis = refDebt.mulDivUp(
      positionManager.totalAssets() + positionManager.debtAmount(), refNav + refDebt
    ) - positionManager.debtAmount();
    assertApproxEqAbs(basisUsed, singleCheckpointBasis, 2, "the accumulated basis matches a single checkpoint");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(basisUsed), "the accumulated basis mints in full");
    assertGt(perfShares, 0, "the fee survived the empty rebalances");
  }

  /// @notice First rounding stage of 3F-481: a positive net entitlement whose BPS
  ///         multiplication rounds to zero fee assets must hold the reference, exactly like the
  ///         share-conversion stage; advancing would consume the sub-BPS basis, so splitting
  ///         one gain across many checkpoints could erase the fee without ever minting.
  function test_checkpointSplitting_bpsStageRoundingHoldsReference() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 3);
    _accrue();
    uint256 refDebt = positionManager.lastDebt();
    uint256 refNav = _lastTotalAssets();
    uint256 balanceAtLift = positionManager.balanceOf(feeRecipient);

    // A wei-scale quote bump: the basis is positive but 15% of it rounds to zero fee assets
    // (the price step below moves the quoted collateral by one wei per unit of i).
    uint256 priceStep = ORACLE_PRICE_SCALE / COLLATERAL_AMOUNT;
    bool found;
    for (uint256 i = 1; i <= 64 && !found; ++i) {
      oracle.setPrice(DEFAULT_ORACLE_PRICE * 3 + i * priceStep);
      int256 basis = _pendingBasis();
      found = basis > 0 && uint256(basis) * PERF_FEE / 10_000 == 0;
    }
    assertTrue(found, "an alignment with a sub-BPS entitlement exists");

    _accrue();
    assertEq(positionManager.lastDebt(), refDebt, "reference debt held on the BPS-stage hold");
    assertEq(_lastTotalAssets(), refNav, "mark held on the BPS-stage hold");
    assertEq(positionManager.balanceOf(feeRecipient), balanceAtLift, "nothing minted on the BPS-stage hold");

    // The gain keeps accumulating against the held reference and eventually mints in full.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 4);
    uint256 basisUsed = uint256(_pendingBasis()).min(positionManager.totalAssets() - _lastTotalAssets());
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(basisUsed), "the accumulated basis mints in full");
    assertGt(perfShares, 0, "the fee is not erased by the sub-BPS checkpoint");
  }

  /// @notice Reviewer follow-up on the NAV cap (3F-470): a near-full liquidation can leave a
  ///         NAV deficit larger than the remaining debt. The flow rebase must keep the mark out
  ///         of the bootstrap sentinel (which would reseed at the trough and charge the
  ///         recovery) by re-anchoring at NAV + deficit with the pre-flow reference LTV.
  function test_navCap_markSurvivesFlowAfterNearFullLiquidation() public {
    _setFees(0, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    uint256 refNav = _lastTotalAssets();
    uint256 refDebt = positionManager.lastDebt();

    // Crash and liquidate most of the position, then restore the quote: the NAV deficit
    // exceeds the remaining debt.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);
    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.startPrank(liquidator);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.liquidate(marketParams1, address(borrowPosition1), 7_500e18, 0, "");
    vm.stopPrank();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    uint256 deficit = refNav - positionManager.totalAssets();
    assertGt(deficit, positionManager.debtAmount(), "the NAV deficit exceeds the remaining debt");

    // A routine flow: the mark must survive at NAV + deficit instead of collapsing to the
    // bootstrap sentinel.
    uint256 supplyBefore = positionManager.totalSupply();
    _mintCollateral(minter, 100e18);
    vm.prank(minter);
    positionManager.deposit(100e18, 0);
    uint256 carry = deficit.mulDiv(positionManager.totalSupply(), supplyBefore);
    uint256 expectedMark = positionManager.totalAssets() + carry;
    assertGt(positionManager.lastDebt(), 0, "the reference debt does not collapse to the sentinel");
    assertEq(_lastTotalAssets(), expectedMark, "the mark survives the flow at NAV + deficit");
    assertEq(
      positionManager.lastDebt(), expectedMark.mulDivUp(refDebt, refNav), "reference debt at the pre-flow reference LTV"
    );

    // The next accrual holds the surviving mark (a sentinel would reseed at the trough here).
    _accrue();
    assertEq(_lastTotalAssets(), expectedMark, "the accrual holds the surviving mark");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "nothing minted below the surviving mark");

    // Recovery below the mark still mints nothing.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);
    assertLt(positionManager.totalAssets(), _lastTotalAssets(), "still below the surviving mark");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no fee on recovery below the surviving mark");

    // Past the mark, only the capped excess is charged.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 5 / 2);
    uint256 navGain = positionManager.totalAssets() - _lastTotalAssets();
    assertGt(navGain, 0, "NAV cleared the surviving mark");
    uint256 basisUsed = uint256(_pendingBasis()).min(navGain);
    (,,, uint256 resumedShares) = positionManager.pendingFees();
    assertEq(resumedShares, _expectedPerfShares(basisUsed), "charged only above the surviving mark");
    assertGt(resumedShares, 0, "fees resume past the surviving mark");
  }
}
