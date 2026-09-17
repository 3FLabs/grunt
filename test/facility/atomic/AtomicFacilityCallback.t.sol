// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {AtomicFacilityBaseTest} from "./AtomicFacilityBase.t.sol";
import {IAtomicFacility} from "src/interfaces/facility/IAtomicFacility.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {BPS} from "src/libs/Constants.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {
  BaseExiter,
  ApproveExactExiter,
  ViewReaderExiter,
  RepayOnBehalfExiter,
  SupplyCollateralExiter,
  AccrueInterestExiter,
  FlashWrappedExiter,
  FlashInCallbackExiter,
  ReenterExiter,
  DirectTransferExiter,
  NoopExiter,
  FacilitatorExiter
} from "test/mock/facility/AtomicExiters.sol";

/// @title AtomicFacilityCallbackTest
/// @notice Tests for the `exit` callback lane (`IAtomicExitCallback`): exact sourcing of
///         `debtIn`, read-consistency inside the callback, the debt mirror check against
///         callback-driven module state changes, flash-loan patterns, reentrancy, settlement
///         being pull-only, and the share fee / exit cap being settled around the callback.
contract AtomicFacilityCallbackTest is AtomicFacilityBaseTest {
  using FixedPointMathLib for uint256;

  uint256 constant ENTER_AMOUNT = 1_000e18;
  uint256 constant FINITE_EXIT_CAP = 1_000_000e6;

  function setUp() public override {
    super.setUp();
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Gives `exiter` PM shares by entering through the facility with it as receiver. The
  ///      guard is in BLOCKLIST mode so the unlisted contract passes. The entry also forwards
  ///      the borrowed debt to the receiver; it is zeroed so every test funds the exiter's debt
  ///      balance explicitly.
  function _sharesFor(address exiter) internal returns (uint256 shares) {
    (shares,) = _enter(user, ENTER_AMOUNT, exiter);
    assertEq(positionManager.balanceOf(exiter), shares, "exiter shares");
    debtToken.setBalance(exiter, 0);
  }

  /// @dev Pre-funds `who` with `amount` of the debt asset.
  function _fundDebt(address who, uint256 amount) internal {
    debtToken.setBalance(who, debtToken.balanceOf(who) + amount);
  }

  /// @dev Unlevers the pool by repaying the borrow module's whole Morpho debt from the test.
  function _unleverPool() internal {
    uint256 borrowShares = morpho.position(marketId, address(borrowPosition)).borrowShares;
    debtToken.setBalance(address(this), debtToken.balanceOf(address(this)) + 100_000_000e6);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.repay(marketParams, 0, borrowShares, address(borrowPosition), "");
    assertEq(positionManager.debtAmount(), 0, "pool not unlevered");
  }

  /// @dev Fee shares of an exit of `shares` at `feeBps` (rounded up for the recipient).
  function _feeShares(uint256 shares, uint256 feeBps) internal pure returns (uint256) {
    return shares.mulDivUp(feeBps, BPS);
  }

  function _newApproveExact() internal returns (ApproveExactExiter r) {
    r = new ApproveExactExiter(facility, positionManager, debtToken);
    vm.label(address(r), "ApproveExactExiter");
  }

  function _newViewReader() internal returns (ViewReaderExiter r) {
    r = new ViewReaderExiter(facility, positionManager, debtToken);
    vm.label(address(r), "ViewReaderExiter");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    1. EXACT SOURCING                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_approveExact_happyPath() public {
    ApproveExactExiter r = _newApproveExact();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee) =
      facility.previewExit(address(positionManager), shares);
    assertEq(previewFee, _feeShares(shares, DEFAULT_FEE_BPS), "preview fee shares");
    _fundDebt(address(r), previewDebtIn);
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);

    (uint256 out, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    assertEq(r.callCount(), 1, "callback count");
    assertEq(r.lastPm(), address(positionManager), "callback pm");
    assertEq(r.lastShares(), shares, "callback shares");
    assertEq(r.lastDebtIn(), debtIn, "callback debtIn equals returned debtIn");
    assertEq(r.lastData(), bytes("x"), "callback data");
    assertEq(debtIn, previewDebtIn, "debtIn equals preview in the same block");
    assertEq(out, previewOut, "out equals preview");
    assertEq(debtToken.allowance(address(r), address(facility)), 0, "exact allowance fully consumed");
    assertEq(debtToken.balanceOf(address(r)), 0, "exiter debt balance fully spent");
    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    assertEq(positionManager.balanceOf(feeRecipient) - feeBefore, previewFee, "fee shares at recipient");
    assertEq(positionManager.balanceOf(address(r)), 0, "shares burned");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 2. STALE PREVIEW + ACCRUAL                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_exactSourcingAcrossInterestAccrual() public {
    ApproveExactExiter r = _newApproveExact();
    uint256 shares = _sharesFor(address(r));
    (uint256 stalePreview,,) = facility.previewExit(address(positionManager), shares);

    // Interest accrues on the Morpho market: the live figure drifts above the stale preview.
    vm.warp(block.timestamp + 200 days);
    (uint256 livePreview,,) = facility.previewExit(address(positionManager), shares);
    assertGt(livePreview, stalePreview, "interest must have accrued");

    // Fund the live figure only: the callback approves exactly what the facility pulls, so no
    // headroom over the stale preview is needed.
    _fundDebt(address(r), livePreview);
    (, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    assertEq(r.callCount(), 1, "callback count");
    assertGe(r.lastDebtIn(), stalePreview, "callback debtIn >= stale preview");
    assertEq(r.lastDebtIn(), livePreview, "callback debtIn == live preview");
    assertEq(debtIn, livePreview, "returned debtIn");
    assertEq(debtToken.balanceOf(address(r)), 0, "exactly the live figure was pulled");
    assertEq(debtToken.allowance(address(r), address(facility)), 0, "no leftover allowance");
    _assertFacilityClean();
  }

  function test_callback_exactSourcingAcrossInterestAccrual_withPmFees() public {
    _setPmFees(100, 1000);
    ApproveExactExiter r = _newApproveExact();
    uint256 shares = _sharesFor(address(r));
    (uint256 stalePreview,,) = facility.previewExit(address(positionManager), shares);

    // Time accrues Morpho interest and PM management fee shares; the up-print accrues
    // performance fee shares. The pending fee shares dilute the exiter's slice, so the live
    // figure is not monotone in time here; the callback still receives the exact final figure.
    vm.warp(block.timestamp + 200 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 110 / 100);
    (,, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    assertGt(mgmtShares, 0, "no pending management fee shares");
    assertGt(perfShares, 0, "no pending performance fee shares");
    (uint256 livePreview,, uint256 liveFee) = facility.previewExit(address(positionManager), shares);

    _fundDebt(address(r), livePreview);
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);
    (, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    assertEq(r.callCount(), 1, "callback count");
    assertTrue(r.lastDebtIn() != stalePreview, "fee accrual must have moved the figure");
    assertEq(r.lastDebtIn(), livePreview, "callback debtIn == live preview across fee accrual");
    assertEq(debtIn, livePreview, "returned debtIn");
    assertEq(positionManager.balanceOf(feeRecipient) - feeBefore, liveFee, "fee shares at recipient");
    assertEq(debtToken.balanceOf(address(r)), 0, "exactly the live figure was pulled");
    _assertFacilityClean();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 3. VIEW CONSISTENCY INSIDE                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_pmViewsMatchPreCallState() public {
    _setPmFees(100, 1000);
    ViewReaderExiter r = _newViewReader();
    uint256 shares = _sharesFor(address(r));
    vm.warp(block.timestamp + 30 days);
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 105 / 100);

    // Pre-call values of every view the callback snapshots.
    uint256 totalAssetsBefore = positionManager.totalAssets();
    uint256 totalSupplyBefore = positionManager.totalSupply();
    (uint256 pfTA, uint256 pfTS, uint256 pfMgmt, uint256 pfPerf) = positionManager.pendingFees();
    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 debtBefore = positionManager.debtAmount();
    bool badDebtBefore = positionManager.hasBadDebt();
    uint256 selfBefore = positionManager.balanceOf(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);

    r.exit(shares, type(uint256).max, 0, receiver, "x");

    ViewReaderExiter.Snapshot memory s = r.snapshot();
    assertEq(r.callCount(), 1, "callback count");
    assertEq(s.totalAssets, totalAssetsBefore, "totalAssets");
    assertEq(s.totalSupply, totalSupplyBefore, "totalSupply");
    assertEq(s.pfTotalAssets, pfTA, "pendingFees.totalAssets");
    assertEq(s.pfTotalSupply, pfTS, "pendingFees.totalSupply");
    assertEq(s.pfMgmtShares, pfMgmt, "pendingFees.mgmtShares");
    assertEq(s.pfPerfShares, pfPerf, "pendingFees.perfShares");
    assertEq(s.collateralAmount, collateralBefore, "collateralAmount");
    assertEq(s.debtAmount, debtBefore, "debtAmount");
    assertEq(s.hasBadDebt, badDebtBefore, "hasBadDebt");
    assertEq(s.facilityBalance, shares, "facility holds the pulled shares during the callback");
    assertEq(s.selfBalance, selfBefore - shares, "exiter balance decreased by shares");
    _assertFacilityClean();
  }

  function test_callback_feeSharesStayWithFacilityUntilAfterBurn() public {
    ViewReaderExiter r = _newViewReader();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn,, uint256 previewFee) = facility.previewExit(address(positionManager), shares);
    assertGt(previewFee, 0, "sanity: fee charged");
    _fundDebt(address(r), previewDebtIn);
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);

    r.exit(shares, type(uint256).max, 0, receiver, "x");

    // During the callback the facility holds every pulled share (fee included); the fee shares
    // reach the recipient only after burn, so a callback revert leaves the recipient untouched.
    ViewReaderExiter.Snapshot memory s = r.snapshot();
    assertEq(s.facilityBalance, shares, "facility holds shares plus fee shares during the callback");
    assertEq(s.feeRecipientBalance, feeBefore, "fee recipient not paid during the callback");
    assertEq(positionManager.balanceOf(feeRecipient) - feeBefore, previewFee, "fee shares forwarded after burn");
    assertEq(positionManager.balanceOf(address(facility)), 0, "facility holds no shares after the exit");
  }

  function test_callback_exitCapConsumedBeforeCallback() public {
    _setExit(positionManager, FINITE_EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    ViewReaderExiter r = _newViewReader();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    assertGt(previewDebtIn, 0, "sanity: levered pool");
    _fundDebt(address(r), previewDebtIn);
    assertEq(facility.getExit(address(positionManager)).cap, FINITE_EXIT_CAP, "cap before");

    (, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    // The ABSOLUTE word is decremented by the gross debt before the callback runs (CEI).
    assertEq(r.snapshot().exitCap, FINITE_EXIT_CAP - debtIn, "exit cap consumed inside the callback");
    assertEq(facility.getExit(address(positionManager)).cap, FINITE_EXIT_CAP - debtIn, "exit cap after");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 4. MODULE STATE CHANGES                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _newRepayOnBehalf() internal returns (RepayOnBehalfExiter r) {
    r = new RepayOnBehalfExiter(facility, positionManager, debtToken, morpho, marketParams, address(borrowPosition));
    vm.label(address(r), "RepayOnBehalfExiter");
  }

  function test_callback_repayOnBehalfRevertsDebtMirrorMismatch() public {
    RepayOnBehalfExiter r = _newRepayOnBehalf();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    uint256 repayAssets = 1_000e6;
    _fundDebt(address(r), previewDebtIn + repayAssets);

    // The repay lowers the PM's debt below the mirror figure: burn pulls less than expected.
    vm.expectPartialRevert(IAtomicFacility.DebtMirrorMismatch.selector);
    r.exit(shares, type(uint256).max, 0, receiver, abi.encode(repayAssets));
  }

  function test_callback_repayOnBehalf_exactMismatchValues() public {
    RepayOnBehalfExiter r = _newRepayOnBehalf();
    uint256 shares = _sharesFor(address(r));
    (uint256 expected,, uint256 previewFee) = facility.previewExit(address(positionManager), shares);
    uint256 burnShares = shares - previewFee;
    uint256 repayAssets = 1_000e6;
    _fundDebt(address(r), expected + repayAssets);

    // Replay the repay on a snapshot to learn burn's post-repay figure, then revert it.
    uint256 snap = vm.snapshotState();
    _fundDebt(address(this), repayAssets);
    debtToken.approve(address(morpho), repayAssets);
    morpho.repay(marketParams, repayAssets, 0, address(borrowPosition), "");
    (, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    uint256 pulled = positionManager.debtAmount()
      .mulDivUp(burnShares, totalSupply_ + mgmtShares + perfShares + positionManager.virtualShareOffset());
    vm.revertToState(snap);
    assertLt(pulled, expected, "repay must move burn's figure below the mirror");

    vm.expectRevert(abi.encodeWithSelector(IAtomicFacility.DebtMirrorMismatch.selector, expected, pulled));
    r.exit(shares, type(uint256).max, 0, receiver, abi.encode(repayAssets));
  }

  function _newSupplyCollateral() internal returns (SupplyCollateralExiter r) {
    r = new SupplyCollateralExiter(
      facility,
      positionManager,
      debtToken,
      morpho,
      marketParams,
      address(borrowPosition),
      underlyingToken,
      collateralToken
    );
    vm.label(address(r), "SupplyCollateralExiter");
    // The wrapper requires SENDER_ROLE on the `from` side of a transfer (exiter -> Morpho).
    vm.prank(owner);
    collateralToken.grantRoles(address(r), WA_SENDER_ROLE);
  }

  function test_callback_supplyCollateralWithPerfFeeRevertsDebtMirrorMismatch() public {
    _setPmFees(0, 1000);
    SupplyCollateralExiter r = _newSupplyCollateral();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    uint256 donation = 500e18;
    _fundDebt(address(r), previewDebtIn);
    underlyingToken.setBalance(address(r), donation);

    // The donation lifts totalAssets above the performance reference: burn accrues extra fee
    // shares first, so its denominator (and debt slice) diverges from the mirror.
    vm.expectPartialRevert(IAtomicFacility.DebtMirrorMismatch.selector);
    r.exit(shares, type(uint256).max, 0, receiver, abi.encode(donation));
  }

  function test_callback_supplyCollateralWithoutPmFeesSucceeds() public {
    SupplyCollateralExiter r = _newSupplyCollateral();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn, uint256 previewOut,) = facility.previewExit(address(positionManager), shares);
    uint256 donation = 500e18;
    _fundDebt(address(r), previewDebtIn);
    underlyingToken.setBalance(address(r), donation);

    (uint256 out, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, abi.encode(donation));

    // The debt slice is untouched by a collateral donation (debt and supply unchanged); the
    // exiter only recovers its proportional slice of the donation, strictly less than it.
    assertEq(r.callCount(), 1, "callback count");
    assertEq(debtIn, previewDebtIn, "debtIn unchanged by the donation");
    assertGt(out, previewOut, "donation raised the underlying out");
    assertLt(out - previewOut, donation, "extra underlying strictly below the donation");
    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    _assertFacilityClean();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 5. ACCRUE INTEREST INSIDE                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_accrueInterestInsideMatchesMirror() public {
    AccrueInterestExiter r =
      new AccrueInterestExiter(facility, positionManager, debtToken, morpho, marketParams, address(borrowPosition));
    uint256 shares = _sharesFor(address(r));

    // Pending (unmaterialized) interest: the mirror prices it through the module's expected
    // borrow assets; materializing it inside the callback changes nothing burn reads.
    vm.warp(block.timestamp + 200 days);
    assertLt(morpho.market(marketId).lastUpdate, block.timestamp, "interest must be pending");
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee) =
      facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);

    (uint256 out, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    assertEq(r.callCount(), 1, "callback count");
    assertEq(morpho.market(marketId).lastUpdate, block.timestamp, "interest materialized by the callback");
    assertEq(debtIn, previewDebtIn, "debtIn matches the pre-accrual preview");
    assertEq(r.lastDebtIn(), debtIn, "callback debtIn");
    assertEq(out, previewOut, "underlying out matches preview");
    assertEq(debtToken.balanceOf(address(r)), 0, "exact pull");
    assertGt(previewFee, 0, "sanity: fee charged");
    _assertFacilityClean();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    6. FLASH LOAN PATTERNS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_flashLoanWrappingExitSucceeds() public {
    FlashWrappedExiter r =
      new FlashWrappedExiter(facility, positionManager, debtToken, morpho, marketParams, address(borrowPosition));
    uint256 shares = _sharesFor(address(r));
    vm.warp(block.timestamp + 30 days);
    (uint256 previewDebtIn, uint256 previewOut,) = facility.previewExit(address(positionManager), shares);
    uint256 headroom = previewDebtIn / 10 + 1;
    uint256 loan = previewDebtIn + headroom;
    // The loan covers the pull; own funds cover the repayment of the spent part.
    _fundDebt(address(r), previewDebtIn);
    uint256 morphoBefore = debtToken.balanceOf(address(morpho));

    r.flashExit(shares, loan, receiver);

    assertEq(r.callCount(), 1, "callback count");
    assertEq(r.flashAssets(), loan, "flash amount");
    assertEq(r.flashExitDebtIn(), previewDebtIn, "debtIn inside the flash frame");
    assertEq(r.lastDebtIn(), previewDebtIn, "callback debtIn");
    assertEq(r.flashExitOut(), previewOut, "underlying out");
    assertEq(underlyingToken.balanceOf(receiver), previewOut, "receiver underlying");
    // Morpho holds the flash principal back plus the whole debt slice burn repaid on the market
    // (no debt-side fee: the fee is taken in shares).
    assertEq(debtToken.balanceOf(address(morpho)), morphoBefore + previewDebtIn, "flash loan fully repaid");
    assertEq(debtToken.balanceOf(address(r)), 0, "own funds covered exactly the pull");
    assertEq(debtToken.allowance(address(r), address(facility)), 0, "no leftover facility allowance");
    _assertFacilityClean();
  }

  function test_callback_flashLoanInsideCallbackRepaidFromOwnBalance() public {
    FlashInCallbackExiter r =
      new FlashInCallbackExiter(facility, positionManager, debtToken, morpho, marketParams, address(borrowPosition));
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn, uint256 previewOut,) = facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);
    uint256 morphoBefore = debtToken.balanceOf(address(morpho));

    (uint256 out, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    // The loan is in and out within the callback frame; the proceeds land only afterwards, so
    // the underlying at the receiver could not have contributed to the flash repayment.
    assertEq(r.callCount(), 1, "callback count");
    assertEq(r.flashAssets(), previewDebtIn, "flash amount");
    assertEq(r.balanceInsideFlash(), 2 * previewDebtIn, "own funds + loan inside the flash frame");
    assertEq(debtIn, previewDebtIn, "debtIn");
    assertEq(out, previewOut, "underlying out");
    assertEq(underlyingToken.balanceOf(receiver), previewOut, "proceeds delivered after the callback");
    assertEq(debtToken.balanceOf(address(morpho)), morphoBefore + previewDebtIn, "flash loan fully repaid");
    assertEq(debtToken.balanceOf(address(r)), 0, "pull funded from the pre-funded balance");
    _assertFacilityClean();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       7. REENTRANCY                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _newReenter() internal returns (ReenterExiter r, uint256 shares) {
    r = new ReenterExiter(facility, positionManager, debtToken);
    vm.label(address(r), "ReenterExiter");
    shares = _sharesFor(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);
  }

  function test_callback_reenterExitReverts() public {
    (ReenterExiter r, uint256 shares) = _newReenter();
    vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
    r.exit(shares, type(uint256).max, 0, receiver, abi.encode(uint8(0)));
    assertEq(positionManager.balanceOf(address(r)), shares, "shares returned on revert");
  }

  function test_callback_reenterEnterReverts() public {
    (ReenterExiter r, uint256 shares) = _newReenter();
    vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
    r.exit(shares, type(uint256).max, 0, receiver, abi.encode(uint8(1)));
    assertEq(positionManager.balanceOf(address(r)), shares, "shares returned on revert");
  }

  function test_callback_previewExitFromCallbackSucceeds() public {
    (ReenterExiter r, uint256 shares) = _newReenter();
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);

    (, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, abi.encode(uint8(2)));

    assertEq(r.callCount(), 1, "callback count");
    assertEq(r.previewDebtInFromCallback(), previewDebtIn, "preview readable from the callback");
    assertEq(debtIn, previewDebtIn, "debtIn");
    _assertFacilityClean();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   8. PULL-ONLY SETTLEMENT                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_directTransferInsteadOfApproveReverts() public {
    DirectTransferExiter r = new DirectTransferExiter(facility, positionManager, debtToken);
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);

    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    r.exit(shares, type(uint256).max, 0, receiver, "x");

    // The whole call reverted: the pushed funds are back with the exiter, shares too.
    assertEq(debtToken.balanceOf(address(r)), previewDebtIn, "push reverted with the call");
    assertEq(positionManager.balanceOf(address(r)), shares, "shares returned on revert");
    _assertFacilityClean();
  }

  function test_callback_noopReverts() public {
    NoopExiter r = new NoopExiter(facility, positionManager, debtToken);
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);

    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    r.exit(shares, type(uint256).max, 0, receiver, "x");
    assertEq(r.callCount(), 0, "state rolled back with the revert");
    assertEq(positionManager.balanceOf(address(r)), shares, "shares returned on revert");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    9. DATA GATING                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_eoaWithDataReverts() public {
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    _fundDebt(user, previewDebtIn);
    vm.startPrank(user);
    debtToken.approve(address(facility), previewDebtIn);
    positionManager.approve(address(facility), shares);
    // No code at msg.sender: the callback call fails before any settlement.
    vm.expectRevert();
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "x");
    vm.stopPrank();
    assertEq(positionManager.balanceOf(user), shares, "shares untouched");
  }

  function test_callback_contractWithEmptyDataSkipsCallback() public {
    ApproveExactExiter r = _newApproveExact();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee) =
      facility.previewExit(address(positionManager), shares);
    // The no-callback path needs the allowance upfront, as the EOA path does.
    _fundDebt(address(r), previewDebtIn);
    r.approveDebt(previewDebtIn);
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);

    (uint256 out, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "");

    assertEq(r.callCount(), 0, "callback must not run on empty data");
    assertEq(out, previewOut, "out equals preview");
    assertEq(debtIn, previewDebtIn, "debtIn equals preview");
    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    assertEq(positionManager.balanceOf(feeRecipient) - feeBefore, previewFee, "fee shares at recipient");
    assertEq(debtToken.balanceOf(address(r)), 0, "exact pull");
    _assertFacilityClean();
  }

  function test_callback_emptyDataPathEqualsEoaPath() public {
    // Same shares, same block: the contract-without-data path and the EOA `_exit` path must
    // settle identical amounts.
    ApproveExactExiter r = _newApproveExact();
    uint256 sharesA = _sharesFor(address(r));
    (uint256 sharesB,) = _enter(user, ENTER_AMOUNT, user);
    assertEq(sharesA, sharesB, "same-block entries mint the same shares");

    uint256 snap = vm.snapshotState();
    (uint256 outEoa, uint256 debtInEoa) = _exit(user, sharesB, receiver);
    vm.revertToState(snap);

    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), sharesA);
    _fundDebt(address(r), previewDebtIn);
    r.approveDebt(previewDebtIn);
    (uint256 outContract, uint256 debtInContract) = r.exit(sharesA, type(uint256).max, 0, receiver, "");

    assertEq(r.callCount(), 0, "no callback");
    assertEq(outContract, outEoa, "underlying out equals the EOA path");
    assertEq(debtInContract, debtInEoa, "debtIn equals the EOA path");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   10. MAX DEBT IN BOUND                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_maxDebtInTooLowRevertsBeforeCallback() public {
    _setExit(positionManager, FINITE_EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    ApproveExactExiter r = _newApproveExact();
    uint256 shares = _sharesFor(address(r));
    (uint256 previewDebtIn,,) = facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);

    vm.expectRevert(abi.encodeWithSelector(IAtomicFacility.ExcessiveDebtIn.selector, previewDebtIn, previewDebtIn - 1));
    r.exit(shares, previewDebtIn - 1, 0, receiver, "x");

    assertEq(r.callCount(), 0, "callback must not run when the bound fails");
    assertEq(positionManager.balanceOf(address(r)), shares, "shares untouched");
    assertEq(facility.getExit(address(positionManager)).cap, FINITE_EXIT_CAP, "cap untouched");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    11. UNLEVERED POOL                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_unleveredPoolCallsBackWithZeroDebtIn() public {
    _setExit(positionManager, FINITE_EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    ApproveExactExiter r = _newApproveExact();
    uint256 shares = _sharesFor(address(r));
    _unleverPool();
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee) =
      facility.previewExit(address(positionManager), shares);
    assertEq(previewDebtIn, 0, "unlevered debtIn");
    assertEq(previewFee, _feeShares(shares, DEFAULT_FEE_BPS), "share fee still charged");
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);

    (uint256 out, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    assertEq(r.callCount(), 1, "callback still runs on a zero debt leg");
    assertEq(r.lastDebtIn(), 0, "callback debtIn is zero");
    assertEq(r.lastShares(), shares, "callback shares");
    assertEq(debtIn, 0, "no debt pulled");
    assertEq(out, previewOut, "out matches preview");
    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    assertEq(positionManager.balanceOf(feeRecipient) - feeBefore, previewFee, "fee shares on a zero debt leg");
    assertEq(facility.getExit(address(positionManager)).cap, FINITE_EXIT_CAP, "zero debt leg skips the cap");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               12. OFFER CHANGE FROM CALLBACK               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_facilitatorRaisesFeeInsideCallback() public {
    FacilitatorExiter r = new FacilitatorExiter(facility, positionManager, debtToken);
    vm.label(address(r), "FacilitatorExiter");
    vm.prank(owner);
    facility.grantRoles(address(r), FACILITY_FACILITATOR_ROLE);
    uint256 totalShares = _sharesFor(address(r));
    uint256 shares = totalShares / 2;
    uint24 newFeeBps = uint24(MAX_FEE);

    (uint256 previewDebtIn,, uint256 previewFee) = facility.previewExit(address(positionManager), shares);
    assertEq(previewFee, _feeShares(shares, DEFAULT_FEE_BPS), "fee at the default rate");
    _fundDebt(address(r), previewDebtIn);
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);

    // This exit's fee split and debtIn were read before the callback: the raise is inert here.
    (, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, abi.encode(newFeeBps));

    assertEq(r.callCount(), 1, "callback count");
    assertEq(debtIn, previewDebtIn, "debtIn unchanged by the in-callback fee raise");
    assertEq(r.lastDebtIn(), previewDebtIn, "callback debtIn unchanged");
    assertEq(positionManager.balanceOf(feeRecipient) - feeBefore, previewFee, "old fee shares forwarded");
    assertEq(facility.getExit(address(positionManager)).feeBps, newFeeBps, "offer updated");
    assertEq(debtToken.balanceOf(address(r)), 0, "exact pull at the old fee");
    _assertFacilityClean();

    // The next exit prices at the new fee: more fee shares, fewer burned, a smaller debt slice.
    uint256 rest = totalShares - shares;
    (uint256 nextDebtIn,, uint256 nextFee) = facility.previewExit(address(positionManager), rest);
    assertEq(nextFee, _feeShares(rest, newFeeBps), "next fee at the raised rate");
    assertGt(nextFee, _feeShares(rest, DEFAULT_FEE_BPS), "raised above the default fee");
    assertLt(nextDebtIn, previewDebtIn, "fewer shares burned pulls less debt");
    _fundDebt(address(r), nextDebtIn);
    feeBefore = positionManager.balanceOf(feeRecipient);
    (, uint256 debtIn2) = r.exit(rest, type(uint256).max, 0, receiver, abi.encode(newFeeBps));
    assertEq(debtIn2, nextDebtIn, "second exit at the new fee");
    assertEq(positionManager.balanceOf(feeRecipient) - feeBefore, nextFee, "new fee shares forwarded");
    _assertFacilityClean();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        13. EVENTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_emitsExitedWithCallbackAmounts() public {
    ApproveExactExiter r = _newApproveExact();
    uint256 shares = _sharesFor(address(r));
    vm.warp(block.timestamp + 30 days);
    (uint256 previewDebtIn, uint256 previewOut, uint256 previewFee) =
      facility.previewExit(address(positionManager), shares);
    _fundDebt(address(r), previewDebtIn);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IAtomicFacility.Exited(
      address(positionManager), address(r), receiver, previewOut, previewDebtIn, shares - previewFee, previewFee
    );
    (, uint256 debtIn) = r.exit(shares, type(uint256).max, 0, receiver, "x");

    assertEq(r.lastDebtIn(), debtIn, "event debt equals the callback debtIn");
    assertEq(r.lastDebtIn(), previewDebtIn, "callback amount");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  CALLBACK ACCESS CONTROL                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_callback_mockRejectsNonFacilityCaller() public {
    ApproveExactExiter r = _newApproveExact();
    vm.expectRevert(abi.encodeWithSelector(BaseExiter.NotFacility.selector, address(this)));
    r.onAtomicExit(address(positionManager), 1, 1, "x");
    assertEq(r.callCount(), 0, "no callback recorded");
  }
}
