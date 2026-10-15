// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibBorrowErrors} from "src/libs/borrow/LibBorrowErrors.sol";
import {MorphoExiter} from "test/mock/facility/InKindExiters.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {IMorpho, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @notice Repays the borrow module's whole Morpho debt inside the callback, then approves `debtIn`.
contract FullRepayExiter is MorphoExiter {
  using MarketParamsLib for MarketParams;

  constructor(
    IInKindFacility facility_,
    PositionManager pm_,
    MockERC20 debtToken_,
    IMorpho morpho_,
    MarketParams memory marketParams_,
    address borrowPosition_
  ) MorphoExiter(facility_, pm_, debtToken_, morpho_, marketParams_, borrowPosition_) {}

  function _onExit(address, uint256, uint256 debtIn, bytes calldata) internal override {
    uint256 borrowShares = morpho.position(_marketParams.id(), borrowPosition).borrowShares;
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.repay(_marketParams, 0, borrowShares, borrowPosition, "");
    debtToken.approve(address(facility), debtIn);
  }
}

/// @notice Exit math computed in the test, independently of LibInKindView.
abstract contract InKindFacilityExitHelpers is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;

  uint256 constant ENTER_AMOUNT = 1_000e18;

  /// @dev debt + ceil(debt * 10 / 1e4) + 1, zero for zero.
  function _expectedPull(uint256 debt) internal pure returns (uint256) {
    if (debt == 0) return 0;
    return debt + (debt * 10 + 9_999) / 10_000 + 1;
  }

  function _adjustedSupply() internal view returns (uint256) {
    (, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    return totalSupply_ + mgmtShares + perfShares + positionManager.virtualShareOffset();
  }

  function _burnShares(uint256 shares, uint24 feeBps) internal pure returns (uint256) {
    return shares - shares.mulDivUp(feeBps, BPS);
  }

  function _mirrorDebt(uint256 burnShares) internal view returns (uint256) {
    return positionManager.debtAmount().mulDivUp(burnShares, _adjustedSupply());
  }

  function _mirrorOut(uint256 burnShares) internal view returns (uint256) {
    return positionManager.collateralAmount().mulDiv(burnShares, _adjustedSupply());
  }

  /// @dev The facility reads the debt through the external view, burn through PM storage.
  function _mockDebtAmount(uint256 debt) internal {
    vm.mockCall(address(positionManager), abi.encodeCall(positionManager.debtAmount, ()), abi.encode(debt));
  }

  /// @dev Funds `who` with exactly `debt` of the debt asset and approves the exit.
  function _fundExit(address who, uint256 shares, uint256 debt) internal {
    debtToken.setBalance(who, debt);
    vm.startPrank(who);
    debtToken.approve(address(facility), debt);
    positionManager.approve(address(facility), shares);
    vm.stopPrank();
  }
}

contract InKindFacilityExitTest is InKindFacilityExitHelpers {
  using FixedPointMathLib for uint256;

  uint128 constant EXIT_CAP = 1_000e6;

  function setUp() public override {
    super.setUp();
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _absWord(int24 multiplier) internal view returns (uint256) {
    return _externalWord(address(absoluteCaps), POOL_ID, multiplier);
  }

  function _setAbsPool(uint128 cap, uint128 hardCap) internal {
    vm.prank(owner);
    absoluteCaps.setCap(POOL_ID, cap, hardCap);
  }

  function _unleverPool() internal {
    uint256 borrowShares = morpho.position(marketId, address(borrowPosition)).borrowShares;
    debtToken.setBalance(address(this), 100_000_000e6);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.repay(marketParams, 0, borrowShares, address(borrowPosition), "");
    assertEq(positionManager.debtAmount(), 0, "pool not unlevered");
  }

  /// @dev Enters as `user`, then mocks the facility's debt read `driftBps` below the real debt.
  function _enterAndDrift(uint256 driftBps)
    internal
    returns (uint256 shares, uint256 burnShares, uint256 mirror, uint256 pulled)
  {
    (shares,) = _enter(user, ENTER_AMOUNT, user);
    burnShares = _burnShares(shares, DEFAULT_FEE_BPS);
    pulled = _mirrorDebt(burnShares);
    _mockDebtAmount(positionManager.debtAmount().mulDiv(BPS - driftBps, BPS));
    mirror = _mirrorDebt(burnShares);
  }

  /// @dev Exits every holder of the default PM at a zero exit fee, returning the underlying out.
  function _exitEveryone() internal returns (uint256 out) {
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    address[3] memory holders = [user, seeder, feeRecipient];
    for (uint256 i = 0; i < holders.length; i++) {
      uint256 before = underlyingToken.balanceOf(holders[i]);
      _exit(holders[i], positionManager.balanceOf(holders[i]), holders[i]);
      out += underlyingToken.balanceOf(holders[i]) - before;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        DEBT HEADROOM                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_previewExit_debtRequiredLiterals() public {
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    // At a zero fee, exiting the whole adjusted supply mirrors exactly the pool debt.
    uint256 supplyAdj = _adjustedSupply();
    uint256[8] memory debts = [uint256(0), 1, 2, 999, 1_000, 1_001, 5_000e6, 5_000e6 + 1];
    uint256[8] memory pulls = [uint256(0), 3, 4, 1_001, 1_002, 1_004, 5_005_000_001, 5_005_000_003];
    for (uint256 i = 0; i < debts.length; i++) {
      _mockDebtAmount(debts[i]);
      (,,, uint256 debtRequired) = facility.previewExit(address(positionManager), supplyAdj);
      assertEq(debtRequired, pulls[i], "debtRequired");
    }
  }

  function test_exit_headroomAbsorbsBurnAboveTheMirror() public {
    (uint256 shares, uint256 burnShares, uint256 mirror, uint256 pulled) = _enterAndDrift(5);
    uint256 pull = _expectedPull(mirror);
    assertGt(pulled, mirror, "burn pulls above the mirror");
    assertLt(pulled, pull, "within the headroom");
    uint256 out = _mirrorOut(burnShares);
    _fundExit(user, shares, pull);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Exited(address(positionManager), user, receiver, out, pulled, burnShares, shares - burnShares);
    vm.prank(user);
    facility.exit(address(positionManager), shares, pull, out, receiver, "");

    assertEq(debtToken.balanceOf(user), pull - pulled, "refund");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_exit_noRefundWhenBurnPullsTheWholePull() public {
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 burnShares = _burnShares(shares, DEFAULT_FEE_BPS);
    uint256 pulled = _mirrorDebt(burnShares);
    // the mirror whose pull is exactly what burn takes, and a debt read that mirrors to it
    uint256 mirror = pulled * 1_000 / 1_001 - 2;
    while (_expectedPull(mirror) < pulled) mirror++;
    assertEq(_expectedPull(mirror), pulled, "fixture: pulled is a reachable pull");
    _mockDebtAmount((mirror - 1) * _adjustedSupply() / burnShares + 1);
    assertEq(_mirrorDebt(burnShares), mirror, "fixture: mocked mirror");
    _fundExit(user, shares, pulled);

    vm.expectCall(address(debtToken), abi.encodeCall(debtToken.transfer, (user, 0)), 0);
    vm.prank(user);
    facility.exit(address(positionManager), shares, pulled, 0, receiver, "");

    assertEq(debtToken.balanceOf(user), 0, "refund");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  function test_exit_capConsumesTheMirrorWhenBurnPullsMore() public {
    _setExit(positionManager, EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,, uint256 mirror, uint256 pulled) = _enterAndDrift(5);
    assertGt(pulled, mirror, "burn pulls above the mirror");
    _fundExit(user, shares, _expectedPull(mirror));

    vm.prank(user);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    assertEq(facility.getExit(address(positionManager)).cap, EXIT_CAP - mirror, "exit cap");
  }

  function test_exit_revertsWhenBurnPullsAboveTheHeadroom() public {
    (uint256 shares,, uint256 mirror, uint256 pulled) = _enterAndDrift(20);
    uint256 pull = _expectedPull(mirror);
    assertGt(pulled, pull, "burn pulls above the headroom");
    _fundExit(user, shares, pull);

    vm.prank(user);
    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    facility.exit(address(positionManager), shares, pull, 0, receiver, "");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      CALLBACK REFUNDS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_callbackRepayingAllDebtGetsThePullBack() public {
    _setExit(positionManager, EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    FullRepayExiter r =
      new FullRepayExiter(facility, positionManager, debtToken, morpho, marketParams, address(borrowPosition));
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, address(r));
    uint256 burnShares = _burnShares(shares, DEFAULT_FEE_BPS);
    uint256 mirror = _mirrorDebt(burnShares);
    uint256 out = _mirrorOut(burnShares);
    uint256 pull = _expectedPull(mirror);
    uint256 poolDebt = positionManager.debtAmount();
    debtToken.setBalance(address(r), poolDebt + pull);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Exited(address(positionManager), address(r), receiver, out, 0, burnShares, shares - burnShares);
    r.exit(shares, pull, out, receiver, "repay");

    assertEq(positionManager.debtAmount(), 0, "pool debt");
    assertEq(debtToken.balanceOf(address(r)), pull, "the whole pull is refunded");
    assertEq(facility.getExit(address(positionManager)).cap, EXIT_CAP - mirror, "exit cap");
    _assertFacilityClean();
    _assertNoAllowances();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ZERO LEGS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_unleveredPoolSkipsTheExternalExitWord() public {
    _setAbsPool(EXIT_CAP, EXIT_CAP);
    _setExit(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    _unleverPool();
    vm.prank(owner);
    absoluteCaps.revokeRoles(address(facility), CAPS_CONSUMER_ROLE);
    uint256 out = _mirrorOut(_burnShares(shares, DEFAULT_FEE_BPS));

    vm.startPrank(user);
    positionManager.approve(address(facility), shares);
    facility.exit(address(positionManager), shares, 0, out, receiver, "");
    vm.stopPrank();

    assertEq(underlyingToken.balanceOf(receiver), out, "receiver underlying");
    (uint128 pool,) = absoluteCaps.getCap(POOL_ID);
    assertEq(pool, EXIT_CAP, "pool");
  }

  function test_exit_unleveredPoolMakesNoDebtTokenCall() public {
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    _unleverPool();
    vm.prank(user);
    positionManager.approve(address(facility), shares);

    vm.expectCall(address(debtToken), abi.encodeCall(debtToken.transferFrom, (user, address(facility), 0)), 0);
    vm.expectCall(address(debtToken), abi.encodeCall(debtToken.approve, (address(positionManager), 0)), 0);
    vm.prank(user);
    facility.exit(address(positionManager), shares, 0, 0, receiver, "");
  }

  function test_exit_zeroFeeMakesNoFeeShareTransfer() public {
    _setExit(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0);
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 feeShares = positionManager.balanceOf(feeRecipient);

    vm.expectCall(address(positionManager), abi.encodeCall(positionManager.transfer, (feeRecipient, 0)), 0);
    _exit(user, shares, receiver);

    assertEq(positionManager.balanceOf(feeRecipient), feeShares, "fee shares");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     EXTERNAL EXIT WORDS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_externalAbsoluteWordConsumesThePool() public {
    _setAbsPool(EXIT_CAP, EXIT_CAP);
    uint256 word = _absWord(MULT_1X);
    _setExit(positionManager, word, FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 mirror = _mirrorDebt(_burnShares(shares, DEFAULT_FEE_BPS));
    _fundExit(user, shares, _expectedPull(mirror));

    vm.expectEmit(true, true, true, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(POOL_ID, mirror, MULT_1X, mirror, uint128(EXIT_CAP - mirror));
    vm.prank(user);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    (uint128 pool,) = absoluteCaps.getCap(POOL_ID);
    assertEq(pool, EXIT_CAP - mirror, "pool");
    assertEq(facility.getExit(address(positionManager)).cap, word, "word");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     NEGATIVE EXIT WORDS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_negativeWordPastTheHeadroomRevertsHardCapExceeded() public {
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 mirror = _mirrorDebt(_burnShares(shares, DEFAULT_FEE_BPS));
    uint128 pool = EXIT_CAP - uint128(mirror - 1);
    _setAbsPool(pool, EXIT_CAP);
    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _fundExit(user, shares, _expectedPull(mirror));

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, pool, "pool");
    assertEq(hardCap, EXIT_CAP, "hard cap");
    assertEq(positionManager.balanceOf(user), shares, "shares");
    assertEq(debtToken.balanceOf(user), _expectedPull(mirror), "debt asset");
    _assertFacilityClean();
  }

  function test_maxExit_quotesTheReleaseHeadroom() public {
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 headroom = 100e6;
    _setAbsPool(EXIT_CAP - uint128(headroom), EXIT_CAP);
    uint256 supplyAdj = _adjustedSupply();
    uint256 totalDebt = positionManager.debtAmount();

    // -2x releases twice the debt: half the headroom in debt
    _setExit(positionManager, _absWord(2 * MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    uint256 half = (headroom / 2).mulDiv(supplyAdj, totalDebt).mulDiv(BPS, BPS - DEFAULT_FEE_BPS);
    assertEq(facility.maxExit(address(positionManager)), half, "maxExit at -2x");

    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    uint256 max = headroom.mulDiv(supplyAdj, totalDebt).mulDiv(BPS, BPS - DEFAULT_FEE_BPS);
    assertEq(facility.maxExit(address(positionManager)), max, "maxExit at -1x");
    assertLt(max, shares, "fixture: the headroom binds");

    uint256 mirror = _mirrorDebt(_burnShares(max, DEFAULT_FEE_BPS));
    _fundExit(user, max, _expectedPull(mirror));
    vm.prank(user);
    facility.exit(address(positionManager), max, type(uint256).max, 0, receiver, "");

    (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, EXIT_CAP - headroom + mirror, "pool credited");
    assertLe(cap, hardCap, "above the hard cap");
  }

  function test_exit_creditOfSharesThatNeverEnteredBlocksNettedExits() public {
    _setAbsPool(EXIT_CAP, EXIT_CAP);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares, uint256 debt) = _enter(user, ENTER_AMOUNT, user);
    uint256 mirror = _mirrorDebt(_burnShares(shares, DEFAULT_FEE_BPS));
    assertLt(mirror, debt, "fixture: the user's exit fits its own entry");

    // the seeder never consumed the pool: its exit up to maxExit takes the headroom
    _exit(seeder, facility.maxExit(address(positionManager)), seeder);
    (uint128 pool,) = absoluteCaps.getCap(POOL_ID);
    assertLt(EXIT_CAP - pool, mirror, "fixture: headroom left");
    _fundExit(user, shares, _expectedPull(mirror));

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    uint256 max = uint256(EXIT_CAP - pool)
      .mulDiv(_adjustedSupply(), positionManager.debtAmount())
      .mulDiv(BPS, BPS - DEFAULT_FEE_BPS);
    assertEq(facility.maxExit(address(positionManager)), max, "maxExit");
    assertLt(max, shares, "maxExit covers the user");
  }

  function test_exit_nettedWordCreditsAccruedInterest() public {
    _setAbsPool(EXIT_CAP, EXIT_CAP);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, 0);
    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, 0);
    (uint256 shares, uint256 debt) = _enter(user, ENTER_AMOUNT, user);
    vm.warp(block.timestamp + 30 days);
    uint256 mirror = _mirrorDebt(shares);
    assertGt(mirror, debt, "fixture: interest accrued on the slice");
    _fundExit(user, shares, _expectedPull(mirror));

    // the slice carries interest the entry never consumed: the user's own exit overflows
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    assertEq(
      facility.maxExit(address(positionManager)),
      debt.mulDiv(_adjustedSupply(), positionManager.debtAmount()),
      "maxExit is the consumed debt"
    );
  }

  function test_exit_hardCapBlockClearsBySetCapNotAdjustCap() public {
    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 mirror = _mirrorDebt(_burnShares(shares, DEFAULT_FEE_BPS));
    _setAbsPool(EXIT_CAP, EXIT_CAP);
    _fundExit(user, shares, _expectedPull(mirror));
    bytes memory blocked = abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID));

    // adjustCap keeps hardCap - cap, so it moves no headroom either way
    vm.prank(owner);
    absoluteCaps.adjustCap(POOL_ID, int256(mirror));
    vm.prank(user);
    vm.expectRevert(blocked);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
    vm.prank(owner);
    absoluteCaps.adjustCap(POOL_ID, -int256(2 * mirror));
    vm.prank(user);
    vm.expectRevert(blocked);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, EXIT_CAP - mirror, "cap");
    assertEq(hardCap, cap, "no headroom");

    vm.prank(owner);
    absoluteCaps.setCap(POOL_ID, cap, cap + uint128(mirror));
    vm.prank(user);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    (cap, hardCap) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, hardCap, "pool back at its hard cap");
    assertEq(positionManager.balanceOf(user), 0, "shares");
  }

  function test_exit_hardCapBlockClearsByEntryOrWordReArm() public {
    _setAbsPool(EXIT_CAP, EXIT_CAP);
    _setEntry(positionManager, _absWord(MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, _absWord(MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 mirror = _mirrorDebt(_burnShares(shares, DEFAULT_FEE_BPS));
    _setAbsPool(EXIT_CAP, EXIT_CAP);
    _fundExit(user, shares, _expectedPull(mirror));
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
    uint256 snap = vm.snapshotState();

    // an entry on the netted pool consumes headroom
    address next = makeAddr("next");
    (, uint256 nextDebt) = _enter(next, ENTER_AMOUNT, next);
    assertGe(nextDebt, mirror, "fixture: the entry frees the slice");
    vm.prank(user);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
    (uint128 pool,) = absoluteCaps.getCap(POOL_ID);
    assertEq(pool, EXIT_CAP - nextDebt + mirror, "pool after the entry and the exit");
    vm.revertToState(snap);

    // the facilitator re-arms the exit word
    _setExit(positionManager, EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    vm.prank(user);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");
    assertEq(facility.getExit(address(positionManager)).cap, EXIT_CAP - mirror, "ABSOLUTE word consumed");
    (pool,) = absoluteCaps.getCap(POOL_ID);
    assertEq(pool, EXIT_CAP, "pool untouched");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        SECURITY CAP                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_doesNotRefundTheSecurityCapOrTheAuth() public {
    _setSecurityCap(1_000e6);
    _setAuth(user, 100e6, FAR_EXPIRY);
    (uint256 shares, uint256 debt) = _enter(user, ENTER_AMOUNT, user);
    assertEq(debt, 500e6, "debt");
    assertEq(facility.getAuth(address(underlyingToken), user).amount, 0, "auth spent");
    assertEq(facility.getSecurityCap(address(underlyingToken)), 600e6, "security spent");

    _exit(user, shares, user);

    assertEq(facility.getAuth(address(underlyingToken), user).amount, 0, "auth refunded");
    assertEq(facility.getSecurityCap(address(underlyingToken)), 600e6, "security refunded");

    // a second round trip drains the lifetime budget further
    (shares, debt) = _enter(user, ENTER_AMOUNT, user);
    _exit(user, shares, user);
    uint256 left = 600e6 - debt;
    assertEq(facility.getSecurityCap(address(underlyingToken)), left, "security after two loops");

    uint256 nextDebt = ENTER_AMOUNT.mulDiv(positionManager.debtAmount(), positionManager.collateralAmount());
    assertGt(nextDebt, left, "fixture: the budget is gone");
    address next = makeAddr("next");
    _fundEntrant(next, ENTER_AMOUNT);
    vm.prank(next);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibFacilityErrors.CapExceeded.selector, uint256(uint160(address(underlyingToken))), left, nextDebt
      )
    );
    facility.enter(address(positionManager), ENTER_AMOUNT, 0, type(uint256).max, 0, next);
  }

  function test_exit_leavesAnExternalSecurityPoolConsumed() public {
    vm.prank(owner);
    absoluteCaps.setCap(SECURITY_POOL_ID, 1_000e6, 1_000e6);
    _setSecurityCap(_externalWord(address(absoluteCaps), SECURITY_POOL_ID, MULT_1X));
    (uint256 shares, uint256 debt) = _enter(user, ENTER_AMOUNT, user);

    vm.expectCall(address(absoluteCaps), abi.encodeWithSelector(IFacilityCaps.consume.selector), 0);
    _exit(user, shares, user);

    (uint128 pool,) = absoluteCaps.getCap(SECURITY_POOL_ID);
    assertEq(pool, 1_000e6 - debt, "security pool refunded");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       MODULE HEALTH                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_revertsAboveTheModuleSafeLtvWhileTheViewsQuote() public {
    _setExit(positionManager, EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    // 0.5 LTV at a 2/3 quote is 0.75: above the 0.72 safeLtv, under the 0.78 liquidation LTV
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2 / 3);
    assertFalse(positionManager.hasBadDebt(), "bad debt");
    uint256 burnShares = _burnShares(shares, DEFAULT_FEE_BPS);
    uint256 mirror = _mirrorDebt(burnShares);

    uint256 max =
      uint256(EXIT_CAP).mulDiv(_adjustedSupply(), positionManager.debtAmount()).mulDiv(BPS, BPS - DEFAULT_FEE_BPS);
    assertEq(facility.maxExit(address(positionManager)), max, "maxExit");
    assertGt(max, shares, "fixture: the cap does not bind");
    (uint256 debtIn, uint256 out, uint256 feeShares, uint256 debtRequired) =
      facility.previewExit(address(positionManager), shares);
    assertEq(debtIn, mirror, "preview debtIn");
    assertEq(out, _mirrorOut(burnShares), "preview out");
    assertEq(feeShares, shares - burnShares, "preview fee");
    assertEq(debtRequired, _expectedPull(mirror), "preview pull");
    _fundExit(user, shares, debtRequired);

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibBorrowErrors.InsufficientCollateral.selector));
    facility.exit(address(positionManager), shares, debtRequired, 0, receiver, "");

    // back under the safeLtv the same exit settles
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    vm.prank(user);
    (uint256 underlyingOut, uint256 repaid) =
      facility.exit(address(positionManager), shares, debtRequired, 0, receiver, "");
    assertEq(underlyingOut, out, "out");
    assertEq(repaid, debtIn, "repaid");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        PREVIEW ORDER                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_previewExit_valuesFollowExitBoundsOrder() public {
    _setPmFees(100, 1_000);
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    vm.warp(block.timestamp + 30 days);
    uint256 burnShares = _burnShares(shares, DEFAULT_FEE_BPS);
    (uint256 debtIn, uint256 underlyingOut, uint256 feeShares, uint256 debtRequired) =
      facility.previewExit(address(positionManager), shares);
    assertEq(debtIn, _mirrorDebt(burnShares), "debtIn");
    assertEq(underlyingOut, _mirrorOut(burnShares), "underlyingOut");
    assertEq(feeShares, shares - burnShares, "feeShares");
    assertEq(debtRequired, _expectedPull(debtIn), "debtRequired");
    _fundExit(user, shares, debtRequired);

    // each bound one unit past the preview value it pairs with reverts on that value
    vm.startPrank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.ExcessiveDebtIn.selector, debtRequired, debtRequired - 1));
    facility.exit(address(positionManager), shares, debtRequired - 1, underlyingOut, receiver, "");
    vm.expectRevert(
      abi.encodeWithSelector(IInKindFacility.InsufficientUnderlyingOut.selector, underlyingOut, underlyingOut + 1)
    );
    facility.exit(address(positionManager), shares, debtRequired, underlyingOut + 1, receiver, "");

    vm.expectCall(address(debtToken), abi.encodeCall(debtToken.transferFrom, (user, address(facility), debtRequired)));
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Exited(address(positionManager), user, receiver, underlyingOut, debtIn, burnShares, feeShares);
    (uint256 out, uint256 repaid) =
      facility.exit(address(positionManager), shares, debtRequired, underlyingOut, receiver, "");
    vm.stopPrank();

    assertEq(out, underlyingOut, "out");
    assertEq(repaid, debtIn, "repaid");
    assertEq(debtToken.balanceOf(user), debtRequired - debtIn, "refund");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       SLIPPAGE BOUNDS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_revertsExcessiveDebtInWhenMaxDebtInIsTheMirror() public {
    (uint256 shares,) = _enter(user, ENTER_AMOUNT, user);
    uint256 mirror = _mirrorDebt(_burnShares(shares, DEFAULT_FEE_BPS));
    _fundExit(user, shares, _expectedPull(mirror));

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.ExcessiveDebtIn.selector, _expectedPull(mirror), mirror));
    facility.exit(address(positionManager), shares, mirror, 0, receiver, "");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       FULL EXIT DUST                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_exit_fullExitLeavesUnleveredCollateralDust() public {
    _enter(user, ENTER_AMOUNT, user);
    uint256 collateralBefore = positionManager.collateralAmount();

    uint256 out = _exitEveryone();

    assertEq(positionManager.totalSupply(), 0, "supply");
    assertEq(positionManager.debtAmount(), 0, "debt");
    assertEq(positionManager.collateralAmount(), collateralBefore - out, "collateral");
    assertGt(positionManager.collateralAmount(), 0, "dust");
    assertEq(facility.maxExit(address(positionManager)), type(uint256).max, "maxExit");
    _assertFacilityClean();
  }

  function test_exit_fullExitClosesLeveredOnlyEntries() public {
    _enter(user, ENTER_AMOUNT, user);
    _exitEveryone();

    _fundEntrant(user, ENTER_AMOUNT);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnleveredEntryDisabled.selector, address(positionManager)));
    facility.enter(address(positionManager), ENTER_AMOUNT, 0, type(uint256).max, 0, user);
  }

  function test_exit_fullExitNextEntrantCapturesNoDust() public {
    _enter(user, ENTER_AMOUNT, user);
    _exitEveryone();
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, 0, true);
    uint256 dust = positionManager.collateralAmount();
    address next = makeAddr("next");

    (uint256 shares, uint256 debt) = _enter(next, ENTER_AMOUNT, next);
    assertEq(debt, 0, "unlevered entry");
    uint256 out = _mirrorOut(shares);
    _exit(next, shares, next);

    assertEq(underlyingToken.balanceOf(next), out, "next out");
    assertLt(out, ENTER_AMOUNT, "round trip is lossy");
    assertEq(positionManager.collateralAmount(), dust + ENTER_AMOUNT - out, "dust stays in the pool");
  }
}
