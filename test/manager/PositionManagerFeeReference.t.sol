// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
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
