// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibInKindView} from "src/libs/facility/inkind/LibInKindView.sol";
import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title InKindFacilityFuzzTest
/// @notice Fuzzed economic properties of the in-kind facility:
///         - staleness neutrality: ratio-matched entries never cross a price, so a stale quote
///           cannot transfer value between the entrant and the holders in either direction, and
///           with fees on the only deviation is the share fee;
///         - exact mirror: `previewExit` replicates `PM.burn`'s pulled debt and returned
///           collateral to the wei across states with pending management + performance fees and
///           elapsed interest;
///         - round trips never profit: same-block enter -> full exit is at best break-even for
///           the user and never a loss for the stayers, fees on or off;
///         - the entry debt leg is `amount * D / C` rounded down and leaves the pool ratio intact;
///         - caps: auth spill-over into the security cap, and `maxEnter` / `maxExit` are tight.
contract InKindFacilityFuzzTest is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;

  /// @dev Morpho oracle price scale: `price * collateral / 1e36 = debt-unit value`.
  uint256 constant ORACLE_PRICE_SCALE = 1e36;

  /// @dev Rounding-dust tolerance for value comparisons, in 6-dec debt units (5e-5 USDC).
  ///      Sources: quoted-equity quantization on the share mint (<= 2 units plus the one
  ///      virtual asset, amplified by a price factor <= 3 once the pool reprices), the burn's
  ///      floor/ceil pair, and Morpho borrow-share round-trips.
  uint256 constant VALUE_DUST = 50;

  /// @dev Quantization slack for the holders'-claim floor checks, in 6-dec debt units: the
  ///      claim measurement itself floors a mulDiv whose denominator the entrant's flow
  ///      changes, and Morpho's borrow-share rounding can shift the aggregate debt by an atom
  ///      per flow. A few units of measurement noise, not a value transfer.
  uint256 constant CLAIM_DUST = 10;

  /// @dev Per-leg slack of a fee-free round trip, in collateral wei: the entrant's share
  ///      fraction can sit above the exact `c / (C + c)` by up to two quoted-equity units (the
  ///      pool quote's floor carry and the debt floor; the `NonNeutralMint` gate allows three),
  ///      each worth `1e12 / (1 - LTV)` wei at the 1:1 quote with LTV <= 45%. The extra
  ///      collateral comes with proportionally more debt to repay, so the value leg is strict.
  uint256 constant LEG_DUST_COLLATERAL = 4e12;

  /// @dev Same slack on the debt leg, in debt units (the ceil on `debtIn` absorbs most of it).
  uint256 constant LEG_DUST_DEBT = 2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Seeds a levered pool from fuzz words: collateral in [1_000e18, 50_000e18], debt at a
  ///      quoted LTV in [10%, 45%], comfortably under the PM's 0.7 target LTV so ratio-matched
  ///      entries never hit the borrow capacity, and under water only past a 2.2x price drop so
  ///      a 0.5x..2x oracle move never trips the bad-debt gate.
  function _seedFuzzedPool(uint256 collateralSeed, uint256 ratioSeed)
    internal
    returns (uint256 seedCollateral, uint256 seedDebt)
  {
    seedCollateral = bound(collateralSeed, 1_000e18, 50_000e18);
    uint256 ratioBps = bound(ratioSeed, 1_000, 4_500);
    // Quoted collateral at the 1:1 price is `collateral / 1e12` (18 -> 6 decimals).
    seedDebt = seedCollateral.mulDiv(ratioBps, BPS * 1e12);
    _seedPool(seedCollateral, seedDebt);
  }

  /// @dev Opens both sides of the default PM with `feeBps` and an unlimited ABSOLUTE cap.
  function _openOffersWithFee(uint24 feeBps) internal {
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, feeBps);
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, feeBps);
    _setSecurityCap(LibCaps.MAX_ABSOLUTE);
  }

  /// @dev Burn's share denominator: post-accrual supply plus the virtual offset.
  function _adjustedSupply() internal view returns (uint256) {
    (, uint256 supply, uint256 mgmtFeeShares, uint256 perfFeeShares) = positionManager.pendingFees();
    return supply + mgmtFeeShares + perfFeeShares + positionManager.virtualShareOffset();
  }

  /// @dev Redeemable value of `who`'s PM shares at the current quote, in debt units.
  function _claimValue(address who) internal view returns (uint256) {
    return positionManager.balanceOf(who).mulDiv(positionManager.totalAssets(), _adjustedSupply());
  }

  /// @dev Value of `amount` collateral units at `price`, in debt units.
  function _collateralValue(uint256 amount, uint256 price) internal pure returns (uint256) {
    return amount.mulDiv(price, ORACLE_PRICE_SCALE);
  }

  /// @dev Exits `shares` as `user` with EXACT funding and EXACT approvals (no extra headroom,
  ///      the opposite of the `_exit` helper): the caller's debt balance is set to exactly the
  ///      preview's `debtRequired`, so the balance afterwards is exactly the refund.
  function _exitExact(uint256 shares, uint256 maxDebtIn, uint256 minOut)
    internal
    returns (uint256 out, uint256 debtIn, uint256 funded)
  {
    (,,, funded) = facility.previewExit(address(positionManager), shares);
    debtToken.setBalance(user, funded);
    vm.startPrank(user);
    debtToken.approve(address(facility), funded);
    positionManager.approve(address(facility), shares);
    (out, debtIn) = facility.exit(address(positionManager), shares, maxDebtIn, minOut, user, "");
    vm.stopPrank();
  }

  /// @dev Enters `amount` as `user` under a `feeBps` offer and checks the mint against the
  ///      fee-free mint `sharesNoFee` of the same entry: the mint is the same, only split by
  ///      the fee formula, the debt leg is `grossDebt`, and `previewEnter` agrees.
  function _enterWithFeeChecks(uint256 amount, uint24 feeBps, uint256 grossDebt, uint256 sharesNoFee)
    internal
    returns (uint256 shares, uint256 feeShares)
  {
    // One quoted-equity unit in shares, at the pre-flow share price: the preview's collateral
    // quote floors `quoted(C) * c / C` (up to `c / C` units under the live delta) and the
    // flow's debt can land an atom higher on Morpho.
    uint256 unitShares = _adjustedSupply().mulDivUp(1, positionManager.totalAssets() + 1);
    uint256 previewSlack = unitShares * (5 + amount / positionManager.collateralAmount()) + 2;
    (uint256 previewDebt, uint256 previewShares, uint256 previewFee) =
      facility.previewEnter(address(positionManager), amount);

    uint256 debt;
    (shares, debt) = _enter(user, amount, user);
    feeShares = positionManager.balanceOf(feeRecipient);

    assertEq(debt, grossDebt, "the debt leg is unaffected by the share fee");
    assertEq(shares + feeShares, sharesNoFee, "the fee only splits the fee-free mint");
    assertEq(feeShares, sharesNoFee.mulDivUp(feeBps, BPS), "entry fee is ceil(minted * fee / BPS)");
    assertEq(shares, sharesNoFee - feeShares, "the entrant gets the mint net of fee");
    assertEq(previewDebt, debt, "previewEnter matches the debt leg");
    assertEq(previewFee, (previewShares + previewFee).mulDivUp(feeBps, BPS), "previewEnter applies the same split");
    assertApproxEqAbs(previewShares, shares, previewSlack, "previewEnter estimates the net shares");
  }

  /// @dev ABSOLUTE cap error of LibCaps, keyed by the consumer's id.
  function _capError(address key, uint256 remaining, uint256 amount) internal pure returns (bytes memory) {
    return abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, uint256(uint160(key)), remaining, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    STALENESS NEUTRALITY                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The motivating property: a ratio-matched entry under a stale quote is neutral for
  ///         both sides of the trade. After the reprice `p'` (a) the entrant's equity is exactly
  ///         `p'c - d`, the levered exposure they paid for, both as a share-of-NAV claim and as
  ///         what `previewExit` would hand back, and (b) the holders' claim is unchanged versus
  ///         the no-entrant counterfactual at the same price. Fees are disabled so the property
  ///         is crisp; rounding dust favors the pool.
  function testFuzz_stalenessNeutrality(uint256 collateralSeed, uint256 ratioSeed, uint256 amount, uint256 priceSeed)
    public
  {
    _seedFuzzedPool(collateralSeed, ratioSeed);
    _openOffersNoFee();
    amount = bound(amount, 1e18, 50_000e18);
    uint256 newPrice = bound(priceSeed, 0.5e24, 2e24); // applied AFTER the entry

    uint256 grossDebt = amount.mulDiv(positionManager.debtAmount(), positionManager.collateralAmount());

    // Counterfactual: no entrant, same reprice, record the seeder's claim.
    uint256 snapshot = vm.snapshotState();
    oracle.setPrice(newPrice);
    uint256 seederClaimWithout = _claimValue(seeder);
    vm.revertToState(snapshot);

    // Enter ratio-matched under the stale quote, then the truth arrives.
    (uint256 shares, uint256 debt) = _enter(user, amount, user);
    assertEq(debt, grossDebt, "a zero-fee entry forwards the full ratio-matched debt");
    assertEq(positionManager.balanceOf(user), shares, "the receiver holds the net shares");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "no fee shares at zero fee");
    oracle.setPrice(newPrice);

    // (a) The entrant's equity at p' is p'c - d: no stale-quote value transfer.
    int256 expected = int256(_collateralValue(amount, newPrice)) - int256(grossDebt);
    int256 entrantEquity = int256(_claimValue(user));
    assertLe(entrantEquity, expected + int256(VALUE_DUST), "the entrant never captures more than p'c - d");
    assertApproxEqAbs(entrantEquity, expected, VALUE_DUST, "entrant equity is p'c - d mod pool-favoring dust");

    (uint256 debtIn, uint256 underlyingOut,,) = facility.previewExit(address(positionManager), shares);
    int256 exitValue = int256(_collateralValue(underlyingOut, newPrice)) - int256(debtIn);
    assertLe(exitValue, expected + int256(VALUE_DUST), "the exit never hands back more than p'c - d");
    assertApproxEqAbs(exitValue, expected, VALUE_DUST, "exit value is p'c - d mod pool-favoring dust");

    // (b) The holders' claim at p' is unchanged by the entrant's arrival.
    uint256 seederClaimWith = _claimValue(seeder);
    assertGe(seederClaimWith + CLAIM_DUST, seederClaimWithout, "the holders never pay for the entrant");
    assertApproxEqAbs(seederClaimWith, seederClaimWithout, VALUE_DUST, "holders' equity is untouched by the entry");
  }

  /// @notice The fee variant: with a nonzero `feeBps` the deviation from perfect neutrality is
  ///         EXACTLY the share fee: the mint is the same as the fee-free mint and is only split
  ///         `ceil(minted * feeBps / BPS)` to the recipient, the rest to the entrant. Nothing
  ///         else moves: the debt leg is the full ratio debt and the entrant's equity after the
  ///         reprice is `p'c - d` less the fee slice, which the recipient holds.
  function testFuzz_stalenessNeutrality_deviationIsExactlyTheFees(
    uint256 collateralSeed,
    uint256 ratioSeed,
    uint256 amount,
    uint256 priceSeed,
    uint256 feeSeed
  ) public {
    _seedFuzzedPool(collateralSeed, ratioSeed);
    uint24 feeBps = uint24(bound(feeSeed, 1, MAX_FEE));
    amount = bound(amount, 1e18, 50_000e18);
    uint256 newPrice = bound(priceSeed, 0.5e24, 2e24); // the reprice applied after the entry

    uint256 grossDebt = amount.mulDiv(positionManager.debtAmount(), positionManager.collateralAmount());

    // Counterfactual: the same entry fee-free, record the gross mint.
    uint256 snapshot = vm.snapshotState();
    _openOffersNoFee();
    (uint256 sharesNoFee,) = _enter(user, amount, user);
    vm.revertToState(snapshot);

    _openOffersWithFee(feeBps);
    (uint256 shares, uint256 feeShares) = _enterWithFeeChecks(amount, feeBps, grossDebt, sharesNoFee);

    oracle.setPrice(newPrice);

    // The two slices together are the fee-free entrant's equity; the recipient holds the fee.
    int256 expected = int256(_collateralValue(amount, newPrice)) - int256(grossDebt);
    int256 entrantEquity = int256(_claimValue(user));
    int256 feeEquity = int256(_claimValue(feeRecipient));
    assertApproxEqAbs(entrantEquity + feeEquity, expected, VALUE_DUST, "entrant + fee slices are p'c - d");
    int256 feeSlice = int256(uint256(expected).mulDiv(feeShares, sharesNoFee));
    assertApproxEqAbs(entrantEquity, expected - feeSlice, VALUE_DUST, "the entrant's shortfall is the fee slice");
    assertApproxEqAbs(feeEquity, feeSlice, VALUE_DUST, "the recipient's equity is the fee slice");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        EXACT MIRROR                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice `previewExit` equals the executed exit to the wei across states with pending
  ///         management + performance PM fee shares and accrued Morpho interest, any share fee.
  ///         The real mirror proof is the EXACT-approval flow: the user is funded with exactly
  ///         the preview's `debtRequired`, the facility pulls exactly it and refunds what burn
  ///         left, so the leftover balance is exactly `debtRequired - debtIn` and the paid
  ///         `debtIn` equals the preview to the wei.
  function testFuzz_exactMirror(
    uint256 collateralSeed,
    uint256 ratioSeed,
    uint256 amount,
    uint256 elapsed,
    uint256 priceSeed,
    uint256 sharesSeed,
    uint256 feeSeed
  ) public {
    _setPmFees(200, 2000);
    _seedFuzzedPool(collateralSeed, ratioSeed);
    uint24 feeBps = uint24(bound(feeSeed, 0, MAX_FEE));
    _openOffersWithFee(feeBps);
    amount = bound(amount, 1e18, 20_000e18);
    (uint256 userShares,) = _enter(user, amount, user);

    // Oracle gain so a performance fee pends (the entry flow seeded the reference), then
    // elapsed time so interest and the management fee accrue.
    oracle.setPrice(bound(priceSeed, 1.05e24, 2e24));
    vm.warp(block.timestamp + bound(elapsed, 1 days, 730 days));
    (,, uint256 mgmtFeeShares, uint256 perfFeeShares) = positionManager.pendingFees();
    assertGt(mgmtFeeShares + perfFeeShares, 0, "PM fee shares must be pending for the interesting path");

    // At least BPS shares so a nonzero fee cannot swallow the whole exit (NothingToBurn).
    uint256 sharesIn = bound(sharesSeed, BPS, userShares);
    (uint256 debtInPreview, uint256 outPreview, uint256 feePreview, uint256 requiredPreview) =
      facility.previewExit(address(positionManager), sharesIn);
    assertEq(feePreview, sharesIn.mulDivUp(feeBps, BPS), "exit fee is ceil(shares * fee / BPS)");
    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);

    // Exact-approval exit, also passing the previews as hard bounds.
    (uint256 out, uint256 debtIn, uint256 funded) = _exitExact(sharesIn, requiredPreview, outPreview);

    assertEq(debtIn, debtInPreview, "executed debtIn equals the preview to the wei");
    assertEq(out, outPreview, "executed underlyingOut equals the preview");
    assertEq(funded, requiredPreview, "the user was funded exactly debtRequired");
    assertEq(debtToken.balanceOf(user), funded - debtIn, "the headroom came back as the refund");
    assertEq(underlyingToken.balanceOf(user), out, "the underlying reached the receiver");
    assertEq(positionManager.balanceOf(user), userShares - sharesIn, "the exact shares were pulled");
    assertEq(positionManager.balanceOf(feeRecipient) - feeSharesBefore, feePreview, "the fee shares match the preview");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  ROUND TRIP NEVER PROFITS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice A same-block enter -> full exit never profits the user (rounding only, fees
  ///         disabled) and never costs the stayers: no same-block locks are needed. The value
  ///         leg is strict; each token leg is pool-favoring up to the quantization slack.
  function testFuzz_roundTripNeverProfits(uint256 collateralSeed, uint256 ratioSeed, uint256 amount) public {
    _seedFuzzedPool(collateralSeed, ratioSeed);
    _openOffersNoFee();
    amount = bound(amount, 1e18, 50_000e18);
    uint256 seederClaimBefore = _claimValue(seeder);
    uint256 totalAssetsBefore = positionManager.totalAssets();
    uint256 supplyBefore = _adjustedSupply();
    uint256 startValue = _collateralValue(amount, DEFAULT_ORACLE_PRICE);

    (uint256 shares, uint256 debtOut) = _enter(user, amount, user);
    (uint256 underlyingBack, uint256 debtIn,) = _exitExact(shares, type(uint256).max, 0);

    // User: everything back, valued at the unchanged quote, is at most what went in.
    assertLe(underlyingBack, amount + LEG_DUST_COLLATERAL, "the underlying leg never favors the user");
    assertGe(debtIn + LEG_DUST_DEBT, debtOut, "the debt leg never favors the user");
    assertLe(
      _collateralValue(underlyingBack, DEFAULT_ORACLE_PRICE) + debtOut,
      startValue + debtIn,
      "the round trip never profits the user"
    );
    // Pool: the holders' claim and the assets per share never decrease (dust accrues to the pool).
    assertGe(_claimValue(seeder) + CLAIM_DUST, seederClaimBefore, "the holders never lose to a round trip");
    assertGe(
      positionManager.totalAssets() + CLAIM_DUST,
      totalAssetsBefore.mulDiv(_adjustedSupply(), supplyBefore),
      "assets per share never decrease for the stayers"
    );
    assertEq(positionManager.balanceOf(user), 0, "every share was exited");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /// @notice The fee variant: on top of the rounding loss the round trip costs the two share
  ///         fees, both of which land with the fee recipient and are worth at least the user's
  ///         value shortfall.
  function testFuzz_roundTripNeverProfits_withFees(
    uint256 collateralSeed,
    uint256 ratioSeed,
    uint256 amount,
    uint256 feeSeed
  ) public {
    _seedFuzzedPool(collateralSeed, ratioSeed);
    uint24 feeBps = uint24(bound(feeSeed, 1, MAX_FEE));
    _openOffersWithFee(feeBps);
    amount = bound(amount, 1e18, 50_000e18);
    uint256 seederClaimBefore = _claimValue(seeder);
    uint256 startValue = _collateralValue(amount, DEFAULT_ORACLE_PRICE);

    (uint256 shares, uint256 debtOut) = _enter(user, amount, user);
    uint256 entryFee = positionManager.balanceOf(feeRecipient);
    (,, uint256 exitFee,) = facility.previewExit(address(positionManager), shares);
    (uint256 underlyingBack, uint256 debtIn,) = _exitExact(shares, type(uint256).max, 0);

    // The two fees are the two formulas and both land with the recipient.
    assertEq(entryFee, (shares + entryFee).mulDivUp(feeBps, BPS), "entry fee is ceil(minted * fee / BPS)");
    assertEq(exitFee, shares.mulDivUp(feeBps, BPS), "exit fee is ceil(shares * fee / BPS)");
    assertEq(positionManager.balanceOf(feeRecipient), entryFee + exitFee, "both fees land with the recipient");
    assertEq(positionManager.balanceOf(user), 0, "every share was exited");

    // The user's loss is at least the value of the fee shares (plus rounding dust).
    uint256 endValue = _collateralValue(underlyingBack, DEFAULT_ORACLE_PRICE) + debtOut;
    assertLe(endValue, startValue + debtIn, "the round trip never profits the user");
    uint256 loss = startValue + debtIn - endValue;
    assertGe(loss + CLAIM_DUST, _claimValue(feeRecipient), "the round trip costs at least both fees");
    assertGe(_claimValue(seeder) + CLAIM_DUST, seederClaimBefore, "the holders never lose to a round trip");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      ENTRY DEBT RATIO                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The entry's debt leg is exactly `amount * D / C` rounded down against the live
  ///         aggregates, including post-interest states, the preview matches, and the pool's
  ///         debt-per-collateral ratio is unchanged up to one debt unit over the new collateral
  ///         (the debt floor, and Morpho's borrow-share atom).
  function testFuzz_enterDebtRatio(uint256 collateralSeed, uint256 ratioSeed, uint256 amount, uint256 elapsed) public {
    _seedFuzzedPool(collateralSeed, ratioSeed);
    _openOffersNoFee();
    // Let Morpho interest drift the ratio: D grows, C is fixed.
    vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
    morpho.accrueInterest(marketParams);
    amount = bound(amount, 1e18, 50_000e18);

    uint256 totalCollateral = positionManager.collateralAmount();
    uint256 totalDebt = positionManager.debtAmount();
    (uint256 previewDebt,, uint256 previewFee) = facility.previewEnter(address(positionManager), amount);
    (, uint256 debt) = _enter(user, amount, user);

    assertEq(debt, amount.mulDiv(totalDebt, totalCollateral), "debt is amount * D / C rounded down");
    assertEq(previewDebt, debt, "previewEnter matches execution");
    assertEq(previewFee, 0, "zero-fee offer charges nothing");
    assertEq(debtToken.balanceOf(user), debt, "the debt reached the receiver");

    // Ratio: D' / C' == D / C within one debt unit over C' (cross-multiplied, no rounding).
    uint256 collateralAfter = positionManager.collateralAmount();
    uint256 debtAfter = positionManager.debtAmount();
    assertEq(collateralAfter, totalCollateral + amount, "the collateral leg is exact");
    assertLe(
      debtAfter * totalCollateral, totalDebt * collateralAfter + totalCollateral, "ratio never rises past an atom"
    );
    assertGe(
      debtAfter * totalCollateral + totalCollateral, totalDebt * collateralAfter, "ratio never falls past a unit"
    );
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            CAPS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Spill-over: an entry of debt `d` consumes `min(auth, d)` from the caller's auth and
  ///         the remainder from the asset's ABSOLUTE security cap, twice in a row.
  function testFuzz_spillOver(uint128 authAmount, uint256 debtSeed) public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    uint256 securityCap = 1_000_000e6;
    _setSecurityCap(securityCap);
    uint256 targetDebt = bound(debtSeed, 1, 2_000e6);
    uint256 authed = bound(uint256(authAmount), 0, 2 * targetDebt);
    _setAuth(user, uint128(authed), FAR_EXPIRY);
    // The amount whose ratio debt is `targetDebt` (C / D is far above one, so the floor lands).
    uint256 amount = targetDebt.mulDivUp(positionManager.collateralAmount(), positionManager.debtAmount());

    (, uint256 debt) = _enter(user, amount, user);
    uint256 fromAuth = authed.min(debt);
    Auth memory auth = facility.getAuth(address(underlyingToken), user);
    assertEq(auth.amount, authed - fromAuth, "the auth is consumed first");
    assertEq(auth.expiry, FAR_EXPIRY, "the auth expiry is untouched");
    assertEq(
      facility.getSecurityCap(address(underlyingToken)), securityCap - (debt - fromAuth), "the remainder spills over"
    );
    assertEq(facility.getEntry(address(positionManager)).capacityCap, LibCaps.MAX_ABSOLUTE - debt, "capacity consumed");

    // Second entry: the depleted auth spills more.
    uint256 authLeft = authed - fromAuth;
    (, uint256 debt2) = _enter(user, amount, user);
    uint256 fromAuth2 = authLeft.min(debt2);
    assertEq(facility.getAuth(address(underlyingToken), user).amount, authLeft - fromAuth2, "the auth keeps draining");
    assertEq(
      facility.getSecurityCap(address(underlyingToken)),
      securityCap - (debt - fromAuth) - (debt2 - fromAuth2),
      "the security cap absorbs both spills"
    );
    _assertFacilityClean();
  }

  /// @notice `maxEnter` is tight under ABSOLUTE words and an auth: entering exactly it fits,
  ///         entering a couple of debt units more reverts on the binding cap.
  function testFuzz_maxEnterFits(uint256 capacity, uint256 security, uint256 authSeed) public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    capacity = bound(capacity, 1, 20_000e6);
    security = bound(security, 0, 20_000e6);
    uint128 authed = uint128(bound(authSeed, 0, 20_000e6));
    _setEntry(positionManager, capacity, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(security);
    _setAuth(user, authed, FAR_EXPIRY);

    uint256 max = facility.maxEnter(address(positionManager), user);
    if (max == 0 || max > 100_000e18) return;
    uint256 totalCollateral = positionManager.collateralAmount();
    uint256 totalDebt = positionManager.debtAmount();
    uint256 debtMax = capacity.min(security + authed);
    assertEq(max, debtMax.mulDiv(totalCollateral, totalDebt), "maxEnter is the binding debt budget at the live ratio");

    // A couple of debt units over the bound reverts on whichever cap binds. Capacity is
    // consumed first, so it reports whenever the overshoot busts it, even when the security
    // leg would have failed too.
    uint256 over = max + totalCollateral.mulDiv(2, totalDebt) + 1;
    uint256 overDebt = over.mulDiv(totalDebt, totalCollateral);
    assertGt(overDebt, debtMax, "the overshoot exceeds the budget");
    bytes memory err = overDebt > capacity
      ? _capError(address(positionManager), capacity, overDebt)
      : _capError(address(underlyingToken), security, overDebt - overDebt.min(authed));
    _fundEntrant(user, over);
    vm.prank(user);
    vm.expectRevert(err);
    facility.enter(address(positionManager), over, 0, type(uint256).max, 0, user);

    // Exactly the bound fits.
    _fundEntrant(user, max);
    vm.prank(user);
    (uint256 shares, uint256 debt) = facility.enter(address(positionManager), max, 0, type(uint256).max, 0, user);
    assertGt(shares, 0, "the bound mints");
    assertLe(debt, debtMax, "the bound's debt fits the budget");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, capacity - debt, "capacity consumed");
    _assertFacilityClean();
  }

  /// @notice `maxExit` is tight under an ABSOLUTE exit cap: exiting `min(maxExit, balance)`
  ///         fits, and when the cap binds, exiting a small chunk more reverts CapExceeded.
  function testFuzz_maxExitFits(uint256 exitCap, uint256 shareFraction) public {
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
    uint256 amount = SEED_COLLATERAL.mulDiv(bound(shareFraction, 1, BPS), BPS);
    (uint256 userShares,) = _enter(user, amount, user);
    exitCap = bound(exitCap, 1, 3_000e6);
    _setExit(positionManager, exitCap, FAR_EXPIRY, DEFAULT_FEE_BPS);

    uint256 max = facility.maxExit(address(positionManager));
    uint256 supplyAdj = _adjustedSupply();
    uint256 totalDebt = positionManager.debtAmount();
    assertEq(
      max,
      LibInKindView.grossForNet(exitCap.mulDiv(supplyAdj, totalDebt), DEFAULT_FEE_BPS),
      "maxExit is the largest gross burning the cap's burnable slice"
    );
    (uint256 debtInMax,,,) = facility.previewExit(address(positionManager), max);
    assertLe(debtInMax, exitCap, "maxExit's debt slice fits the cap");

    // Two debt units' worth of burnable shares, grossed up by the fee, plus one.
    uint256 chunk = (supplyAdj.mulDiv(2, totalDebt) + 2).mulDiv(BPS, BPS - DEFAULT_FEE_BPS) + 1;
    // the cap is charged after burn, so the overshoot must be fundable to reach it
    if (max + chunk <= userShares) {
      uint256 over = max + chunk;
      (uint256 overDebt,,, uint256 overRequired) = facility.previewExit(address(positionManager), over);
      assertGt(overDebt, exitCap, "the overshoot exceeds the cap");
      debtToken.setBalance(user, overRequired);
      vm.startPrank(user);
      debtToken.approve(address(facility), overRequired);
      positionManager.approve(address(facility), over);
      vm.expectRevert(_capError(address(positionManager), exitCap, overDebt));
      facility.exit(address(positionManager), over, type(uint256).max, 0, user, "");
      vm.stopPrank();
    }

    uint256 toExit = max.min(userShares);
    (, uint256 debtIn) = _exit(user, toExit, user);
    assertLe(debtIn, exitCap, "the bound's debt fits the cap");
    assertEq(facility.getExit(address(positionManager)).cap, exitCap - debtIn, "the cap absorbed the exit");
    assertEq(positionManager.balanceOf(user), userShares - toExit, "the exact shares were pulled");
    _assertFacilityClean();
    _assertNoAllowances();
  }
}
