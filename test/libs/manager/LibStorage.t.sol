// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {IPositionManagerAdmin} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {LibManagerStorageHarness} from "test/mock/libs/LibManagerStorageHarness.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibStorageTest (Manager)
/// @notice Unit tests for manager LibStorage library
contract LibManagerStorageTest is Test {
  LibManagerStorageHarness harness;
  MockERC20 collateralToken;
  MockERC20 debtToken;

  function setUp() public {
    harness = new LibManagerStorageHarness();
    collateralToken = new MockERC20("Collateral", "COL", 18);
    debtToken = new MockERC20("Debt", "DEBT", 18);

    harness.setMetadata("Test PM", "TPM", address(collateralToken), address(debtToken));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        setLtv TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setLtv_emitsEvent() public {
    uint256 ltv = 0.86e18;

    vm.expectEmit();
    emit IPositionManagerAdmin.LTVSet(ltv);
    harness.setLtv(ltv);
  }

  function testFuzz_setLtv_success(uint256 ltv) public {
    ltv = bound(ltv, 1, FixedPointMathLib.WAD);

    harness.setLtv(ltv);
    assertEq(harness.getLtv(), uint64(ltv));
  }

  function testFuzz_setLtv_revertOnInvalid(uint256 ltv) public {
    vm.assume(ltv == 0 || ltv > FixedPointMathLib.WAD);

    vm.expectRevert(LibCommonErrors.InvalidLtv.selector);
    harness.setLtv(ltv);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   rebaseSnapshot TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebaseSnapshot_empty() public {
    assertEq(harness.getLastTotalAssets(), 0);
    harness.rebaseSnapshot(0, 0, 0, 0, 0, 0);
    assertEq(harness.getLastTotalAssets(), 0);
    assertEq(harness.getLastDebt(), 0);
  }

  /// @notice With a zero reference debt (bootstrap sentinel) the rebase is a plain snapshot of
  ///         the post-flow state.
  function test_rebaseSnapshot_sentinelSnapshotsToCurrent() public {
    harness.setReference(0, 0);
    harness.rebaseSnapshot(10_000e18, 5_000e18, 100e18, 12_000e18, 6_000e18, 120e18);
    assertEq(harness.getLastTotalAssets(), 6_000e18, "lastTotalAssets snaps to current NAV");
    assertEq(harness.getLastDebt(), 6_000e18, "lastDebt snaps to current debt");
  }

  /// @notice A supply-neutral flow (rebalance, module change) preserves the carried pending basis
  ///         in full: the new reference reproduces the same negative basis at the post-flow state.
  function test_rebaseSnapshot_supplyNeutralPreservesCarry() public {
    // Reference at collat 10_000 / debt 5_000; pre-flow debt has grown by 100 (carry = 100).
    harness.setReference(5_000e18, 5_000e18);
    harness.rebaseSnapshot(10_000e18, 5_100e18, 100e18, 8_000e18, 4_100e18, 100e18);
    // carry stays 100: newRefDebt = 4_100 - 100 = 4_000, lastTotalAssets = 8_000 - 4_000.
    assertEq(harness.getLastDebt(), 4_000e18, "carry preserved against new debt");
    assertEq(harness.getLastTotalAssets(), 4_000e18, "lastTotalAssets = newCollat - newRefDebt");
  }

  /// @notice A proportional exit sheds the exiting shares' slice of the carry.
  function test_rebaseSnapshot_exitScalesCarryDown() public {
    harness.setReference(5_000e18, 5_000e18);
    // Half the shares exit proportionally: collat/debt/supply all halve; carry 100 -> 50.
    harness.rebaseSnapshot(10_000e18, 5_100e18, 100e18, 5_000e18, 2_550e18, 50e18);
    assertEq(harness.getLastDebt(), 2_500e18, "carry halves with supply");
    assertEq(harness.getLastTotalAssets(), 2_500e18, "lastTotalAssets = newCollat - newRefDebt");
  }

  /// @notice A flow with an empty good-debt universe on both sides (every position underwater)
  ///         holds the reference so the high-water mark survives the episode.
  function test_rebaseSnapshot_underwaterFlowHoldsReference() public {
    harness.setReference(5_000e18, 5_000e18);
    harness.rebaseSnapshot(0, 0, 100e18, 0, 0, 100e18);
    assertEq(harness.getLastTotalAssets(), 5_000e18, "reference NAV held");
    assertEq(harness.getLastDebt(), 5_000e18, "reference debt held");
  }

  /// @notice A flow that empties the good-debt universe itself (the last healthy module removed
  ///         or drained while the others stay underwater) also holds the reference: re-anchoring
  ///         on empty aggregates would write the bootstrap sentinel and destroy the high-water
  ///         mark, so the recovery would be re-charged from wherever the next accrual reseeds.
  function test_rebaseSnapshot_flowEmptyingGoodDebtUniverseHoldsReference() public {
    harness.setReference(14_000e18, 6_000e18);
    harness.setHeldManagementFeeAssets(100e18);

    // Supply-neutral removal of the last healthy module (visible pre-flow: 4_500 / 1_000).
    harness.rebaseSnapshot(4_500e18, 1_000e18, 100e18, 0, 0, 100e18);
    assertEq(harness.getLastTotalAssets(), 14_000e18, "reference NAV held across the removal");
    assertEq(harness.getLastDebt(), 6_000e18, "reference debt held across the removal");

    // Same transition through a supply-changing flow (a withdrawal draining the module).
    harness.rebaseSnapshot(4_500e18, 1_000e18, 100e18, 0, 0, 40e18);
    assertEq(harness.getLastTotalAssets(), 14_000e18, "reference NAV held across the exit");
    assertEq(harness.getLastDebt(), 6_000e18, "reference debt held across the exit");

    // The held deduction stays nominal on the hold path, like the both-sides-empty hold.
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "hold path leaves the deduction in place");
  }

  /// @notice Carry at or above the post-flow debt re-anchors the mark at NAV + carry with the
  ///         reference debt at the pre-flow reference LTV, instead of flooring it at the
  ///         bootstrap sentinel (which would let the next accrual reseed the high-water mark at
  ///         the trough and charge the recovery).
  function test_rebaseSnapshot_oversizedCarryKeepsMarkAtReferenceLtv() public {
    harness.setReference(5_000e18, 5_000e18);
    // Pre-flow carry = 100; flow repays almost all debt (newDebt = 60 < carry). The reference
    // LTV is 50%, so the re-anchored reference debt equals the mark.
    harness.rebaseSnapshot(10_000e18, 5_100e18, 100e18, 5_060e18, 60e18, 100e18);
    assertEq(harness.getLastTotalAssets(), 5_100e18, "mark re-anchored at NAV + carry");
    assertEq(harness.getLastDebt(), 5_100e18, "reference debt at the pre-flow reference LTV");

    // Same but the flow unwinds the debt entirely: the mark still survives.
    harness.setReference(5_000e18, 5_000e18);
    harness.rebaseSnapshot(10_000e18, 5_100e18, 100e18, 5_000e18, 0, 100e18);
    assertEq(harness.getLastTotalAssets(), 5_100e18, "mark survives a full debt unwind");
    assertEq(harness.getLastDebt(), 5_100e18, "reference debt stays out of the sentinel");
  }

  /// @notice The held management fee accumulator is never rescaled by a flow: a deposit/exit
  ///         round trip that restores the vault state must hand the deduction back whole (a
  ///         down-only rule would let reversible capital grind it toward zero), and
  ///         supply-neutral and underwater flows are untouched too.
  function test_rebaseSnapshot_keepsHeldManagementFeesNominalAcrossFlows() public {
    harness.setReference(5_000e18, 5_000e18);
    harness.setHeldManagementFeeAssets(100e18);

    // Supply-neutral flow: deduction unchanged.
    harness.rebaseSnapshot(10_000e18, 5_100e18, 100e18, 8_000e18, 4_100e18, 100e18);
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "supply-neutral flow keeps the deduction");

    // A deposit doubles the supply: the deduction stays nominal (per-share dilution).
    harness.rebaseSnapshot(8_000e18, 4_100e18, 100e18, 16_000e18, 8_200e18, 200e18);
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "deposit leaves the deduction nominal");

    // The deposit exits again, restoring the pre-deposit state: the deduction comes back
    // whole, not halved (the round-trip grind).
    harness.rebaseSnapshot(16_000e18, 8_200e18, 200e18, 8_000e18, 4_100e18, 100e18);
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "round trip hands the deduction back whole");

    // Underwater flow (both sides empty): everything held, deduction included.
    harness.rebaseSnapshot(0, 0, 100e18, 0, 0, 100e18);
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "underwater flow holds the deduction");
  }

  /// @notice A rescue flow out of a full bad-debt episode (empty pre-flow aggregates) keeps the
  ///         accumulator nominal: shares mint against a zero asset base there, so the supply
  ///         ratio is unmoored and scaling would inflate the deduction beyond the fees ever
  ///         charged.
  function test_rebaseSnapshot_rescueFlowKeepsHeldManagementFeesNominal() public {
    harness.setReference(5_000e18, 5_000e18);
    harness.setHeldManagementFeeAssets(100e18);
    harness.rebaseSnapshot(0, 0, 100e18, 5_200e18, 5_000e18, 1e30);
    assertEq(harness.getLastDebt(), 5_000e18, "reference re-anchored on the post-flow state");
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "deduction stays nominal across the rescue");
  }

  /// @notice A flow from a universe pinned at `collateral == debt` (zero NAV but still good
  ///         debt, so gross collateral is positive) keeps the accumulator nominal too: the mint
  ///         denominator is the virtual asset base, so a dust deposit doubles the supply and
  ///         would double the credit with it (Cantina #30).
  function test_rebaseSnapshot_zeroNavFlowKeepsHeldManagementFeesNominal() public {
    harness.setReference(1_000e18, 4_000e18);
    harness.setHeldManagementFeeAssets(100e18);
    harness.rebaseSnapshot(5_000e18, 5_000e18, 100e18, 5_000e18 + 1, 5_000e18, 200e18);
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "deduction stays nominal at zero pre-flow NAV");
  }

  /// @notice An exit that empties the good-debt universe (reference-hold early return) leaves
  ///         the deduction nominal like any other exit while shares remain, but a flow that
  ///         burns the last share clears it: no holders, no one owed the deduction, and during
  ///         a bad-debt window the empty-vault reseed clear never runs (Cantina #7).
  function test_rebaseSnapshot_fullExitClearsHeldManagementFees() public {
    harness.setReference(5_000e18, 5_000e18);
    harness.setHeldManagementFeeAssets(100e18);

    // Partial exit draining the last healthy module: shares remain, so the deduction stays
    // nominal and the reference is held.
    harness.rebaseSnapshot(8_000e18, 4_100e18, 100e18, 0, 0, 80e18);
    assertEq(harness.getLastDebt(), 5_000e18, "empty good-debt exit holds the reference");
    assertEq(harness.getHeldManagementFeeAssets(), 100e18, "partial exit keeps the deduction nominal");

    // The remaining shares exit too: the terminal clear fires, the reference hold is untouched.
    harness.rebaseSnapshot(0, 0, 80e18, 0, 0, 0);
    assertEq(harness.getLastDebt(), 5_000e18, "reference still held across the full exit");
    assertEq(harness.getHeldManagementFeeAssets(), 0, "full exit clears the deduction");
  }

  /// @notice In the sentinel fallback the accumulator is left in place: the sentinel forces the
  ///         next accrual to advance the reference, which clears it before any performance fee
  ///         could consume it.
  function test_rebaseSnapshot_sentinelLeavesHeldManagementFeesForAccrualToClear() public {
    harness.setReference(0, 0);
    harness.setHeldManagementFeeAssets(77e18);
    harness.rebaseSnapshot(10_000e18, 5_000e18, 100e18, 12_000e18, 6_000e18, 120e18);
    assertEq(harness.getHeldManagementFeeAssets(), 77e18, "sentinel fallback does not touch the accumulator");
  }

  /// @dev Replicates the write-out branches of `rebaseSnapshot` for the fuzz expectations.
  function _expectedReference(
    uint256 expectedCarry,
    uint256 refNav,
    uint256 refDebt,
    uint256 newCollat,
    uint256 newDebt
  ) internal pure returns (uint256 expectedRefNav, uint256 expectedRefDebt) {
    if (expectedCarry >= newDebt && expectedCarry > 0 && refNav > 0) {
      // Oversized carry: the mark re-anchors at NAV + carry at the pre-flow reference LTV.
      expectedRefNav = newCollat - newDebt + expectedCarry;
      expectedRefDebt = FixedPointMathLib.mulDivUp(expectedRefNav, refDebt, refNav);
    } else {
      expectedRefDebt = FixedPointMathLib.zeroFloorSub(newDebt, expectedCarry);
      expectedRefNav = newCollat - expectedRefDebt;
    }
  }

  /// @notice The per-share pending basis is preserved across the rebase (up to rounding dust in
  ///         favor of the protocol).
  function testFuzz_rebaseSnapshot_preservesPerShareBasis(
    uint96 refTotalAssets,
    uint96 refDebt,
    uint96 carrySeed,
    uint96 heldMgmtSeed,
    uint96 newCollat,
    uint96 newDebt,
    uint64 prevSupply,
    uint64 newSupply
  ) public {
    vm.assume(refDebt > 0 && prevSupply > 0 && newSupply > 0);
    vm.assume(newCollat >= newDebt);
    // A flow into an empty good-debt universe holds the reference instead of rebasing; that
    // path is pinned by the dedicated hold tests above.
    vm.assume(newCollat > 0);

    uint256 refCollat = uint256(refTotalAssets) + refDebt;
    // Build a pre-flow state whose basis is exactly -carry at reference LTV.
    uint256 prevCollat = refCollat;
    uint256 carry = uint256(carrySeed);
    uint256 prevDebt = uint256(refDebt) + carry;

    harness.setReference(refTotalAssets, refDebt);
    harness.setHeldManagementFeeAssets(heldMgmtSeed);
    harness.rebaseSnapshot(prevCollat, prevDebt, prevSupply, newCollat, newDebt, newSupply);

    (uint256 expectedRefNav, uint256 expectedRefDebt) = _expectedReference(
      FixedPointMathLib.mulDiv(carry, newSupply, prevSupply), refTotalAssets, refDebt, newCollat, newDebt
    );

    assertEq(harness.getLastDebt(), expectedRefDebt, "reference debt carries the scaled basis");
    assertEq(harness.getLastTotalAssets(), expectedRefNav, "reference NAV re-anchored on post-flow collateral");
    assertEq(
      harness.getHeldManagementFeeAssets(), heldMgmtSeed, "held management fee deduction is never rescaled by a flow"
    );
  }
}
