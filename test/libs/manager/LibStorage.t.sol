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

  /// @notice Carry larger than the post-flow debt floors the reference debt at the bootstrap
  ///         sentinel (excess carry is forgiven).
  function test_rebaseSnapshot_carryClampedAtNewDebt() public {
    harness.setReference(5_000e18, 5_000e18);
    // Pre-flow carry = 100; flow repays almost all debt (newDebt = 60 < carry).
    harness.rebaseSnapshot(10_000e18, 5_100e18, 100e18, 5_060e18, 60e18, 100e18);
    assertEq(harness.getLastDebt(), 0, "reference debt floors at the sentinel");
    assertEq(harness.getLastTotalAssets(), 5_060e18, "lastTotalAssets = newCollat");
  }

  /// @notice The per-share pending basis is preserved across the rebase (up to rounding dust in
  ///         favor of the protocol).
  function testFuzz_rebaseSnapshot_preservesPerShareBasis(
    uint96 refTotalAssets,
    uint96 refDebt,
    uint96 carrySeed,
    uint96 newCollat,
    uint96 newDebt,
    uint64 prevSupply,
    uint64 newSupply
  ) public {
    vm.assume(refDebt > 0 && prevSupply > 0 && newSupply > 0);
    vm.assume(newCollat >= newDebt);

    uint256 refCollat = uint256(refTotalAssets) + refDebt;
    // Build a pre-flow state whose basis is exactly -carry at reference LTV.
    uint256 prevCollat = refCollat;
    uint256 carry = uint256(carrySeed);
    uint256 prevDebt = uint256(refDebt) + carry;

    harness.setReference(refTotalAssets, refDebt);
    harness.rebaseSnapshot(prevCollat, prevDebt, prevSupply, newCollat, newDebt, newSupply);

    uint256 expectedCarry = FixedPointMathLib.mulDiv(carry, newSupply, prevSupply);
    if (expectedCarry > newDebt) expectedCarry = newDebt;

    assertEq(harness.getLastDebt(), uint256(newDebt) - expectedCarry, "reference debt carries the scaled basis");
    assertEq(
      harness.getLastTotalAssets(),
      uint256(newCollat) - (uint256(newDebt) - expectedCarry),
      "reference NAV re-anchored on post-flow collateral"
    );
  }
}
