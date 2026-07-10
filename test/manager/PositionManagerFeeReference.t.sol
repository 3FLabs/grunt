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

  /// @dev The held management fee accumulator (management fees charged since the reference last
  ///      advanced, deducted from the next positive basis).
  function _heldManagementFees() internal view returns (uint256) {
    (,,,,, uint256 held) = positionManager.feeData();
    return held;
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

    // The excluded module re-enters the aggregates on recovery: no spurious positive basis.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    assertLe(_pendingBasis(), 0, "module re-entry does not manufacture a gain");
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

  /// @notice A flow during the window rebases against the reduced universe: the carry clamp
  ///         re-anchors the reference at the post-flow state, which can only under-read the basis
  ///         once the excluded module re-enters (LP-favorable), never mint the phantom gain.
  function test_badDebt_partialExclusionFlowReanchorsLpFavorably() public {
    _setFees(0, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);

    // Unlevered deposit routed to the healthy module: the flow's accrual must not mint, and the
    // rebase re-anchors at the post-flow reduced universe (visible collat 4_950, debt 1_000).
    SupplyQueueEntry[] memory queue1 = new SupplyQueueEntry[](1);
    queue1[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue1);
    _leveredDeposit(1_000e18, 0);
    assertEq(positionManager.balanceOf(feeRecipient), 0, "window flow does not crystallize the phantom");
    assertEq(positionManager.lastDebt(), 1_000e18, "flow re-anchored on the reduced universe");
    assertEq(_lastTotalAssets(), 3_950e18, "flow re-anchored at the post-flow visible NAV");

    // B re-enters on recovery: the re-anchored reference under-reads the basis, so the recovery
    // is not charged (under-collection until a genuine new high, corrected by an owner reset).
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    assertLt(_pendingBasis(), 0, "re-entry under-reads the basis against the re-anchored reference");
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no fee on the module re-entry");

    // Fees resume once the pool clears the re-anchored reference LTV.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 150 / 100);
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "a strong enough gain clears the re-anchored reference");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(uint256(basis)), "fees resume on the genuine gain");
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

  /// @notice Pins the documented window-flow limitation and its operational remedy: a rescue
  ///         repayment that pulls the excluded module back above water mid-flow re-anchors the
  ///         reference at the trough (the re-entered module's high LTV over-reads the recovery),
  ///         and the remedy is a temporary zero performance rate through the first positive
  ///         accrual, not an owner reset (a reset would crystallize the phantom basis first).
  function test_badDebt_partialExclusionRescueFlowNeedsFeeHoliday() public {
    _setFees(0, PERF_FEE);
    _setupDebtHeavyExclusionWindow();

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 45 / 100);

    // Rescue: the rebalancer repays 2_500 of B's debt, pulling B (4_500 quoted vs 2_500 debt)
    // back above water mid-flow. The rebase compares the reduced pre-flow universe (4_500,
    // 1_000) with the full post-flow universe (9_000, 3_500): the carry clamps to zero and the
    // reference re-anchors at the trough with the re-entered module's LTV.
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
    assertEq(positionManager.lastDebt(), 3_500e18, "reference re-anchored at the trough (documented over-read)");
    assertEq(_lastTotalAssets(), 5_500e18, "reference NAV re-anchored at the trough");

    uint256 snap = vm.snapshotState();

    // Without intervention, the recovery is charged as gain from the trough anchor.
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    int256 phantomBasis = _pendingBasis();
    assertGt(phantomBasis, 0, "the trough anchor over-reads the recovery");
    (,,, uint256 phantomShares) = positionManager.pendingFees();
    assertEq(
      phantomShares,
      _expectedPerfShares(uint256(phantomBasis)),
      "absent intervention the recovery is charged from the trough"
    );
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), phantomShares, "the phantom fee mints at the first accrual");

    vm.revertToState(snap);

    // Remedy: zero the performance rate right after the flow; the first positive accrual then
    // advances the reference mintlessly and the rate can be restored.
    _setFees(0, 0);
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "zero-rate accrual advances without minting");
    assertEq(_lastTotalAssets(), 16_500e18, "reference re-anchored at the recovered state");
    _setFees(0, PERF_FEE);
    assertEq(positionManager.balanceOf(feeRecipient), 0, "restoring the rate does not mint");

    // Fees resume only on genuine gains above the re-anchored reference.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    int256 basis = _pendingBasis();
    assertGt(basis, 0, "genuine gain above the re-anchored reference");
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, _expectedPerfShares(uint256(basis)), "post-holiday gains charge normally");
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
  ///         still advances the reference on a positive basis.
  function test_advance_feeCapEarlyReturnStillAdvances() public {
    // Route to the interest-free market so the position survives a long dormancy.
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    _setFees(200, 2000);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Large gain + very long dormancy: the mgmt fee cap binds and the no-mint guard fires.
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);
    vm.warp(block.timestamp + 100 * 365 days);

    (,, uint256 mgmtPending, uint256 perfPending) = positionManager.pendingFees();
    assertEq(mgmtPending + perfPending, 0, "cap binds: no shares pending");

    _accrue();
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no shares minted when the cap binds");
    assertEq(_lastTotalAssets(), positionManager.totalAssets(), "reference NAV advanced despite zero mint");
    assertEq(positionManager.lastDebt(), positionManager.debtAmount(), "reference debt advanced");
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
  ///         reference without a performance fee; the consumed deduction does not carry past the
  ///         new mark.
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
    assertEq(_heldManagementFees(), 0, "consumed deduction does not carry past the new mark");
  }

  /// @notice The pending deduction scales with the share supply across a flow: an exit takes its
  ///         slice along instead of donating it to the stayers.
  function test_flow_scalesHeldManagementFeesWithSupply() public {
    _setFees(200, PERF_FEE);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    vm.warp(block.timestamp + 15 days);
    _accrue();
    uint256 heldBefore = _heldManagementFees();
    assertGt(heldBefore, 0, "management fees accumulated while held");

    // Exit half the pool in the same block: the burn's internal accrual is zero-elapsed, so the
    // only supply change is the burn itself and the deduction must scale with it.
    uint256 supplyBefore = positionManager.totalSupply();
    uint256 sharesToBurn = positionManager.balanceOf(minter) / 2;
    _mintDebt(minter, DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.burn(sharesToBurn, WithdrawalStrategy.PROPORTIONAL);

    uint256 supplyAfter = positionManager.totalSupply();
    assertEq(
      _heldManagementFees(), heldBefore.mulDiv(supplyAfter, supplyBefore), "deduction scales with the share supply"
    );
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

  /// @notice A fee holiday (no recipient) neither wipes nor grows the deduction: it survives
  ///         held holiday accruals and still nets the crystallization once fees are re-enabled,
  ///         while a positive-basis advance during the holiday clears it like any other advance.
  function test_managementFee_holidayPreservesHeldDeduction() public {
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

    // Variant: a positive basis during the holiday advances without a mint and clears the
    // deduction with the fee period it belonged to.
    vm.revertToState(snap);
    vm.prank(owner);
    positionManager.setFeeData(address(0), 200, PERF_FEE);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    vm.prank(owner);
    positionManager.setFeeData(address(0), 200, PERF_FEE);
    assertEq(_heldManagementFees(), 0, "advance during the holiday clears the deduction");
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
  ///         (management fees charged since the reference last advanced) is forgiven with it.
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
}
