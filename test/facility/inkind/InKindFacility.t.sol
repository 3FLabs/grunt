// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {InKindFacility} from "src/facility/inkind/InKindFacility.sol";
import {IInKindFacility, EntryOffer, ExitOffer, Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {IInKindExitCallback} from "src/interfaces/facility/IInKindExitCallback.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

/// @title InKindFacilityTest
/// @notice Unit, view, slot-layout, e2e and fuzz tests for InKindFacility entries, exits, caps,
///         auths and admin.
contract InKindFacilityTest is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;
  using LibClone for address;

  /// @dev Storage slot of the facility state (keccak256("facility.inkind.storage")).
  bytes32 constant IN_KIND_STORAGE_SLOT = 0xca588c75c16c13263b4eb28c18c53ab9e5eef731302e0192c05b7a1eaaf2f463;

  function setUp() public override {
    super.setUp();
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The id the facility reports on capacity and exit cap errors: the PM address as a uint.
  function _pmId(PositionManager pm) internal pure returns (uint256) {
    return uint256(uint160(address(pm)));
  }

  /// @dev The id the facility reports on security cap errors: the underlying address as a uint.
  function _assetId() internal view returns (uint256) {
    return uint256(uint160(address(underlyingToken)));
  }

  /// @dev Ratio-derived gross debt for `amount` at the live pool ratio, as enter computes it.
  function _expectedDebt(uint256 amount) internal view returns (uint256) {
    return amount.mulDiv(positionManager.debtAmount(), positionManager.collateralAmount());
  }

  /// @dev Burn's exact share denominator: post-accrual supply + virtual offset.
  function _adjustedSupply() internal view returns (uint256) {
    (, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    return totalSupply_ + mgmtShares + perfShares + positionManager.virtualShareOffset();
  }

  /// @dev EXTERNAL word over the fixture's shared absolute pool.
  function _absWord(int24 multiplier) internal view returns (uint256) {
    return _externalWord(address(absoluteCaps), POOL_ID, multiplier);
  }

  /// @dev EXTERNAL word over several absolute pools (see _poolIds).
  function _absPoolsWord(uint64 ids, int24 multiplier) internal view returns (uint256) {
    return _externalWord(address(absoluteCaps), ids, multiplier);
  }

  /// @dev Packs pool IDs into a FacilityAbsoluteCaps cap ID, id1 in the low bits.
  function _poolIds(uint16 id1, uint16 id2, uint16 id3) internal pure returns (uint64) {
    return uint64(id1) | (uint64(id2) << 16) | (uint64(id3) << 32);
  }

  /// @dev Sets an absolute pool in debt units as the caps manager (the owner).
  function _setAbsPoolAt(uint16 id, uint128 cap, uint128 hardCap) internal {
    vm.prank(owner);
    absoluteCaps.setCap(id, uint128(cap * CAPS_SCALE), uint128(hardCap * CAPS_SCALE));
  }

  /// @dev EXTERNAL word over a dynamic cap.
  function _dynWord(uint64 id, int24 multiplier) internal view returns (uint256) {
    return _externalWord(address(dynamicCaps), id, multiplier);
  }

  /// @dev Sets the shared absolute pool in debt units as the caps manager (the owner).
  function _setAbsPool(uint128 cap, uint128 hardCap) internal {
    _setAbsPoolAt(POOL_ID, cap, hardCap);
  }

  /// @dev Sets a dynamic cap fully recovered right now: `recovery` debt units over one day,
  ///      origin a day ago.
  function _setDynPoolFull(uint64 id, uint128 recovery) internal {
    vm.prank(owner);
    dynamicCaps.setCap(id, uint128(recovery * CAPS_SCALE), uint64(1 days), uint64(block.timestamp - 1 days));
  }

  /// @dev Dynamic cap origin rounding forfeits up to one second of recovery per consumption.
  function _dynTolerance(uint256 recovery) internal pure returns (uint256) {
    return recovery / 1 days + 1;
  }

  /// @dev Funds `who` with `debtAllowance` debt asset and approves the facility for an exit of
  ///      `shares` without executing it (for tests that must call exit directly).
  function _approveExit(address who, uint256 shares, uint256 debtAllowance) internal {
    debtToken.setBalance(who, debtToken.balanceOf(who) + debtAllowance);
    vm.startPrank(who);
    debtToken.approve(address(facility), debtAllowance);
    positionManager.approve(address(facility), shares);
    vm.stopPrank();
  }

  /// @dev Un-levers the default pool by repaying the borrow module's whole Morpho debt on its behalf.
  function _unleverPool() internal {
    uint256 borrowShares = morpho.position(marketId, address(borrowPosition)).borrowShares;
    debtToken.setBalance(address(this), debtToken.balanceOf(address(this)) + 100_000_000e6);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.repay(marketParams, 0, borrowShares, address(borrowPosition), "");
    assertEq(positionManager.debtAmount(), 0, "pool not unlevered");
  }

  /// @dev Drops the oracle so module debt exceeds quoted collateral (-99.99%).
  function _triggerBadDebt() internal {
    oracle.setPrice(1e20);
    assertTrue(positionManager.hasBadDebt(), "bad debt not triggered");
  }

  /// @dev Dry-runs an entry of `amount` by `who` and returns the exact mint figures.
  function _dryRunEnter(address who, uint256 amount, address to)
    internal
    returns (uint256 shares, uint256 debt, uint256 feeShares)
  {
    uint256 snap = vm.snapshotState();
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);
    (shares, debt) = _enter(who, amount, to);
    feeShares = positionManager.balanceOf(feeRecipient) - feeBefore;
    vm.revertToState(snap);
  }

  /// @dev Fee shares the default fee takes on `minted` shares (rounded up for the recipient).
  function _feeOn(uint256 minted) internal pure returns (uint256) {
    return minted.mulDivUp(DEFAULT_FEE_BPS, BPS);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ENTER                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_smoke_enterThenExit() public {
    uint256 amount = 1_000e18;
    (uint256 shares, uint256 debt) = _enter(user, amount, user);
    assertEq(debt, amount * SEED_DEBT / SEED_COLLATERAL, "ratio debt");
    assertEq(debtToken.balanceOf(user), debt, "debt forwarded");
    assertEq(positionManager.balanceOf(user), shares, "shares forwarded");
    assertGt(positionManager.balanceOf(feeRecipient), 0, "fee shares");
    _assertFacilityClean();
    _assertNoAllowances();

    (uint256 out, uint256 debtIn) = _exit(user, shares, receiver);
    assertGt(out, 0, "underlying out");
    assertGt(debtIn, 0, "debt in");
    assertEq(underlyingToken.balanceOf(receiver), out, "underlying forwarded");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_enter_happyPath() public {
    uint256 amount = 1_000e18;
    uint256 expectedDebt = _expectedDebt(amount);
    uint256 supplyBefore = positionManager.totalSupply();
    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 debtBefore = positionManager.debtAmount();

    (uint256 shares, uint256 debt) = _enter(user, amount, receiver);

    uint256 minted = positionManager.totalSupply() - supplyBefore;
    uint256 feeShares = positionManager.balanceOf(feeRecipient);
    assertGt(shares, 0, "no shares minted");
    assertEq(debt, expectedDebt, "debt != amount * D / C");
    assertEq(feeShares, _feeOn(minted), "fee shares != ceil share of the mint");
    assertEq(shares + feeShares, minted, "net + fee != minted");
    // The receiver gets the whole debt and the net shares; the user paid the underlying.
    assertEq(debtToken.balanceOf(receiver), debt, "receiver debt");
    assertEq(positionManager.balanceOf(receiver), shares, "receiver shares");
    assertEq(debtToken.balanceOf(user), 0, "user got debt");
    assertEq(positionManager.balanceOf(user), 0, "user got shares");
    assertEq(underlyingToken.balanceOf(user), 0, "user underlying spent");
    assertEq(debtToken.balanceOf(feeRecipient), 0, "fee is not paid in debt asset");
    // PM totals grew by exactly the wrapped amount and the borrowed debt.
    assertEq(positionManager.collateralAmount(), collateralBefore + amount, "PM collateral");
    assertApproxEqAbs(positionManager.debtAmount(), debtBefore + debt, 1, "PM debt");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_enter_ratioDerivedDebtExact() public {
    // Seed ratio is exactly 0.5e-12 debt units per collateral wei.
    uint256 amount = 1_000e18;
    assertEq(_expectedDebt(amount), 500e6, "fixture ratio");
    (, uint256 debt) = _enter(user, amount, receiver);
    assertEq(debt, 500e6, "debt != amount * D / C");
    assertEq(debtToken.balanceOf(receiver), 500e6, "receiver got the full debt");
    _assertFacilityClean();
  }

  function test_enter_ratioDerivedDebt_afterInterestAccrual() public {
    uint256 ratioDebtBefore = _expectedDebt(1_000e18);
    vm.warp(block.timestamp + 180 days);
    morpho.accrueInterest(marketParams);

    uint256 amount = 1_000e18;
    uint256 expectedDebt = _expectedDebt(amount);
    assertGt(expectedDebt, ratioDebtBefore, "interest did not drift the ratio up");

    (, uint256 debt) = _enter(user, amount, receiver);
    assertEq(debt, expectedDebt, "debt != drifted amount * D / C");
    _assertFacilityClean();
  }

  function test_enter_feeSharesRoundUpForRecipient() public {
    // At the seed state the share price is exactly 1e12 and every mint is a multiple of 400
    // (25 bps = 1/400): accrue interest so the price drifts, then find an amount whose mint
    // is not a multiple of 400 so the fee rounds.
    vm.warp(block.timestamp + 30 days);
    morpho.accrueInterest(marketParams);
    uint256 amount;
    uint256 minted;
    for (uint256 k = 1; k <= 64; ++k) {
      amount = 1_000e18 + k * 2e12;
      (uint256 shares,, uint256 feeShares) = _dryRunEnter(user, amount, receiver);
      minted = shares + feeShares;
      if (minted % 400 != 0) break;
    }
    assertTrue(minted % 400 != 0, "no rounding candidate found");

    (uint256 netShares,) = _enter(user, amount, receiver);
    uint256 fee = positionManager.balanceOf(feeRecipient);
    assertEq(fee, _feeOn(minted), "fee != mulDivUp share of the mint");
    assertGt(fee, minted * DEFAULT_FEE_BPS / BPS, "fee not strictly above the floor");
    assertEq(netShares, minted - fee, "net shares");
    assertEq(positionManager.balanceOf(receiver), netShares, "receiver net shares");
  }

  function test_enter_zeroFeeGivesAllMintedShares() public {
    _openOffersNoFee();
    uint256 supplyBefore = positionManager.totalSupply();
    (uint256 shares,) = _enter(user, 1_000e18, receiver);
    uint256 minted = positionManager.totalSupply() - supplyBefore;
    assertEq(shares, minted, "net shares != minted");
    assertEq(positionManager.balanceOf(receiver), minted, "receiver got every share");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "fee recipient got shares at zero fee");
    _assertFacilityClean();
  }

  function test_enter_revertsOnMinDebt() public {
    uint256 amount = 1_000e18;
    uint256 expectedDebt = _expectedDebt(amount);
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(
        IInKindFacility.DebtOutOfBounds.selector, expectedDebt, expectedDebt + 1, type(uint256).max
      )
    );
    facility.enter(address(positionManager), amount, expectedDebt + 1, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsOnMaxDebt() public {
    uint256 amount = 1_000e18;
    uint256 expectedDebt = _expectedDebt(amount);
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DebtOutOfBounds.selector, expectedDebt, 0, expectedDebt - 1));
    facility.enter(address(positionManager), amount, 0, expectedDebt - 1, 0, receiver);
  }

  function test_enter_revertsOnMinSharesOut() public {
    uint256 amount = 1_000e18;
    (uint256 actualShares,,) = _dryRunEnter(user, amount, receiver);

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, actualShares, actualShares + 1)
    );
    facility.enter(address(positionManager), amount, 0, type(uint256).max, actualShares + 1, receiver);
  }

  function test_enter_absoluteCapConsumedWithGrossDebt() public {
    uint256 cap = 600e6;
    _setEntry(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);

    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertEq(debt, 500e6, "gross debt");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, cap - debt, "cap not decremented by the debt");
    _assertFacilityClean();
  }

  function test_enter_absoluteCapExhaustionRevertsBeforeTokenMovement() public {
    uint256 cap = 600e6;
    _setEntry(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _enter(user, 1_000e18, receiver); // consumes 500e6, leaves 100e6

    uint256 amount = 1_000e18;
    uint256 nextDebt = _expectedDebt(amount);
    uint256 securityBefore = facility.getSecurityCap(address(underlyingToken), address(debtToken));
    uint256 supplyBefore = positionManager.totalSupply();
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _pmId(positionManager), cap - 500e6, nextDebt)
    );
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);

    // Nothing moved: the user keeps the underlying, the PM and the security cap are untouched.
    assertEq(underlyingToken.balanceOf(user), amount, "user underlying moved");
    assertEq(positionManager.totalSupply(), supplyBefore, "PM supply moved");
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)), securityBefore, "security cap moved"
    );
    assertEq(facility.getEntry(address(positionManager)).capacityCap, cap - 500e6, "capacity moved");
    _assertFacilityClean();
  }

  function test_enter_externalAbsoluteWordConsumesPool() public {
    _setAbsPool(600e6, 1_000e6);
    uint256 word = _absWord(MULT_1X);
    _setEntry(positionManager, word, FAR_EXPIRY, DEFAULT_FEE_BPS);

    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertEq(_absCap(POOL_ID), 600e6 - debt, "pool not decremented by the debt");
    // The EXTERNAL word itself is stored unchanged.
    assertEq(facility.getEntry(address(positionManager)).capacityCap, word, "external word mutated");
    _assertFacilityClean();
  }

  function test_enter_multiPoolWordSpillsOver() public {
    _setAbsPool(300e6, 1_000e6);
    _setAbsPoolAt(OTHER_POOL_ID, 1_000e6, 1_000e6);
    _setEntry(positionManager, _absPoolsWord(_poolIds(POOL_ID, OTHER_POOL_ID, 0), MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);

    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertGt(debt, 300e6, "debt should exceed the first pool");
    assertEq(_absCap(POOL_ID), 0, "first pool not drained first");
    assertEq(_absCap(OTHER_POOL_ID), 1_000e6 - (debt - 300e6), "second pool did not take the rest");
    _assertFacilityClean();
  }

  function test_enter_multiPoolWordRevertsWhenPoolsTogetherFallShort() public {
    _setAbsPool(100e6, 1_000e6);
    _setAbsPoolAt(OTHER_POOL_ID, 100e6, 1_000e6);
    uint64 ids = _poolIds(POOL_ID, OTHER_POOL_ID, 0);
    _setEntry(positionManager, _absPoolsWord(ids, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);

    uint256 amount = 1_000e18;
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, ids));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
    assertEq(_absCap(POOL_ID), 100e6, "first pool moved on a reverted entry");
  }

  function test_enter_externalDynamicWordConsumesAndExhausts() public {
    _setDynPoolFull(POOL_ID, 600e6);
    _setEntry(positionManager, _dynWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);

    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertApproxEqAbs(_dynRemaining(POOL_ID), 600e6 - debt, _dynTolerance(600e6), "dynamic cap not consumed");

    uint256 amount = 1_000e18;
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsOnExpiredOffer() public {
    uint40 expiry = uint40(block.timestamp + 1 hours);
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, expiry, DEFAULT_FEE_BPS);

    // Enabled strictly before expiry, disabled the second expiry is reached.
    vm.warp(expiry - 1);
    (uint256 shares,) = _enter(user, 1_000e18, receiver);
    assertGt(shares, 0, "entry one second before expiry");

    vm.warp(expiry);
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, address(positionManager)));
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsOnNeverSetOffer() public {
    _seedPool(positionManager2, SEED_COLLATERAL, SEED_DEBT);
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, address(positionManager2)));
    facility.enter(address(positionManager2), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsAfterDisableViaExpiryZero() public {
    _setEntry(positionManager, 0, 0, 0);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, address(positionManager)));
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    // Disabling zeroes the whole offer; the exit side is untouched.
    EntryOffer memory offer = facility.getEntry(address(positionManager));
    assertEq(offer.capacityCap, 0, "cap zeroed");
    assertEq(offer.expiry, 0, "expiry zeroed");
    assertEq(offer.feeBps, 0, "fee zeroed");
    assertEq(facility.getExit(address(positionManager)).expiry, FAR_EXPIRY, "exit side touched");
  }

  function test_enter_revertsWhenPaused() public {
    vm.prank(compliance);
    facility.pauseFor(1 days);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    // Unpause via pauseFor(0) restores the flow.
    vm.prank(owner);
    facility.pauseFor(0);
    vm.prank(user);
    (uint256 shares,) = facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
    assertGt(shares, 0, "entry after unpause");
  }

  function test_enter_worksAfterPauseExpiry() public {
    vm.prank(owner);
    facility.pauseFor(1 days);
    vm.warp(block.timestamp + 1 days);
    (, bool isPaused,) = facility.config();
    assertFalse(isPaused, "still paused at expiry");

    (uint256 shares,) = _enter(user, 1_000e18, receiver);
    assertGt(shares, 0, "entry after pause expiry");
  }

  function test_enter_revertsOnBadDebt() public {
    _triggerBadDebt();
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(positionManager)));
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsOnUnleveredPoolWhileTheOfferIsClosedToIt() public {
    // Collateral but zero debt on a fresh PM, and an offer that does not opt in.
    _seedPool(positionManager2, SEED_COLLATERAL, 0);
    _setEntry(positionManager2, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnleveredEntryDisabled.selector, address(positionManager2)));
    facility.enter(address(positionManager2), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsOnEmptyPool() public {
    _setEntry(positionManager2, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.EmptyPool.selector, address(positionManager2)));
    facility.enter(address(positionManager2), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsOnZeroDebtRounding() public {
    // amount * D / C = 1e12 * 0.5e-12 = 0.5 -> rounds to 0 -> cap bypass guard.
    uint256 amount = 1e12;
    assertEq(_expectedDebt(amount), 0, "debt must round to zero");
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, amount));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
  }

  function test_enter_revertsOnZeroAmountAndZeroReceiver() public {
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.enter(address(positionManager), 0, 0, type(uint256).max, 0, receiver);

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, address(0));
  }

  function test_enter_emitsEvent() public {
    uint256 amount = 1_000e18;
    (uint256 expectedShares, uint256 expectedDebt, uint256 expectedFee) = _dryRunEnter(user, amount, receiver);

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Entered(
      address(positionManager), user, receiver, amount, expectedDebt, expectedShares, expectedFee
    );
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   SECURITY CAP AND AUTHS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_security_entryWithoutAuthConsumesSecurityCap() public {
    _setSecurityCap(1_000e6);
    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)),
      1_000e6 - debt,
      "security cap not decremented"
    );
    // No auth was involved.
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "auth touched");
  }

  function test_security_zeroCapRevertsWithAssetId() public {
    _setSecurityCap(0);
    uint256 amount = 1_000e18;
    uint256 debt = _expectedDebt(amount);
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _assetId(), 0, debt));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
  }

  function test_security_unsetCapRevertsWithAssetId() public {
    // A fresh facility never had its security cap set: it reads as a zero ABSOLUTE cap.
    InKindFacility fresh = InKindFacility(address(implementation).clone());
    fresh.initialize(owner, facilitator, feeRecipient);
    vm.prank(facilitator);
    fresh.setEntry(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    assertEq(fresh.getSecurityCap(address(underlyingToken), address(debtToken)), 0, "unset security cap");

    uint256 amount = 1_000e18;
    uint256 debt = _expectedDebt(amount);
    underlyingToken.setBalance(user, amount);
    vm.startPrank(user);
    underlyingToken.approve(address(fresh), amount);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _assetId(), 0, debt));
    fresh.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
    vm.stopPrank();
  }

  function test_security_authCoversWholeDebt() public {
    _setSecurityCap(1_000e6);
    _setAuth(user, 600e6, FAR_EXPIRY);
    uint256 amount = 1_000e18;
    uint256 debt = _expectedDebt(amount);

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.AuthConsumed(address(underlyingToken), address(debtToken), user, debt, uint128(600e6 - debt));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);

    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 1_000e6, "security cap touched");
    Auth memory auth = facility.getAuth(address(underlyingToken), address(debtToken), user);
    assertEq(auth.amount, 600e6 - debt, "auth not decremented");
    assertEq(auth.expiry, FAR_EXPIRY, "auth expiry changed");
  }

  function test_security_authSpillsOverIntoSecurityCap() public {
    _setSecurityCap(1_000e6);
    _setAuth(user, 200e6, FAR_EXPIRY);
    uint256 amount = 1_000e18;
    uint256 debt = _expectedDebt(amount);
    assertGt(debt, 200e6, "debt must exceed the auth");

    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.AuthConsumed(address(underlyingToken), address(debtToken), user, 200e6, 0);
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);

    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "auth not drained");
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)),
      1_000e6 - (debt - 200e6),
      "security cap took the wrong remainder"
    );
  }

  function test_security_authIsPerCaller() public {
    // The auth is keyed by msg.sender, not by the receiver.
    _setSecurityCap(1_000e6);
    _setAuth(receiver, 600e6, FAR_EXPIRY);
    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertEq(
      facility.getAuth(address(underlyingToken), address(debtToken), receiver).amount, 600e6, "receiver auth consumed"
    );
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)), 1_000e6 - debt, "security cap not consumed"
    );
  }

  function test_security_expiredAuthIgnored() public {
    _setSecurityCap(1_000e6);
    _setAuth(user, 600e6, uint40(block.timestamp + 1 hours));
    vm.warp(block.timestamp + 2 hours);

    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)),
      1_000e6 - debt,
      "security cap did not take all"
    );
    assertEq(
      facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 600e6, "expired auth consumed"
    );
  }

  function test_security_authExpiryAtTimestampIsExpired() public {
    _setSecurityCap(1_000e6);
    // `block.timestamp < expiry` semantics: an auth expiring exactly now is already expired.
    _setAuth(user, 600e6, uint40(block.timestamp));
    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)), 1_000e6 - debt, "auth at expiry was used"
    );
    assertEq(
      facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 600e6, "auth at expiry consumed"
    );

    // One second of validity is enough.
    _setAuth(user, 600e6, uint40(block.timestamp + 1));
    _enter(user, 1_000e18, receiver);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)),
      1_000e6 - debt,
      "security cap used over a live auth"
    );
    assertLt(
      facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 600e6, "live auth not consumed"
    );
  }

  function test_setAuth_overwrites() public {
    _setSecurityCap(1_000e6);
    _setAuth(user, 100e6, FAR_EXPIRY);
    _setAuth(user, 700e6, uint40(block.timestamp + 1 days));
    Auth memory auth = facility.getAuth(address(underlyingToken), address(debtToken), user);
    assertEq(auth.amount, 700e6, "amount not overwritten");
    assertEq(auth.expiry, uint40(block.timestamp + 1 days), "expiry not overwritten");

    // Re-setting after a partial consumption overwrites the remaining amount too.
    _enter(user, 1_000e18, receiver);
    assertEq(
      facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 200e6, "auth partially consumed"
    );
    _setAuth(user, 700e6, FAR_EXPIRY);
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 700e6, "auth not re-armed");
  }

  function test_setAuth_expiryZeroRevokes() public {
    _setSecurityCap(1_000e6);
    _setAuth(user, 600e6, FAR_EXPIRY);
    _setAuth(user, 0, 0);
    Auth memory auth = facility.getAuth(address(underlyingToken), address(debtToken), user);
    assertEq(auth.amount, 0, "amount not cleared");
    assertEq(auth.expiry, 0, "expiry not cleared");

    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)), 1_000e6 - debt, "revoked auth still used"
    );
  }

  function test_security_capSharedAcrossPositionManagers() public {
    _seedPool(positionManager2, SEED_COLLATERAL, SEED_DEBT);
    _setEntry(positionManager2, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(2_000e6);

    (, uint256 debt1) = _enter(positionManager, user, 1_000e18, receiver);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)), 2_000e6 - debt1, "first PM did not consume"
    );
    (, uint256 debt2) = _enter(positionManager2, user, 1_000e18, receiver);
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)),
      2_000e6 - debt1 - debt2,
      "second PM did not consume"
    );
    assertEq(positionManager2.balanceOf(receiver), positionManager2.balanceOf(receiver), "sanity");
    assertGt(positionManager2.balanceOf(receiver), 0, "PM2 shares");
    _assertFacilityClean();
  }

  function test_security_externalDynamicWordConsumesAndExhausts() public {
    _setDynPoolFull(SECURITY_POOL_ID, 600e6);
    _setSecurityCap(_dynWord(SECURITY_POOL_ID, MULT_1X));

    (, uint256 debt) = _enter(user, 1_000e18, receiver);
    assertApproxEqAbs(
      _dynRemaining(SECURITY_POOL_ID), 600e6 - debt, _dynTolerance(600e6), "dynamic security cap not consumed"
    );

    uint256 amount = 1_000e18;
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, SECURITY_POOL_ID));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
  }

  function test_security_capacityExhaustionSurfacesBeforeSecurity() public {
    // Both caps are too small: the capacity error surfaces (consumed first).
    _setEntry(positionManager, 100e6, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(100e6);
    uint256 amount = 1_000e18;
    uint256 debt = _expectedDebt(amount);
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _pmId(positionManager), 100e6, debt));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 100e6, "security cap touched");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, 100e6, "capacity touched");
    assertEq(underlyingToken.balanceOf(user), amount, "tokens moved");
  }

  function test_security_securityExhaustionSurfacesAfterCapacity() public {
    // Capacity is plenty, the security cap is too small: the security error surfaces and the
    // capacity consumption is rolled back with the revert.
    _setEntry(positionManager, 1_000e6, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(100e6);
    uint256 amount = 1_000e18;
    uint256 debt = _expectedDebt(amount);
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _assetId(), 100e6, debt));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
    assertEq(facility.getEntry(address(positionManager)).capacityCap, 1_000e6, "capacity consumption not rolled back");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 100e6, "security cap touched");
    assertEq(underlyingToken.balanceOf(user), amount, "tokens moved");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            EXIT                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_happyPath() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);
    uint256 supplyBefore = positionManager.totalSupply();

    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee,) =
      facility.previewExit(address(positionManager), shares);
    (uint256 out, uint256 debtIn) = _exit(user, shares, receiver);

    assertEq(out, previewOut, "underlying out matches preview");
    assertEq(debtIn, previewDebtIn, "debtIn matches preview");
    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    assertEq(collateralToken.balanceOf(receiver), 0, "receiver got the wrapper instead of the underlying");
    assertEq(positionManager.balanceOf(user), 0, "shares not pulled");
    assertEq(positionManager.balanceOf(feeRecipient) - feeSharesBefore, previewFee, "fee shares to the recipient");
    assertEq(supplyBefore - positionManager.totalSupply(), shares - previewFee, "burned shares != shares - fee");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_exit_proportionalAmountsMatchMirrorMath() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    vm.warp(block.timestamp + 30 days);

    uint256 half = shares / 2;
    uint256 expectedFee = _feeOn(half);
    uint256 burnShares = half - expectedFee;
    uint256 expectedDebtIn = positionManager.debtAmount().mulDivUp(burnShares, _adjustedSupply());
    uint256 expectedOut = positionManager.collateralAmount().mulDiv(burnShares, _adjustedSupply());

    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);
    (uint256 out, uint256 debtIn) = _exit(user, half, receiver);
    assertEq(out, expectedOut, "collateral out != proportional slice of burnShares");
    assertEq(debtIn, expectedDebtIn, "debtIn != rounded-up proportional slice of burnShares");
    assertEq(positionManager.balanceOf(feeRecipient) - feeSharesBefore, expectedFee, "fee shares");
    _assertFacilityClean();
  }

  function test_exit_feeSharesToRecipientAndBurnSharesBurned() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);
    uint256 supplyBefore = positionManager.totalSupply();
    uint256 userDebtBefore = debtToken.balanceOf(user);

    (uint256 previewDebtIn,, uint256 previewFee,) = facility.previewExit(address(positionManager), shares);
    uint256 allowance = _required(previewDebtIn);
    _approveExit(user, shares, allowance);
    vm.prank(user);
    (, uint256 debtIn) = facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    assertEq(positionManager.balanceOf(feeRecipient) - feeSharesBefore, previewFee, "fee shares forwarded");
    assertEq(supplyBefore - positionManager.totalSupply(), shares - previewFee, "burnShares burned");
    assertEq(positionManager.balanceOf(user), 0, "user shares pulled");
    assertEq(debtToken.balanceOf(user), userDebtBefore + allowance - debtIn, "exactly debtIn pulled");
    assertEq(debtToken.allowance(user, address(facility)), 0, "the required pull consumed the allowance");
    _assertFacilityClean();
  }

  function test_exit_revertsNothingToBurnWhenFeeEatsEverything() public {
    // 1 share at 25 bps: fee = ceil(1 * 25 / 10_000) = 1, nothing left to burn.
    vm.prank(user);
    vm.expectRevert(IInKindFacility.NothingToBurn.selector);
    facility.exit(address(positionManager), 1, type(uint256).max, 0, receiver, "");

    vm.expectRevert(IInKindFacility.NothingToBurn.selector);
    facility.previewExit(address(positionManager), 1);

    // Two shares leave one to burn.
    (uint256 debtIn,, uint256 feeShares,) = facility.previewExit(address(positionManager), 2);
    assertEq(feeShares, 1, "fee on two shares");
    assertGt(debtIn, 0, "one burnable share still owes a rounded-up debt wei");
  }

  function test_exit_revertsOnMaxDebtIn() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    (,,, uint256 required) = facility.previewExit(address(positionManager), shares);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.ExcessiveDebtIn.selector, required, required - 1));
    facility.exit(address(positionManager), shares, required - 1, 0, receiver, "");
  }

  function test_exit_revertsOnMinUnderlyingOut() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    (uint256 previewDebtIn, uint256 previewOut,,) = facility.previewExit(address(positionManager), shares);
    _approveExit(user, shares, _required(previewDebtIn));
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(IInKindFacility.InsufficientUnderlyingOut.selector, previewOut, previewOut + 1)
    );
    facility.exit(address(positionManager), shares, type(uint256).max, previewOut + 1, receiver, "");
  }

  function test_exit_absoluteCapConsumedWithDebtIn() public {
    uint256 cap = 1_000e6;
    _setExit(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, 1_000e18, user);

    (, uint256 debtIn) = _exit(user, shares, receiver);
    assertGt(debtIn, 0, "debtIn");
    assertEq(facility.getExit(address(positionManager)).cap, cap - debtIn, "exit cap not decremented by debtIn");
    _assertFacilityClean();
  }

  function test_exit_absoluteCapExhaustionReverts() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    (uint256 previewDebtIn,,,) = facility.previewExit(address(positionManager), shares);
    uint256 cap = previewDebtIn - 1;
    _setExit(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);

    _approveExit(user, shares, _required(previewDebtIn));
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _pmId(positionManager), cap, previewDebtIn)
    );
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
    assertEq(positionManager.balanceOf(user), shares, "shares moved on a capped exit");
  }

  function test_exit_externalNegativeMultiplierGivesCapacityBack() public {
    _setAbsPool(800e6, 1_000e6);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);

    // Entry consumes the shared pool with the gross debt.
    (uint256 shares, uint256 debt) = _enter(user, 1_000e18, user);
    uint256 afterEnter = _absCap(POOL_ID);
    assertEq(afterEnter, 800e6 - debt, "entry did not consume the pool");

    // Exit releases debtIn back into the pool (negative multiplier).
    (, uint256 debtIn) = _exit(user, shares, receiver);
    uint256 afterExit = _absCap(POOL_ID);
    assertEq(afterExit, afterEnter + debtIn, "exit did not release into the pool");
    // Round trips are lossy (two share fees plus rounding), so the pool lands just below start.
    assertLt(afterExit, 800e6, "round trip created capacity");
    assertApproxEqRel(afterExit, 800e6, 1e16, "pool did not return near its start");
    _assertFacilityClean();
  }

  function test_exit_multiPoolWordRefillsFirstPoolFirst() public {
    // [asset pool, shared pool]: the asset pool's hard cap is its own allocation.
    _setAbsPool(300e6, 300e6);
    _setAbsPoolAt(OTHER_POOL_ID, 1_000e6, 1_000e6);
    uint64 ids = _poolIds(POOL_ID, OTHER_POOL_ID, 0);
    _setEntry(positionManager, _absPoolsWord(ids, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, _absPoolsWord(ids, MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);

    (uint256 shares, uint256 debt) = _enter(user, 1_000e18, user);
    uint256 sharedAfterEnter = 1_000e6 - (debt - 300e6);

    // The exit refills the asset pool up to its hard cap, then spills into the shared pool.
    (, uint256 debtIn) = _exit(user, shares, receiver);
    assertGt(debtIn, 300e6, "exit should reach the shared pool");
    assertEq(_absCap(POOL_ID), 300e6, "asset pool not refilled first");
    assertEq(_absCap(OTHER_POOL_ID), sharedAfterEnter + (debtIn - 300e6), "shared pool did not take the rest");
    _assertFacilityClean();
  }

  function test_exit_releaseAboveHardCapReverts() public {
    // Pool already full: any release overflows the hard cap.
    _setAbsPool(1_000e6, 1_000e6);
    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, 1_000e18, user);

    (uint256 previewDebtIn,,,) = facility.previewExit(address(positionManager), shares);
    _approveExit(user, shares, _required(previewDebtIn));
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, POOL_ID));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
  }

  function test_exit_fullSupplyThroughFacility() public {
    // Zero exit fee so the fee recipient's own exit does not mint it new fee shares forever.
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    (uint256 userShares,) = _enter(user, 1_000e18, user);
    uint256 seederShares = positionManager.balanceOf(seeder);
    uint256 feeShares = positionManager.balanceOf(feeRecipient);
    assertGt(seederShares, 0, "seeder holds no shares");
    assertGt(feeShares, 0, "fee recipient holds no shares");

    (uint256 userOut,) = _exit(user, userShares, user);
    assertGt(userOut, 0, "user exit");
    _assertFacilityClean();

    // The seeder and the fee recipient exit their entire stakes through the facility too.
    (uint256 seederOut,) = _exit(seeder, seederShares, seeder);
    assertGt(seederOut, 0, "seeder exit");
    (uint256 feeOut,) = _exit(feeRecipient, feeShares, feeRecipient);
    assertGt(feeOut, 0, "fee recipient exit");
    assertEq(positionManager.totalSupply(), 0, "supply not fully exited");
    // Rounding leaves pool-favoring dust behind (virtual-offset slice), never a shortfall.
    _assertFacilityClean();
  }

  function test_exit_fromUnleveredPool() public {
    uint256 exitCap = 1_000e6;
    _setExit(positionManager, exitCap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, 1_000e18, user);
    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);

    _unleverPool();
    // Entries are closed to everyone; exits do not read the security cap.
    _setSecurityCap(0);

    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee,) =
      facility.previewExit(address(positionManager), shares);
    assertEq(previewDebtIn, 0, "unlevered debtIn must be zero");
    // The share fee is independent of the debt leg.
    assertEq(previewFee, _feeOn(shares), "share fee skipped on an unlevered pool");

    // No debt approval at all: the exit must not pull any.
    vm.startPrank(user);
    positionManager.approve(address(facility), shares);
    (uint256 out, uint256 debtIn) = facility.exit(address(positionManager), shares, 0, 0, receiver, "");
    vm.stopPrank();

    assertEq(debtIn, 0, "debt pulled");
    assertEq(out, previewOut, "out matches preview");
    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    assertEq(positionManager.balanceOf(feeRecipient) - feeSharesBefore, previewFee, "fee shares");
    // The cap word is untouched: a zero debt leg skips consumption entirely.
    assertEq(facility.getExit(address(positionManager)).cap, exitCap, "cap consumed on zero debt");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_exit_withAccruedPmFees() public {
    _setPmFees(200, 2000);
    (uint256 shares,) = _enter(user, 1_000e18, user);

    // Time + an oracle up-print accrue management and performance fee shares.
    vm.warp(block.timestamp + 90 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    (, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    assertGt(mgmtShares, 0, "no pending management fee shares");
    assertGt(perfShares, 0, "no pending performance fee shares");

    // The preview denominator includes pending fee shares, diluting the exiter's slice.
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee,) =
      facility.previewExit(address(positionManager), shares);
    uint256 undilutedOut = positionManager.collateralAmount()
      .mulDiv(shares - previewFee, totalSupply_ + positionManager.virtualShareOffset());
    assertLt(previewOut, undilutedOut, "fee shares must dilute the exiter");

    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);
    (uint256 out, uint256 debtIn) = _exit(user, shares, receiver);
    assertEq(out, previewOut, "out matches preview across fee accrual");
    assertEq(debtIn, previewDebtIn, "debtIn matches preview across fee accrual to the wei");
    assertEq(positionManager.balanceOf(feeRecipient) - feeSharesBefore, previewFee, "fee matches preview");
    assertGt(positionManager.balanceOf(pmFeeRecipient), 0, "PM fee shares not crystallized by burn");
    _assertFacilityClean();
  }

  function test_exit_callbackSourcesDebt() public {
    ExitCallbackStub stub = new ExitCallbackStub(address(facility), address(debtToken));
    (uint256 shares,) = _enter(user, 1_000e18, address(stub));
    (uint256 previewDebtIn, uint256 previewOut,,) = facility.previewExit(address(positionManager), shares);
    debtToken.setBalance(address(stub), _required(previewDebtIn));

    // The stub approves exactly the debt it is told inside the callback.
    bytes memory data = abi.encode("source");
    (uint256 out, uint256 debtIn) = stub.doExit(address(positionManager), shares, data);
    assertEq(stub.calls(), 1, "callback not invoked once");
    assertEq(stub.lastPositionManager(), address(positionManager), "callback pm");
    assertEq(stub.lastShares(), shares, "callback shares (fee included)");
    assertEq(stub.lastDebtIn(), _required(previewDebtIn), "callback debtIn");
    assertEq(keccak256(stub.lastData()), keccak256(data), "callback data");
    assertEq(debtIn, previewDebtIn, "debtIn");
    assertEq(out, previewOut, "out");
    assertEq(underlyingToken.balanceOf(address(stub)), out, "stub received the underlying");
    assertEq(
      debtToken.balanceOf(address(stub)),
      _required(previewDebtIn) - previewDebtIn,
      "stub kept only the refunded headroom"
    );
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_exit_emptyDataSkipsCallback() public {
    ExitCallbackStub stub = new ExitCallbackStub(address(facility), address(debtToken));
    (uint256 shares,) = _enter(user, 1_000e18, address(stub));
    (uint256 previewDebtIn,,,) = facility.previewExit(address(positionManager), shares);
    debtToken.setBalance(address(stub), _required(previewDebtIn));
    stub.approveDebt(_required(previewDebtIn));

    stub.doExit(address(positionManager), shares, "");
    assertEq(stub.calls(), 0, "callback invoked on empty data");
  }

  function test_exit_revertsWhenPaused() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    vm.prank(compliance);
    facility.pauseFor(1 days);

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    // Works once the pause lapses.
    vm.warp(block.timestamp + 1 days);
    (uint256 out,) = _exit(user, shares, receiver);
    assertGt(out, 0, "exit after pause expiry");
  }

  function test_exit_revertsOnExpiredOrNeverSetOffer() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    uint40 expiry = uint40(block.timestamp + 1 hours);
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, expiry, DEFAULT_FEE_BPS);
    vm.warp(expiry);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, address(positionManager)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, address(positionManager2)));
    facility.exit(address(positionManager2), shares, type(uint256).max, 0, receiver, "");
  }

  function test_exit_revertsOnBadDebt() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    _triggerBadDebt();
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(positionManager)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
  }

  function test_exit_revertsOnZeroSharesAndZeroReceiver() public {
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.exit(address(positionManager), 0, type(uint256).max, 0, receiver, "");

    vm.prank(user);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    facility.exit(address(positionManager), 1e18, type(uint256).max, 0, address(0), "");
  }

  function test_exit_emitsEvent() public {
    (uint256 shares,) = _enter(user, 1_000e18, user);
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee,) =
      facility.previewExit(address(positionManager), shares);
    _approveExit(user, shares, _required(previewDebtIn));

    vm.prank(user);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Exited(
      address(positionManager), user, receiver, previewOut, previewDebtIn, shares - previewFee, previewFee
    );
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     UNLEVERED POOLS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_unlevered_entryRevertsWhileTheOfferIsClosedToIt() public {
    _unleverPool();
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnleveredEntryDisabled.selector, address(positionManager)));
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_unlevered_entryMintsTheRatioMatchedFractionAndBorrowsNothing() public {
    _unleverPool();
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, true);

    uint256 amount = 1_000e18;
    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 expected = _adjustedSupply().mulDiv(amount, collateralBefore);
    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);

    (uint256 shares, uint256 debt) = _enter(user, amount, receiver);
    uint256 feeShares = positionManager.balanceOf(feeRecipient) - feeSharesBefore;

    assertEq(debt, 0, "unlevered entry borrowed");
    assertEq(debtToken.balanceOf(receiver), 0, "receiver got debt asset");
    assertEq(positionManager.debtAmount(), 0, "pool levered by the entry");
    assertEq(positionManager.collateralAmount(), collateralBefore + amount, "collateral supplied");
    assertEq(positionManager.balanceOf(receiver), shares, "receiver shares");
    // The mint is the fair fraction: the neutrality gate bounds it above, rounding below.
    assertLe(shares + feeShares, expected, "minted above the ratio-matched fraction");
    assertApproxEqRel(shares + feeShares, expected, 1e12, "minted below the ratio-matched fraction");
    assertEq(feeShares, _feeOn(shares + feeShares), "fee shares");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_unlevered_entryConsumesNoCapNoSecurityAndNoAuth() public {
    _unleverPool();
    // Everything a levered entry needs is shut: a zero capacity word, a zero security cap and
    // no auth. None of them is denominated in anything an unlevered entry moves.
    _setEntry(positionManager, 0, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    _setSecurityCap(0);
    _setAuth(user, 0, 0);

    (uint256 shares, uint256 debt) = _enter(user, 1_000e18, receiver);

    assertGt(shares, 0, "no shares minted");
    assertEq(debt, 0, "unlevered entry borrowed");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, 0, "capacity word moved");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 0, "security word moved");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "auth moved");
  }

  function test_unlevered_dustEntryStillRevertsInALeveredPool() public {
    // The flag only opens pools with no debt at all: in a levered pool a debt leg that rounds
    // to zero would still be a free pass on every debt-denominated cap.
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    uint256 amount = 1e12;
    assertEq(_expectedDebt(amount), 0, "debt must round to zero");
    _fundEntrant(user, amount);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, amount));
    facility.enter(address(positionManager), amount, 0, type(uint256).max, 0, receiver);
  }

  function test_unlevered_emptyPoolStillReverts() public {
    // No collateral, so no fraction to match: the flag does not bootstrap a pool.
    _setEntry(positionManager2, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.EmptyPool.selector, address(positionManager2)));
    facility.enter(address(positionManager2), 1_000e18, 0, type(uint256).max, 0, receiver);
  }

  function test_unlevered_offersAreTheOnlyKillSwitch() public {
    _unleverPool();
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    (uint256 shares,) = _enter(user, 1_000e18, user);

    // Entry side: clear the flag, or expire the offer.
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnleveredEntryDisabled.selector, address(positionManager)));
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, 0, DEFAULT_FEE_BPS, true);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, address(positionManager)));
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    // Exit side: the expiry only, since an unlevered exit reads no cap either.
    _setExit(positionManager, 0, 0, DEFAULT_FEE_BPS);
    vm.prank(user);
    positionManager.approve(address(facility), shares);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, address(positionManager)));
    facility.exit(address(positionManager), shares, 0, 0, receiver, "");

    // And the facility-wide pause covers both.
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    _setExit(positionManager, 0, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.prank(compliance);
    facility.pauseFor(1 days);
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.exit(address(positionManager), shares, 0, 0, receiver, "");
  }

  function test_unlevered_roundTripReturnsTheUnderlyingNetOfFees() public {
    _unleverPool();
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    uint256 amount = 1_000e18;

    (uint256 shares, uint256 debt) = _enter(user, amount, user);
    assertEq(debt, 0, "entry borrowed");

    (uint256 out, uint256 debtIn) = _exit(user, shares, receiver);

    assertEq(debtIn, 0, "exit repaid");
    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    // Lossy here: the two share fees outweigh the wei-level rounding.
    assertLt(out, amount, "round trip profited");
    assertApproxEqRel(out, amount, 1e16, "round trip lost more than the fees");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_unlevered_previewAndMaxEnter() public {
    _unleverPool();
    _setEntry(positionManager, 0, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    _setSecurityCap(0);
    uint256 amount = 1_000e18;

    (uint256 debt, uint256 previewShares, uint256 previewFee) = facility.previewEnter(address(positionManager), amount);
    assertEq(debt, 0, "previewed debt");
    assertGt(previewShares, 0, "previewed shares");
    assertEq(previewFee, _feeOn(previewShares + previewFee), "previewed fee");

    // No debt-denominated word bounds the size, and maxExit already reports the same.
    assertEq(facility.maxEnter(address(positionManager), user), type(uint256).max, "maxEnter bounded");
    assertEq(facility.maxExit(address(positionManager)), type(uint256).max, "maxExit bounded");

    (uint256 shares,) = _enter(user, amount, receiver);
    assertApproxEqRel(shares, previewShares, 1e12, "preview off the mint");
  }

  function test_unlevered_flagRoundTripsThroughStorageAndEvent() public {
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.EntrySet(address(positionManager), 123e6, FAR_EXPIRY, 42, true);
    _setEntry(positionManager, 123e6, FAR_EXPIRY, 42, true);
    assertTrue(facility.getEntry(address(positionManager)).allowUnlevered, "flag not stored");

    _setEntry(positionManager, 123e6, FAR_EXPIRY, 42, false);
    assertFalse(facility.getEntry(address(positionManager)).allowUnlevered, "flag not cleared");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_revertsOnZeroAddresses() public {
    InKindFacility fresh = InKindFacility(address(implementation).clone());
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    fresh.initialize(address(0), facilitator, feeRecipient);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    fresh.initialize(owner, facilitator, address(0));

    // Zero facilitator is allowed (role skipped).
    vm.expectEmit(true, true, true, true, address(fresh));
    emit IInKindFacility.FeeRecipientSet(feeRecipient);
    fresh.initialize(owner, address(0), feeRecipient);
    (address recipient, bool isPaused, uint40 pausedUntil) = fresh.config();
    assertEq(recipient, feeRecipient, "fee recipient stored");
    assertFalse(isPaused, "fresh facility paused");
    assertEq(pausedUntil, 0, "fresh pausedUntil");
    assertEq(fresh.owner(), owner, "owner");
    assertFalse(fresh.hasAnyRole(facilitator, FACILITY_FACILITATOR_ROLE), "facilitator role granted");
  }

  function test_initialize_grantsFacilitatorRole() public view {
    assertTrue(facility.hasAllRoles(facilitator, FACILITY_FACILITATOR_ROLE), "facilitator role missing");
    assertEq(facility.owner(), owner, "owner");
  }

  function test_initialize_lockedAfterInit() public {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    facility.initialize(owner, facilitator, feeRecipient);
  }

  function test_initialize_implementationLocked() public {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    implementation.initialize(owner, facilitator, feeRecipient);
  }

  function test_constructor_revertsOnCodelessWhitelist() public {
    address dead = makeAddr("deadWhitelist");
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, dead));
    new InKindFacility(dead);
  }

  function test_constructor_storesWhitelist() public view {
    assertEq(address(facility.CAPS_WHITELIST()), address(whitelist), "whitelist immutable");
    assertEq(address(implementation.CAPS_WHITELIST()), address(whitelist), "whitelist on the implementation");
  }

  function test_setEntry_roleMatrix() public {
    vm.prank(owner);
    facility.setEntry(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    vm.prank(facilitator);
    facility.setEntry(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);

    address[3] memory rejected = [operator, compliance, user];
    for (uint256 i = 0; i < rejected.length; ++i) {
      vm.prank(rejected[i]);
      vm.expectRevert(Ownable.Unauthorized.selector);
      facility.setEntry(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    }
  }

  function test_setExit_roleMatrix() public {
    vm.prank(owner);
    facility.setExit(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.prank(facilitator);
    facility.setExit(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);

    address[3] memory rejected = [operator, compliance, user];
    for (uint256 i = 0; i < rejected.length; ++i) {
      vm.prank(rejected[i]);
      vm.expectRevert(Ownable.Unauthorized.selector);
      facility.setExit(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    }
  }

  function test_setSecurityCap_roleMatrix() public {
    vm.prank(owner);
    facility.setSecurityCap(address(underlyingToken), address(debtToken), 1e6);
    vm.prank(operator);
    facility.setSecurityCap(address(underlyingToken), address(debtToken), 2e6);
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 2e6, "cap stored");

    address[3] memory rejected = [facilitator, compliance, user];
    for (uint256 i = 0; i < rejected.length; ++i) {
      vm.prank(rejected[i]);
      vm.expectRevert(Ownable.Unauthorized.selector);
      facility.setSecurityCap(address(underlyingToken), address(debtToken), 3e6);
    }

    vm.prank(operator);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    facility.setSecurityCap(address(0), address(debtToken), 1e6);
  }

  function test_setAuth_roleMatrix() public {
    vm.prank(owner);
    facility.setAuth(address(underlyingToken), address(debtToken), user, 1e6, FAR_EXPIRY);
    vm.prank(operator);
    facility.setAuth(address(underlyingToken), address(debtToken), user, 2e6, FAR_EXPIRY);
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 2e6, "auth stored");

    address[3] memory rejected = [facilitator, compliance, user];
    for (uint256 i = 0; i < rejected.length; ++i) {
      vm.prank(rejected[i]);
      vm.expectRevert(Ownable.Unauthorized.selector);
      facility.setAuth(address(underlyingToken), address(debtToken), user, 3e6, FAR_EXPIRY);
    }

    vm.prank(operator);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    facility.setAuth(address(0), address(debtToken), user, 1e6, FAR_EXPIRY);
    vm.prank(operator);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    facility.setAuth(address(underlyingToken), address(debtToken), address(0), 1e6, FAR_EXPIRY);
  }

  function test_pauseFor_roleMatrix() public {
    // Compliance pauses.
    vm.prank(compliance);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.InKindFacilityPausedSet(uint40(block.timestamp + 1 days));
    facility.pauseFor(1 days);
    (, bool isPaused, uint40 pausedUntil) = facility.config();
    assertTrue(isPaused, "paused by compliance");
    assertEq(pausedUntil, uint40(block.timestamp + 1 days), "pausedUntil");

    // Owner unpauses and re-pauses.
    vm.prank(owner);
    facility.pauseFor(0);
    (, isPaused, pausedUntil) = facility.config();
    assertFalse(isPaused, "unpaused via pauseFor(0)");
    assertEq(pausedUntil, 0, "pausedUntil cleared");
    vm.prank(owner);
    facility.pauseFor(2 days);
    (, isPaused,) = facility.config();
    assertTrue(isPaused, "paused by owner");

    // Facilitator, operator and strangers are rejected.
    address[3] memory rejected = [facilitator, operator, user];
    for (uint256 i = 0; i < rejected.length; ++i) {
      vm.prank(rejected[i]);
      vm.expectRevert(Ownable.Unauthorized.selector);
      facility.pauseFor(1 days);
    }
  }

  function test_setFeeRecipient() public {
    address newRecipient = makeAddr("newRecipient");
    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.FeeRecipientSet(newRecipient);
    facility.setFeeRecipient(newRecipient);
    (address recipient,,) = facility.config();
    assertEq(recipient, newRecipient, "fee recipient updated");

    // The new recipient receives the share fees from then on.
    _enter(user, 1_000e18, receiver);
    assertGt(positionManager.balanceOf(newRecipient), 0, "new recipient got no fee shares");
    assertEq(positionManager.balanceOf(feeRecipient), 0, "old recipient still paid");

    vm.prank(owner);
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    facility.setFeeRecipient(address(0));

    // Owner-only: every role holder is rejected.
    address[4] memory rejected = [facilitator, operator, compliance, user];
    for (uint256 i = 0; i < rejected.length; ++i) {
      vm.prank(rejected[i]);
      vm.expectRevert(Ownable.Unauthorized.selector);
      facility.setFeeRecipient(newRecipient);
    }
  }

  function test_setEntryAndExit_revertOnFeeAboveMax() public {
    vm.prank(facilitator);
    vm.expectRevert(IInKindFacility.FeeExceedsMax.selector);
    facility.setEntry(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, uint24(MAX_FEE + 1), false);
    vm.prank(facilitator);
    vm.expectRevert(IInKindFacility.FeeExceedsMax.selector);
    facility.setExit(address(positionManager), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, uint24(MAX_FEE + 1));

    // Exactly the max is accepted on both sides.
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, uint24(MAX_FEE));
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, uint24(MAX_FEE));
    assertEq(facility.getEntry(address(positionManager)).feeBps, MAX_FEE, "max entry fee stored");
    assertEq(facility.getExit(address(positionManager)).feeBps, MAX_FEE, "max exit fee stored");
  }

  function test_setEntryAndExit_revertOnInvalidPositionManager() public {
    address[4] memory bad;
    // No code at all.
    bad[0] = makeAddr("eoa");
    // A contract without assets().
    bad[1] = address(new MockERC20("X", "X", 18));
    // assets() resolving to an EOA collateral.
    bad[2] = address(new PmSurfaceStub(makeAddr("eoaCollateral")));
    // assets() resolving to a contract collateral without underlying().
    bad[3] = address(new PmSurfaceStub(address(new MockERC20("Y", "Y", 18))));

    for (uint256 i = 0; i < bad.length; ++i) {
      vm.prank(facilitator);
      vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InvalidPositionManager.selector, bad[i]));
      facility.setEntry(bad[i], LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
      vm.prank(facilitator);
      vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InvalidPositionManager.selector, bad[i]));
      facility.setExit(bad[i], LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    }

    // underlying() resolving to the zero address.
    address zeroUnderlyingPm = address(new PmSurfaceStub(address(new ZeroUnderlyingWrapper())));
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InvalidPositionManager.selector, zeroUnderlyingPm));
    facility.setEntry(zeroUnderlyingPm, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, false);

    // A stub whose collateral is the real wrapper passes the surface check.
    address surfacePm = address(new PmSurfaceStub(address(collateralToken)));
    _setEntry(PositionManager(surfacePm), LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.getEntry(surfacePm).expiry, FAR_EXPIRY, "surface-valid PM rejected");
  }

  function test_setters_validateCapWord() public {
    uint256[7] memory words;
    bytes[7] memory errors;
    // Unknown type byte.
    words[0] = uint256(2) << 248;
    errors[0] = abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, words[0]);
    // EXTERNAL word with the un-negatable int24.min multiplier, rejected by the caps contract.
    words[1] = _absWord(type(int24).min);
    errors[1] = abi.encodeWithSelector(IFacilityCaps.InvalidMultiplier.selector);
    // EXTERNAL word pointing at a caps contract the whitelist does not allow.
    address rogueCaps = address(new FacilityAbsoluteCaps());
    words[2] = _externalWord(rogueCaps, POOL_ID, MULT_1X);
    errors[2] = abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, rogueCaps);
    // Absolute cap IDs the caps contract rejects: no pool, a gap, a repeat, id1 missing.
    words[3] = _absPoolsWord(0, MULT_1X);
    words[4] = _absPoolsWord(_poolIds(POOL_ID, 0, OTHER_POOL_ID), MULT_1X);
    words[5] = _absPoolsWord(_poolIds(POOL_ID, POOL_ID, 0), MULT_1X);
    words[6] = _absPoolsWord(_poolIds(0, POOL_ID, 0), MULT_1X);
    for (uint256 i = 3; i < words.length; ++i) {
      errors[i] = abi.encodeWithSelector(FacilityAbsoluteCaps.InvalidCapId.selector);
    }

    for (uint256 i = 0; i < words.length; ++i) {
      vm.prank(facilitator);
      vm.expectRevert(errors[i]);
      facility.setEntry(address(positionManager), words[i], FAR_EXPIRY, DEFAULT_FEE_BPS, false);
      vm.prank(facilitator);
      vm.expectRevert(errors[i]);
      facility.setExit(address(positionManager), words[i], FAR_EXPIRY, DEFAULT_FEE_BPS);
      vm.prank(operator);
      vm.expectRevert(errors[i]);
      facility.setSecurityCap(address(underlyingToken), address(debtToken), words[i]);
      // Validation is unconditional: a disabled offer (expiry 0) is rejected too.
      vm.prank(facilitator);
      vm.expectRevert(errors[i]);
      facility.setEntry(address(positionManager), words[i], 0, 0, false);
    }

    // Valid EXTERNAL words on both whitelisted caps contracts are accepted everywhere, including
    // a multi-pool absolute word and dynamic ID 0 (FacilityDynamicCaps accepts any ID).
    _setEntry(positionManager, _absPoolsWord(_poolIds(POOL_ID, OTHER_POOL_ID, 0), MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, _dynWord(0, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, _dynWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(_dynWord(SECURITY_POOL_ID, MULT_1X));
    assertEq(facility.getEntry(address(positionManager)).capacityCap, _absWord(MULT_1X), "entry word");
    assertEq(facility.getExit(address(positionManager)).cap, _dynWord(POOL_ID, MULT_1X), "exit word");
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)),
      _dynWord(SECURITY_POOL_ID, MULT_1X),
      "security word"
    );
  }

  function test_setEntryAndSecurityCap_rejectNonConsumingWords() public {
    // A negative multiplier consumes nothing on the entry side.
    uint256 negWord = _dynWord(POOL_ID, MULT_NEG_1X);
    uint256 negAbsWord = _absWord(MULT_NEG_1X);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonConsumingCap.selector, negWord));
    facility.setEntry(address(positionManager), negWord, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonConsumingCap.selector, negAbsWord));
    facility.setEntry(address(positionManager), negAbsWord, FAR_EXPIRY, DEFAULT_FEE_BPS, false);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonConsumingCap.selector, negWord));
    facility.setSecurityCap(address(underlyingToken), address(debtToken), negWord);
    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonConsumingCap.selector, negAbsWord));
    facility.setSecurityCap(address(underlyingToken), address(debtToken), negAbsWord);

    // The exit side accepts any multiplier: negative is the netting case.
    _setExit(positionManager, negWord, FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.getExit(address(positionManager)).cap, negWord, "negative exit word rejected");
    _setExit(positionManager, negAbsWord, FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.getExit(address(positionManager)).cap, negAbsWord, "negative absolute exit word rejected");
  }

  function test_setOffersAndSecurityCap_rejectZeroMultiplier() public {
    // A zero multiplier caps nothing, so the caps contracts reject it on every word.
    uint256 zeroWord = _dynWord(POOL_ID, 0);
    uint256 zeroAbsWord = _absWord(0);

    vm.startPrank(facilitator);
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    facility.setEntry(address(positionManager), zeroWord, FAR_EXPIRY, DEFAULT_FEE_BPS, false);
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    facility.setExit(address(positionManager), zeroWord, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    facility.setExit(address(positionManager), zeroAbsWord, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.stopPrank();

    vm.prank(operator);
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    facility.setSecurityCap(address(underlyingToken), address(debtToken), zeroAbsWord);
  }

  function test_setEntry_rearmOverwritesRemainingCapacity() public {
    uint256 cap = 600e6;
    _setEntry(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _enter(user, 1_000e18, receiver);
    assertEq(facility.getEntry(address(positionManager)).capacityCap, cap - 500e6, "cap partially consumed");

    // Re-setting the offer re-arms the full ABSOLUTE capacity.
    _setEntry(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.getEntry(address(positionManager)).capacityCap, cap, "capacity re-armed");

    // Same for the exit side and the security cap.
    _setExit(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(cap);
    (uint256 shares,) = _enter(user, 1_000e18, user);
    (, uint256 debtIn) = _exit(user, shares, receiver);
    assertEq(facility.getExit(address(positionManager)).cap, cap - debtIn, "exit cap consumed");
    assertEq(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)), cap - 500e6, "security cap consumed"
    );
    _setExit(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(cap);
    assertEq(facility.getExit(address(positionManager)).cap, cap, "exit cap re-armed");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), cap, "security cap re-armed");
  }

  function test_setters_emitEvents() public {
    uint40 expiry = uint40(block.timestamp + 7 days);

    vm.prank(facilitator);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.EntrySet(address(positionManager), 123e6, expiry, 42, false);
    facility.setEntry(address(positionManager), 123e6, expiry, 42, false);

    vm.prank(facilitator);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.ExitSet(address(positionManager), 456e6, expiry, 43);
    facility.setExit(address(positionManager), 456e6, expiry, 43);

    vm.prank(operator);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.SecurityCapSet(address(underlyingToken), address(debtToken), 789e6);
    facility.setSecurityCap(address(underlyingToken), address(debtToken), 789e6);

    vm.prank(operator);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.AuthSet(address(underlyingToken), address(debtToken), user, 11e6, expiry);
    facility.setAuth(address(underlyingToken), address(debtToken), user, 11e6, expiry);

    address newRecipient = makeAddr("newRecipient");
    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.FeeRecipientSet(newRecipient);
    facility.setFeeRecipient(newRecipient);

    vm.prank(compliance);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.InKindFacilityPausedSet(uint40(block.timestamp + 3 days));
    facility.pauseFor(3 days);

    // A permanent pause saturates the timestamp.
    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.InKindFacilityPausedSet(type(uint40).max);
    facility.pauseFor(type(uint256).max);
  }

  function test_getters_and_config() public {
    // Unset state.
    EntryOffer memory unsetEntry = facility.getEntry(address(positionManager2));
    assertEq(unsetEntry.capacityCap, 0, "unset entry cap");
    assertEq(unsetEntry.expiry, 0, "unset entry expiry");
    assertEq(unsetEntry.feeBps, 0, "unset entry fee");
    ExitOffer memory unsetExit = facility.getExit(address(positionManager2));
    assertEq(unsetExit.cap, 0, "unset exit cap");
    assertEq(unsetExit.expiry, 0, "unset exit expiry");
    assertEq(unsetExit.feeBps, 0, "unset exit fee");
    assertEq(facility.getSecurityCap(address(debtToken), address(debtToken)), 0, "unset security cap");
    Auth memory unsetAuth = facility.getAuth(address(underlyingToken), address(debtToken), user);
    assertEq(unsetAuth.amount, 0, "unset auth amount");
    assertEq(unsetAuth.expiry, 0, "unset auth expiry");

    // Set state round-trips.
    uint40 expiry = uint40(block.timestamp + 7 days);
    _setEntry(positionManager2, 123e6, expiry, 42);
    _setExit(positionManager2, 456e6, expiry + 1, 43);
    _setAuth(user, 11e6, expiry + 2);
    vm.prank(operator);
    facility.setSecurityCap(address(debtToken), address(debtToken), 789e6);

    EntryOffer memory entry = facility.getEntry(address(positionManager2));
    assertEq(entry.capacityCap, 123e6, "entry cap stored");
    assertEq(entry.expiry, expiry, "entry expiry stored");
    assertEq(entry.feeBps, 42, "entry fee stored");
    ExitOffer memory exitOffer = facility.getExit(address(positionManager2));
    assertEq(exitOffer.cap, 456e6, "exit cap stored");
    assertEq(exitOffer.expiry, expiry + 1, "exit expiry stored");
    assertEq(exitOffer.feeBps, 43, "exit fee stored");
    assertEq(facility.getSecurityCap(address(debtToken), address(debtToken)), 789e6, "security cap stored");
    Auth memory auth = facility.getAuth(address(underlyingToken), address(debtToken), user);
    assertEq(auth.amount, 11e6, "auth amount stored");
    assertEq(auth.expiry, expiry + 2, "auth expiry stored");

    (address recipient, bool isPaused, uint40 pausedUntil) = facility.config();
    assertEq(recipient, feeRecipient, "config fee recipient");
    assertFalse(isPaused, "config not paused");
    assertEq(pausedUntil, 0, "config pausedUntil");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_previewEnter_valueParity() public {
    uint256 amount = 1_000e18;
    (uint256 previewDebt, uint256 previewShares, uint256 previewFee) =
      facility.previewEnter(address(positionManager), amount);

    uint256 supplyBefore = positionManager.totalSupply();
    (uint256 shares, uint256 debt) = _enter(user, amount, receiver);
    uint256 minted = positionManager.totalSupply() - supplyBefore;
    uint256 fee = positionManager.balanceOf(feeRecipient);

    assertEq(previewDebt, debt, "preview debt != executed debt");
    // The share figure is a best-effort estimate at the pre-flow share price.
    assertApproxEqRel(previewShares, shares, 1e15, "preview shares drifts more than 0.1%");
    assertApproxEqRel(previewFee, fee, 1e15, "preview fee drifts more than 0.1%");
    assertEq(previewFee, _feeOn(previewShares + previewFee), "preview fee != ceil share of the preview mint");
    assertEq(fee, _feeOn(minted), "executed fee != ceil share of the actual mint");
    assertGe(previewShares + previewFee, minted, "preview estimate must not undershoot the actual mint");
  }

  function test_previewEnter_gateParity() public {
    // Unknown offer.
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, address(positionManager2)));
    facility.previewEnter(address(positionManager2), 1_000e18);

    // Zero amount.
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.previewEnter(address(positionManager), 0);

    // Zero-debt rounding.
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, uint256(1e12)));
    facility.previewEnter(address(positionManager), 1e12);

    // Paused.
    vm.prank(compliance);
    facility.pauseFor(1 days);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.previewEnter(address(positionManager), 1_000e18);
    vm.prank(compliance);
    facility.pauseFor(0);

    // Bad debt.
    _triggerBadDebt();
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(positionManager)));
    facility.previewEnter(address(positionManager), 1_000e18);
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    // Expired offer.
    uint40 expiry = uint40(block.timestamp + 1 hours);
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, expiry, DEFAULT_FEE_BPS);
    vm.warp(expiry);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, address(positionManager)));
    facility.previewEnter(address(positionManager), 1_000e18);

    // Unlevered and empty pools.
    _setEntry(positionManager2, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.EmptyPool.selector, address(positionManager2)));
    facility.previewEnter(address(positionManager2), 1_000e18);
    _seedPool(positionManager2, SEED_COLLATERAL, 0);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnleveredEntryDisabled.selector, address(positionManager2)));
    facility.previewEnter(address(positionManager2), 1_000e18);
  }

  function test_previewEnter_ignoresCaps() public {
    // Previews do not read the caps: a closed capacity still quotes.
    _setEntry(positionManager, 0, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(0);
    (uint256 debt, uint256 shares,) = facility.previewEnter(address(positionManager), 1_000e18);
    assertEq(debt, 500e6, "preview debt under a closed cap");
    assertGt(shares, 0, "preview shares under a closed cap");
  }

  function test_previewExit_gateParity() public {
    // Unknown offer.
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, address(positionManager2)));
    facility.previewExit(address(positionManager2), 1e18);

    // Zero shares.
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.previewExit(address(positionManager), 0);

    // Paused.
    vm.prank(compliance);
    facility.pauseFor(1 days);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.previewExit(address(positionManager), 1e18);
    vm.prank(compliance);
    facility.pauseFor(0);

    // Bad debt.
    _triggerBadDebt();
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(positionManager)));
    facility.previewExit(address(positionManager), 1e18);
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    // Expired offer.
    uint40 expiry = uint40(block.timestamp + 1 hours);
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, expiry, DEFAULT_FEE_BPS);
    vm.warp(expiry);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, address(positionManager)));
    facility.previewExit(address(positionManager), 1e18);
  }

  function test_maxEnter_absoluteCapacityBelowSecurity() public {
    _setEntry(positionManager, 600e6, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(1_000e6);

    uint256 max = facility.maxEnter(address(positionManager), user);
    assertEq(max, uint256(600e6).mulDiv(positionManager.collateralAmount(), positionManager.debtAmount()), "max");
    assertEq(max, 1_200e18, "fixture max");

    // The bound fits...
    uint256 snap = vm.snapshotState();
    (uint256 shares, uint256 debt) = _enter(user, max, receiver);
    assertGt(shares, 0, "max entry failed");
    assertEq(debt, 600e6, "max entry did not fill the capacity");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, 0, "capacity not exhausted");
    vm.revertToState(snap);

    // ...and a chunk more does not.
    uint256 over = max + 1e18;
    bytes memory err = abi.encodeWithSelector(
      LibFacilityErrors.CapExceeded.selector, _pmId(positionManager), 600e6, _expectedDebt(over)
    );
    _fundEntrant(user, over);
    vm.prank(user);
    vm.expectRevert(err);
    facility.enter(address(positionManager), over, 0, type(uint256).max, 0, receiver);
  }

  function test_maxEnter_authPlusSecurityBelowCapacity() public {
    _setEntry(positionManager, 5_000e6, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(400e6);
    _setAuth(user, 300e6, FAR_EXPIRY);

    uint256 max = facility.maxEnter(address(positionManager), user);
    assertEq(max, uint256(700e6).mulDiv(positionManager.collateralAmount(), positionManager.debtAmount()), "max");
    assertEq(max, 1_400e18, "fixture max");
    // A user without auth only sees the security cap.
    assertEq(facility.maxEnter(address(positionManager), receiver), 800e18, "unauthed max");

    uint256 snap = vm.snapshotState();
    (, uint256 debt) = _enter(user, max, receiver);
    assertEq(debt, 700e6, "max entry did not fill auth + security");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "auth not drained");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 0, "security cap not drained");
    vm.revertToState(snap);
    assertEq(
      facility.getAuth(address(underlyingToken), address(debtToken), user).amount,
      300e6,
      "auth not restored by the snapshot revert"
    );
    assertEq(
      facility.getAuth(address(underlyingToken), address(debtToken), user).expiry,
      FAR_EXPIRY,
      "auth expiry not restored"
    );
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 400e6, "security cap not restored");

    uint256 over = max + 1e18;
    // Computed before the prank: an external call would consume it.
    bytes memory err =
      abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _assetId(), 400e6, _expectedDebt(over) - 300e6);
    _fundEntrant(user, over);
    vm.prank(user);
    vm.expectRevert(err);
    facility.enter(address(positionManager), over, 0, type(uint256).max, 0, receiver);
  }

  function test_maxEnter_expiredAuthIgnored() public {
    _setEntry(positionManager, 5_000e6, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(400e6);
    _setAuth(user, 300e6, uint40(block.timestamp + 1));
    assertEq(facility.maxEnter(address(positionManager), user), 1_400e18, "live auth counted");
    vm.warp(block.timestamp + 1);
    assertEq(facility.maxEnter(address(positionManager), user), 800e18, "expired auth counted");
  }

  function test_maxEnter_saturatesOnHugeAbsoluteWords() public {
    // MAX_ABSOLUTE is 2^248 - 1, not type(uint256).max: the debt bound is finite but the
    // conversion to underlying (x 2e12) overflows and saturates.
    uint256 max = facility.maxEnter(address(positionManager), user);
    assertGe(max, 1e40, "max not huge under MAX_ABSOLUTE words");
    assertEq(max, type(uint256).max, "conversion did not saturate");
  }

  function test_maxEnter_externalWordsQuoteThePools() public {
    _setAbsPool(600e6, 1_000e6);
    _setDynPoolFull(SECURITY_POOL_ID, 900e6);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(_dynWord(SECURITY_POOL_ID, MULT_1X));
    assertEq(facility.maxEnter(address(positionManager), user), 1_200e18, "absolute pool bound");

    // A 2x multiplier halves the depositable debt.
    _setEntry(positionManager, _absWord(2 * MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.maxEnter(address(positionManager), user), 600e18, "2x multiplier bound");

    // Then the dynamic security cap binds.
    _setAbsPool(1_000e6, 1_000e6);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.maxEnter(address(positionManager), user), 1_800e18, "dynamic security bound");
  }

  function test_maxEnter_multiPoolWordQuotesTheSum() public {
    _setAbsPool(300e6, 1_000e6);
    _setAbsPoolAt(OTHER_POOL_ID, 300e6, 1_000e6);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.maxEnter(address(positionManager), user), 600e18, "single pool bound");

    _setEntry(positionManager, _absPoolsWord(_poolIds(POOL_ID, OTHER_POOL_ID, 0), MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.maxEnter(address(positionManager), user), 1_200e18, "pools should add up");
  }

  function test_maxEnter_gateParity() public {
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownEntry.selector, address(positionManager2)));
    facility.maxEnter(address(positionManager2), user);

    vm.prank(compliance);
    facility.pauseFor(1 days);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.maxEnter(address(positionManager), user);
    vm.prank(compliance);
    facility.pauseFor(0);

    _setEntry(positionManager2, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.EmptyPool.selector, address(positionManager2)));
    facility.maxEnter(address(positionManager2), user);

    _triggerBadDebt();
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(positionManager)));
    facility.maxEnter(address(positionManager), user);
  }

  function test_maxExit_absoluteCap() public {
    (uint256 userShares,) = _enter(user, 1_000e18, user);
    uint256 cap = 100e6;
    _setExit(positionManager, cap, FAR_EXPIRY, DEFAULT_FEE_BPS);

    uint256 max = facility.maxExit(address(positionManager));
    assertGt(max, 0, "max exit zero");
    assertLt(max, userShares, "fixture: the cap must bind below the user's stake");

    // The bound fits...
    uint256 snap = vm.snapshotState();
    (, uint256 debtIn) = _exit(user, max, receiver);
    assertLe(debtIn, cap, "max exit overshot the cap");
    assertApproxEqRel(debtIn, cap, 1e12, "max exit did not fill the cap");
    vm.revertToState(snap);

    // ...and a chunk more does not.
    uint256 over = max + 1e18;
    (uint256 overDebtIn,,,) = facility.previewExit(address(positionManager), over);
    assertGt(overDebtIn, cap, "chunk too small to exceed the cap");
    _approveExit(user, over, _required(overDebtIn));
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, _pmId(positionManager), cap, overDebtIn)
    );
    facility.exit(address(positionManager), over, type(uint256).max, 0, receiver, "");
  }

  function test_maxExit_unbounded() public {
    // Huge ABSOLUTE word: the share conversion saturates.
    assertEq(facility.maxExit(address(positionManager)), type(uint256).max, "MAX_ABSOLUTE exit word");

    // Negative multiplier on a dynamic cap: the caps contract quotes unbounded.
    _setExit(positionManager, _dynWord(POOL_ID, MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertEq(facility.maxExit(address(positionManager)), type(uint256).max, "unbounded external exit word");

    // Zero-debt pool: nothing to cap.
    _setExit(positionManager, 100e6, FAR_EXPIRY, DEFAULT_FEE_BPS);
    assertLt(facility.maxExit(address(positionManager)), type(uint256).max, "bounded before unlevering");
    _unleverPool();
    assertEq(facility.maxExit(address(positionManager)), type(uint256).max, "unlevered pool");
  }

  function test_maxExit_gateParity() public {
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnknownExit.selector, address(positionManager2)));
    facility.maxExit(address(positionManager2));

    vm.prank(compliance);
    facility.pauseFor(1 days);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.maxExit(address(positionManager));
    vm.prank(compliance);
    facility.pauseFor(0);

    _triggerBadDebt();
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.BadDebtState.selector, address(positionManager)));
    facility.maxExit(address(positionManager));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        SLOT LAYOUT                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_slot_constantMatchesKeccak() public pure {
    assertEq(keccak256("facility.inkind.storage"), IN_KIND_STORAGE_SLOT, "storage slot constant");
  }

  function test_slot_feeRecipientAndPausedUntilPacked() public {
    address newRecipient = makeAddr("newRecipient");
    vm.prank(owner);
    facility.setFeeRecipient(newRecipient);
    vm.prank(compliance);
    facility.pauseFor(1 days);
    uint40 pausedUntil = uint40(block.timestamp + 1 days);

    // Slot +4: feeRecipient in the low 160 bits, pausedUntil in the next 40.
    uint256 word = uint256(vm.load(address(facility), bytes32(uint256(IN_KIND_STORAGE_SLOT) + 4)));
    assertEq(address(uint160(word)), newRecipient, "feeRecipient at bits 0..159");
    assertEq(uint40(word >> 160), pausedUntil, "pausedUntil at bits 160..199");
    assertEq(word >> 200, 0, "dirty high bits");

    // Slots +0..+3 hold mappings: their base slots stay empty.
    for (uint256 i = 0; i < 4; ++i) {
      assertEq(vm.load(address(facility), bytes32(uint256(IN_KIND_STORAGE_SLOT) + i)), bytes32(0), "mapping base slot");
    }
  }

  function test_slot_entryAndExitOfferLayout() public {
    uint40 expiry = uint40(block.timestamp + 7 days);
    _setEntry(positionManager, 123e6, expiry, 42, true);
    _setExit(positionManager, 456e6, expiry + 1, 43);

    // entries[pm] at keccak256(pm . slot+0): capacityCap (word 0), then
    // expiry | feeBps << 40 | allowUnlevered << 64 (word 1).
    bytes32 entryBase = keccak256(abi.encode(address(positionManager), uint256(IN_KIND_STORAGE_SLOT)));
    assertEq(uint256(vm.load(address(facility), entryBase)), 123e6, "entry capacityCap");
    uint256 entryWord1 = uint256(vm.load(address(facility), bytes32(uint256(entryBase) + 1)));
    assertEq(uint40(entryWord1), expiry, "entry expiry at bits 0..39");
    assertEq(uint24(entryWord1 >> 40), 42, "entry feeBps at bits 40..63");
    assertEq(uint8(entryWord1 >> 64), 1, "entry allowUnlevered at bit 64");
    assertEq(entryWord1 >> 72, 0, "entry dirty high bits");

    // exits[pm] at keccak256(pm . slot+1), same layout.
    bytes32 exitBase = keccak256(abi.encode(address(positionManager), uint256(IN_KIND_STORAGE_SLOT) + 1));
    assertEq(uint256(vm.load(address(facility), exitBase)), 456e6, "exit cap");
    uint256 exitWord1 = uint256(vm.load(address(facility), bytes32(uint256(exitBase) + 1)));
    assertEq(uint40(exitWord1), expiry + 1, "exit expiry at bits 0..39");
    assertEq(uint24(exitWord1 >> 40), 43, "exit feeBps at bits 40..63");
  }

  function test_slot_securityCapAndAuthLayout() public {
    uint40 expiry = uint40(block.timestamp + 7 days);
    _setSecurityCap(789e6);
    _setAuth(user, 11e6, expiry);

    // securityCaps[asset][debtAsset] at keccak256(debtAsset . keccak256(asset . slot+2)).
    bytes32 securityInner = keccak256(abi.encode(address(underlyingToken), uint256(IN_KIND_STORAGE_SLOT) + 2));
    bytes32 securitySlot = keccak256(abi.encode(address(debtToken), securityInner));
    assertEq(uint256(vm.load(address(facility), securitySlot)), 789e6, "security cap word");

    // auths[asset][debtAsset][user] at keccak256(user . keccak256(debtAsset . keccak256(asset .
    // slot+3))): amount | expiry << 128.
    bytes32 authOuter = keccak256(abi.encode(address(underlyingToken), uint256(IN_KIND_STORAGE_SLOT) + 3));
    bytes32 authInner = keccak256(abi.encode(address(debtToken), authOuter));
    bytes32 authSlot = keccak256(abi.encode(user, authInner));
    uint256 authWord = uint256(vm.load(address(facility), authSlot));
    assertEq(uint128(authWord), 11e6, "auth amount at bits 0..127");
    assertEq(uint40(authWord >> 128), expiry, "auth expiry at bits 128..167");
    assertEq(authWord >> 168, 0, "auth dirty high bits");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            E2E                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_e2e_enterAccrueExitMultiUser() public {
    address user2 = makeAddr("user2");

    // 1. Entry: receiver takes the net shares and the full debt.
    (uint256 shares, uint256 debt) = _enter(user, 2_000e18, receiver);
    assertEq(positionManager.balanceOf(receiver), shares, "receiver shares after entry");
    assertEq(debtToken.balanceOf(receiver), debt, "receiver debt after entry");
    _assertFacilityClean();
    _assertNoAllowances();

    // 2a. Interest accrues: the exit's debt quote drifts up with the pool's debt.
    (uint256 debtInBefore, uint256 outBefore,,) = facility.previewExit(address(positionManager), shares / 2);
    vm.warp(block.timestamp + 60 days);
    morpho.accrueInterest(marketParams);
    {
      (uint256 debtInDrifted, uint256 outDrifted,,) = facility.previewExit(address(positionManager), shares / 2);
      assertGt(debtInDrifted, debtInBefore, "interest did not drift the exit quote");
      assertEq(outDrifted, outBefore, "interest moved the collateral slice");
    }

    // 2b. PM fees accrue (time plus an up-print): pending fee shares dilute every holder.
    _setPmFees(200, 2000);
    vm.warp(block.timestamp + 30 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);
    {
      (,, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
      assertGt(mgmtShares, 0, "no pending management fee shares");
      assertGt(perfShares, 0, "no pending performance fee shares");
    }
    (uint256 debtInAfter, uint256 outAfter,,) = facility.previewExit(address(positionManager), shares / 2);
    assertLt(outAfter, outBefore, "PM fees did not dilute the exit quote");

    // 3. Partial exit by the receiver: half the shares against the fresh quote.
    {
      uint256 underlyingBefore = underlyingToken.balanceOf(receiver);
      (uint256 out, uint256 debtIn) = _exit(receiver, shares / 2, receiver);
      assertEq(debtIn, debtInAfter, "executed debtIn matches the fresh preview");
      assertEq(out, outAfter, "executed out matches the fresh preview");
      assertEq(underlyingToken.balanceOf(receiver) - underlyingBefore, out, "receiver underlying after exit");
      assertEq(positionManager.balanceOf(receiver), shares - shares / 2, "remaining shares");
      _assertFacilityClean();
      _assertNoAllowances();
    }

    // 4. A second user enters at the drifted ratio: prices exactly on the live D / C.
    uint256 amount2 = 500e18;
    uint256 shares2;
    {
      uint256 expectedDebt2 = _expectedDebt(amount2);
      uint256 debt2;
      (shares2, debt2) = _enter(user2, amount2, user2);
      assertEq(debt2, expectedDebt2, "second entry not ratio-priced");
      assertGt(shares2, 0, "second entry shares");
      _assertFacilityClean();
      _assertNoAllowances();
    }

    // 5. Full exits: both users leave, the seeder's stake is intact and the facility is clean.
    (uint256 out2,) = _exit(receiver, positionManager.balanceOf(receiver), receiver);
    assertGt(out2, 0, "receiver final exit");
    assertEq(positionManager.balanceOf(receiver), 0, "receiver shares left");
    _assertFacilityClean();
    _assertNoAllowances();
    (uint256 out3,) = _exit(user2, shares2, user2);
    assertGt(out3, 0, "user2 final exit");
    assertEq(positionManager.balanceOf(user2), 0, "user2 shares left");
    _assertFacilityClean();
    _assertNoAllowances();

    // Round trips are lossy for the entrants (fees plus rounding): user2 got back less than it put in.
    assertLt(out3, amount2, "round trip not lossy");
    assertGt(positionManager.balanceOf(feeRecipient), 0, "fee recipient holds no shares");
    assertGt(positionManager.balanceOf(pmFeeRecipient), 0, "PM fee recipient holds no shares");
    assertGt(positionManager.balanceOf(seeder), 0, "seeder stake gone");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            FUZZ                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_enter_ratioDerivedDebt(uint256 amount) public {
    amount = bound(amount, 1e13, 5_000e18);
    uint256 expectedDebt = _expectedDebt(amount);
    vm.assume(expectedDebt > 0);

    uint256 supplyBefore = positionManager.totalSupply();
    (uint256 shares, uint256 debt) = _enter(user, amount, receiver);
    uint256 minted = positionManager.totalSupply() - supplyBefore;
    uint256 fee = positionManager.balanceOf(feeRecipient);

    assertEq(debt, expectedDebt, "debt != amount * D / C");
    assertEq(debtToken.balanceOf(receiver), debt, "receiver got the full debt");
    assertEq(fee, _feeOn(minted), "fee != mulDivUp share of the mint");
    assertEq(shares + fee, minted, "net + fee != minted");
    assertGt(shares, 0, "no shares minted");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function testFuzz_exit_matchesPreviewMirror(uint256 shareFraction, uint256 elapsed) public {
    _setPmFees(200, 2000);
    (uint256 shares,) = _enter(user, 1_000e18, user);

    elapsed = bound(elapsed, 0, 365 days);
    vm.warp(block.timestamp + elapsed);
    // At least two shares so the rounded-up fee leaves something to burn.
    uint256 exitShares = bound(shareFraction, 2, shares);

    // The facility's mirror math must equal burn's pulled amounts to the wei.
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee,) =
      facility.previewExit(address(positionManager), exitShares);
    uint256 feeSharesBefore = positionManager.balanceOf(feeRecipient);
    (uint256 out, uint256 debtIn) = _exit(user, exitShares, receiver);

    assertEq(out, previewOut, "underlying out != preview");
    assertEq(debtIn, previewDebtIn, "debtIn != preview");
    assertEq(positionManager.balanceOf(feeRecipient) - feeSharesBefore, previewFee, "fee shares != preview");
    assertEq(positionManager.balanceOf(user), shares - exitShares, "shares pulled != exitShares");
    _assertFacilityClean();
    _assertNoAllowances();
  }
}

/// @dev Minimal contract exposing only assets(): used to probe the PM surface validation.
contract PmSurfaceStub {
  address internal immutable COLLATERAL;

  constructor(address collateral) {
    COLLATERAL = collateral;
  }

  function assets() external view returns (address collateralAsset, address debtAsset) {
    return (COLLATERAL, address(0));
  }
}

/// @dev Wrapper stub whose underlying() resolves to the zero address.
contract ZeroUnderlyingWrapper {
  function underlying() external pure returns (address) {
    return address(0);
  }
}

/// @dev Exit caller implementing the callback: records the call and approves exactly the debt
///      it is told, so the facility's pull is sourced inside the callback frame.
contract ExitCallbackStub is IInKindExitCallback {
  address internal immutable FACILITY;
  address internal immutable DEBT;

  uint256 public calls;
  address public lastPositionManager;
  uint256 public lastShares;
  uint256 public lastDebtIn;
  bytes public lastData;

  constructor(address facility_, address debt_) {
    FACILITY = facility_;
    DEBT = debt_;
  }

  function onInKindExit(address positionManager, uint256 shares, uint256 debtIn, bytes calldata data) external {
    require(msg.sender == FACILITY, "not facility");
    calls++;
    lastPositionManager = positionManager;
    lastShares = shares;
    lastDebtIn = debtIn;
    lastData = data;
    ERC20(DEBT).approve(FACILITY, debtIn);
  }

  function approveDebt(uint256 amount) external {
    ERC20(DEBT).approve(FACILITY, amount);
  }

  function doExit(address positionManager, uint256 shares, bytes calldata data)
    external
    returns (uint256 out, uint256 debtIn)
  {
    ERC20(positionManager).approve(FACILITY, shares);
    return IInKindFacility(FACILITY).exit(positionManager, shares, type(uint256).max, 0, address(this), data);
  }
}
