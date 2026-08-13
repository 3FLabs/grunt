// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManagerFlowFairnessTest
/// @notice Flow-fairness properties. For a capital flow moving collateral `c` (quoted `c_q`
///         at the oracle quote `p`) and debt `d` (into the pool on a deposit, out of it on a
///         withdraw or burn) against a pool with quoted collateral `C` and debt `D`, the
///         share amount minted or burned is fair under a true price `P` iff
///
///             (P - p) * (d * C - c_q * D) == 0
///
///         i.e. iff the quote is fresh (`P == p`, case 1) or the flow's debt-to-collateral
///         ratio matches the pool's (case 2). Exits are deposits with the signs flipped, so
///         both directions are pinned here; `burn()` computes its amounts proportionally by
///         construction, so it is ratio-matched at any quote and only the free-form
///         `withdraw(c, d, strategy)` can pick a mismatched ratio. Case 1 additionally
///         requires that no later accrual consumes principal (the Cantina #32 follow-up
///         regression class). The third case (stale quote, mismatched ratio) is an inherent
///         transfer that no vault-side accounting can prevent; flows executed while the quote
///         may be stale must match the pool ratio (operational policy), see the two
///         demonstration tests.
contract PositionManagerFlowFairnessTest is PositionManagerBaseTest {
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

  /// @notice Case 1, exit direction: at a fresh quote a withdraw of ANY ratio burns shares
  ///         worth exactly the removed carry (rounded against the exiter by at most one
  ///         share), under any fee configuration, and neither the exit nor elapsed time can
  ///         create a performance fee afterwards.
  function testFuzz_withdraw_freshQuote_burnsCarryValue(uint256 c, uint256 d, uint256 p, uint256 fees) public {
    _setFees(uint24(bound(fees, 0, 200)), uint24(bound(fees >> 128, 0, 5000)));
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    p = bound(p, 0.8e36, 3e36);
    oracle.setPrice(p);
    _accrue();

    // Keep the post-exit LTV under the 70% withdrawal bound even for a collateral-only exit,
    // then let the debt leg roam anywhere below the flow's own 64%. Also cap the removed
    // carry at 90% of the minter's redeemable value: a high-rate crystallization above can
    // hand a large share slice to the fee recipient, and the burn must fit what the minter
    // still holds.
    uint256 cMaxQuoted = FixedPointMathLib.zeroFloorSub(
        positionManager.collateralAmountQuoted(), positionManager.debtAmount().mulDiv(100, 65)
      ).min(_shareValue(positionManager.balanceOf(minter)).mulDiv(90, 100));
    c = bound(c, 1e15, cMaxQuoted.mulDiv(ORACLE_PRICE_SCALE, p));
    uint256 cQuoted = c.mulDiv(p, ORACLE_PRICE_SCALE);
    d = bound(d, 0, cQuoted.mulDiv(64, 100).min(positionManager.debtAmount()));
    _mintDebt(minter, d);

    uint256 assetsBefore = positionManager.totalAssets();
    uint256 sharesBefore = positionManager.balanceOf(minter);
    vm.prank(minter);
    positionManager.withdraw(c, d, WithdrawalStrategy.SEQUENTIAL);

    uint256 carry = assetsBefore - positionManager.totalAssets();
    uint256 burned = sharesBefore - positionManager.balanceOf(minter);
    uint256 value = _shareValue(burned);
    // Withdrawals compound more rounding than deposits (Morpho repay share round-trips, and
    // each collateral atom quantizes to ~p quoted atoms), so the dust bound scales with the
    // price factor on top of the one-share mint rounding.
    uint256 dust = _sharePriceCeil() + 8 * (p / ORACLE_PRICE_SCALE + 2);
    assertGe(value + dust, carry, "the stayers never subsidize the exiter beyond dust");
    assertApproxEqAbs(value, carry, dust, "the exit burns exactly the carry's value (case 1)");

    (,,, uint256 perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "no performance fee pending without a gain");
    vm.warp(block.timestamp + bound(fees >> 64, 0, 90 days));
    (,,, perfShares) = positionManager.pendingFees();
    assertEq(perfShares, 0, "time alone never creates a performance fee after the exit");
  }

  /// @notice Case 2, exit direction: a withdraw whose debt-to-collateral ratio matches the
  ///         pool's leaves the stayers whole under ANY later true price: the per-share value
  ///         once the truth arrives equals the no-exit counterfactual.
  function testFuzz_withdraw_matchedRatio_leavesStayersWhole(uint256 c, uint256 p1, uint256 p2) public {
    // No fees configured: pure cohort accounting.
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    p1 = bound(p1, 0.8e36, 1.5e36);
    oracle.setPrice(p1);
    p2 = bound(p2, p1.mulDiv(85, 100), p1 * 2);

    c = bound(c, 1e18, 2_000e18);
    uint256 cQuoted = c.mulDiv(p1, ORACLE_PRICE_SCALE);
    uint256 d = cQuoted.mulDiv(positionManager.debtAmount(), positionManager.collateralAmountQuoted());
    _mintDebt(minter, d);

    uint256 snapshot = vm.snapshotState();
    oracle.setPrice(p2);
    uint256 ppsWithout = _shareValue(1e18);
    vm.revertToState(snapshot);

    vm.prank(minter);
    positionManager.withdraw(c, d, WithdrawalStrategy.SEQUENTIAL);
    oracle.setPrice(p2);
    assertApproxEqAbs(_shareValue(1e18), ppsWithout, 1e6, "matched-ratio exit is repricing-neutral for the stayers");
  }

  /// @notice `burn()` computes its collateral and debt proportionally by construction, so it
  ///         is ratio-matched and repricing-neutral at any (possibly stale) quote.
  function testFuzz_burn_isRatioMatchedByConstruction(uint256 shares, uint256 p1, uint256 p2) public {
    // No fees configured: pure cohort accounting.
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    p1 = bound(p1, 0.8e36, 1.5e36);
    oracle.setPrice(p1);
    p2 = bound(p2, p1.mulDiv(85, 100), p1 * 2);

    shares = bound(shares, 1e15, positionManager.balanceOf(minter).mulDiv(40, 100));
    _mintDebt(minter, positionManager.debtAmount()); // over-provision the proportional repay

    uint256 snapshot = vm.snapshotState();
    oracle.setPrice(p2);
    uint256 ppsWithout = _shareValue(1e18);
    vm.revertToState(snapshot);

    vm.prank(minter);
    positionManager.burn(shares, WithdrawalStrategy.PROPORTIONAL);
    oracle.setPrice(p2);
    assertApproxEqAbs(_shareValue(1e18), ppsWithout, 1e6, "burn is repricing-neutral at any quote");
  }

  /// @notice The exit complement of the stale-quote transfer: withdrawing collateral without
  ///         its debt share at a stale-low quote hands the exiter's levered upside to the
  ///         stayers. Same closed form as the deposit demonstration, signs flipped.
  function test_withdraw_mismatchedRatio_staleQuoteTransfersValue() public {
    _leveredDeposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Collateral-only exit at the stale 1:1 quote: 2_500 of carry burns 2_500 shares (half
    // the supply), leaving the pool at 7_500 collateral / 5_000 debt.
    uint256 sharesBefore = positionManager.balanceOf(minter);
    vm.prank(minter);
    positionManager.withdraw(2_500e18, 0, WithdrawalStrategy.SEQUENTIAL);
    assertEq(sharesBefore - positionManager.balanceOf(minter), 2_500e18, "the carry burns its quote value in shares");

    // The truth arrives at 2x: the burned half of the pool was truly worth 7_500, but the
    // exiter left with collateral worth 5_000. The stayers keep the difference: per-share
    // value 4 against 3 in the no-exit counterfactual.
    oracle.setPrice(2e36);
    assertEq(positionManager.totalAssets(), 10_000e18, "stayers keep the levered slice");
    assertGt(
      _shareValue(1e18),
      uint256(15_000e18).mulDiv(1e18, 5_000e18 + 1),
      "stayers gain from the exiter's mismatched-ratio exit"
    );
  }
}
