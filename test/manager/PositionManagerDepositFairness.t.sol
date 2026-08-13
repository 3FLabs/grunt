// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManagerDepositFairnessTest
/// @notice Deposit-fairness properties. For a deposit of collateral `c` (quoted `c_q` at the
///         oracle quote `p`) borrowing debt `d` into a pool with quoted collateral `C` and
///         debt `D`, the minted share fraction is fair under a true price `P` iff
///
///             (P - p) * (d * C - c_q * D) == 0
///
///         i.e. iff the quote is fresh (`P == p`, case 1) or the deposited debt-to-collateral
///         ratio matches the pool's (case 2). Case 1 additionally requires that no later
///         accrual consumes the fresh principal (the Cantina #32 follow-up regression class).
///         The third case (stale quote, mismatched ratio) is an inherent transfer that no
///         vault-side accounting can prevent; deposits made while the quote may be stale must
///         match the pool ratio (operational policy), see the demonstration test.
contract PositionManagerDepositFairnessTest is PositionManagerBaseTest {
  using FixedPointMathLib for uint256;

  uint24 constant PERF_FEE = 1500; // 15%, mirrors the production vault

  uint24 internal currentMgmtFee;
  uint24 internal currentPerfFee;

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

  /// @dev Redeemable value of `shares` at the current quote (virtual offset included).
  function _shareValue(uint256 shares) internal view returns (uint256) {
    return
      shares.mulDiv(positionManager.totalAssets(), positionManager.totalSupply() + positionManager.virtualShareOffset());
  }

  /// @dev Value of one share rounded up, the natural dust unit for mint-rounding tolerances.
  function _sharePriceCeil() internal view returns (uint256) {
    return positionManager.totalAssets().divUp(positionManager.totalSupply() + positionManager.virtualShareOffset());
  }

  /// @notice Case 1 (fresh quote): under any fee configuration, the deposited carry mints
  ///         shares worth the carry, minus at most one share of mint rounding, and no later
  ///         accrual can charge a performance fee against the fresh principal: with the quote
  ///         unchanged, the pending performance component stays zero no matter how much time
  ///         passes (only the time-based management fee may accrue).
  function testFuzz_deposit_freshQuote_mintsCarryValue(uint256 c, uint256 d, uint256 p, uint256 fees) public {
    // Fuzz the fee configuration: management rate in [0, 200] bps, performance in [0, 5000].
    _setFees(uint24(bound(fees, 0, 200)), uint24(bound(fees >> 128, 0, 5000)));
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // The mock oracle is the sole truth, so any settled quote is "fresh". Move it and accrue
    // so the deposit lands on an arbitrary reference state (crystallized or held).
    p = bound(p, 0.8e36, 3e36);
    oracle.setPrice(p);
    _accrue();

    c = bound(c, 1e18, 20_000e18);
    uint256 cQuoted = c.mulDiv(p, ORACLE_PRICE_SCALE);
    d = bound(d, 0, cQuoted.mulDiv(60, 100));

    uint256 assetsBefore = positionManager.totalAssets();
    uint256 sharesBefore = positionManager.balanceOf(minter);
    _leveredDeposit(c, d);

    uint256 carry = positionManager.totalAssets() - assetsBefore;
    uint256 minted = positionManager.balanceOf(minter) - sharesBefore;
    uint256 value = _shareValue(minted);
    assertLe(value, carry, "the depositor never mints more value than the carry");
    assertApproxEqAbs(value, carry, _sharePriceCeil() + 2, "the carry mints its own value back (case 1)");

    // No gain happened since the deposit settled, so an accrual must mint no performance fee:
    // any perf mint here would be paid by the fresh principal (the Cantina #32 follow-up
    // class). The debt side routes to the interest-bearing market, whose accrued interest
    // only pushes the basis further negative.
    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no performance fee pending without a gain");
    vm.warp(block.timestamp + bound(fees >> 64, 0, 90 days));
    (,,, perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "time alone never creates a performance fee on the principal");
  }

  /// @notice Case 2 (stale quote): a deposit whose debt-to-collateral ratio matches the
  ///         pool's is fair under ANY later true price. Once the quote refreshes, the
  ///         depositor's claim is worth the true value of the slice they contributed.
  function testFuzz_deposit_matchedRatio_fairUnderRepricing(uint256 c, uint256 p1, uint256 p2) public {
    // No fees configured: pure cohort accounting.
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    p1 = bound(p1, 0.8e36, 1.5e36); // the (possibly stale) quote at deposit time
    oracle.setPrice(p1);
    p2 = bound(p2, p1.mulDiv(85, 100), p1 * 2); // the refreshed true quote

    c = bound(c, 1e18, 20_000e18);
    uint256 cQuoted = c.mulDiv(p1, ORACLE_PRICE_SCALE);
    // Match the pool's debt-to-quoted-collateral ratio (up to one atom of rounding).
    uint256 d = cQuoted.mulDiv(positionManager.debtAmount(), positionManager.collateralAmountQuoted());

    uint256 sharesBefore = positionManager.balanceOf(minter);
    _leveredDeposit(c, d);
    uint256 minted = positionManager.balanceOf(minter) - sharesBefore;

    oracle.setPrice(p2);
    uint256 trueContribution = c.mulDiv(p2, ORACLE_PRICE_SCALE) - d;
    assertApproxEqAbs(
      _shareValue(minted),
      trueContribution,
      _sharePriceCeil() + 100,
      "matched-ratio deposit is repricing-neutral (case 2)"
    );
  }

  /// @notice Case 2 with fees on: a matched-ratio deposit grows the performance fee by
  ///         exactly the fee on its OWN levered slice's gain, `perfFee * d * (p2/p1 - 1)`,
  ///         and nothing more. The deposited principal is never charged; only its genuine
  ///         performance is (the reference is crystallized at `p1` so the closed form is
  ///         exact; a pending pre-deposit entitlement is covered by the checkpoint-splitting
  ///         regression tests). The performance rate itself is fuzzed.
  function testFuzz_deposit_matchedRatio_chargedOnlyOwnGain(uint256 c, uint256 p1, uint256 p2) public {
    uint24 perfFee = uint24(bound(c >> 128, 1, 5000));
    _setFees(0, perfFee);
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    p1 = bound(p1, 1.05e36, 1.5e36); // above the seed quote so the accrual crystallizes at p1
    oracle.setPrice(p1);
    _accrue();
    p2 = bound(p2, p1.mulDiv(85, 100), p1 * 2);

    c = bound(c, 1e18, 20_000e18);
    uint256 cQuoted = c.mulDiv(p1, ORACLE_PRICE_SCALE);
    uint256 d = cQuoted.mulDiv(positionManager.debtAmount(), positionManager.collateralAmountQuoted());

    // Counterfactual: no deposit, reprice, accrue; record the fee take in asset value.
    uint256 snapshot = vm.snapshotState();
    uint256 recipientBefore = positionManager.balanceOf(feeRecipient);
    oracle.setPrice(p2);
    _accrue();
    uint256 feeValueWithout = _shareValue(positionManager.balanceOf(feeRecipient) - recipientBefore);
    vm.revertToState(snapshot);

    // Real: matched-ratio deposit, then the same repricing and accrual.
    _leveredDeposit(c, d);
    recipientBefore = positionManager.balanceOf(feeRecipient);
    oracle.setPrice(p2);
    _accrue();
    uint256 feeValueWith = _shareValue(positionManager.balanceOf(feeRecipient) - recipientBefore);

    // The depositor's own levered slice gain from p1 to p2 (zero when the price fell: the
    // basis is capped below at zero for both branches).
    uint256 ownGain = FixedPointMathLib.zeroFloorSub(d.mulDiv(p2, p1), d);
    assertApproxEqAbs(
      feeValueWith,
      feeValueWithout + ownGain.mulDiv(perfFee, 10_000),
      2 * _sharePriceCeil() + 1_000,
      "the deposit is charged exactly its own slice's gain"
    );
  }

  /// @notice The complement, kept as a documented limitation: under a stale quote a
  ///         ratio-MISMATCHED deposit inherently moves value, with sign
  ///         `(P - p) * (d * C - c_q * D)`. Here an unlevered deposit ahead of an upward
  ///         repricing buys the levered pool at the stale price: the depositor exits with
  ///         more than they contributed and the incumbents pay for it. No vault-side
  ///         accounting can prevent this; deposits made while the quote may be stale must
  ///         match the pool's ratio (or wait for the refresh).
  function test_deposit_mismatchedRatio_staleQuoteTransfersValue() public {
    // Pool: 10_000 collateral / 5_000 debt at a stale 1:1 quote; supply 5_000.
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Unlevered 10_000 deposit at the stale quote mints 10_000 shares (carry at the quote).
    uint256 sharesBefore = positionManager.balanceOf(minter);
    _leveredDeposit(10_000e18, 0);
    uint256 minted = positionManager.balanceOf(minter) - sharesBefore;

    // The true price arrives: 2x. True contribution is 20_000, but the depositor's claim is
    // 10_000/15_000 of the 35_000 pool = 23_333: a 3_333 transfer from the incumbents.
    oracle.setPrice(2e36);
    uint256 trueContribution = 20_000e18;
    uint256 value = _shareValue(minted);
    assertGt(value, trueContribution + 3_000e18, "mismatched-ratio deposit captures incumbent value");
    assertApproxEqAbs(value, 23_333e18, 1e18, "the transfer matches the closed form");
  }
}
