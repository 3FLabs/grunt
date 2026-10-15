// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";
import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {IPositionManagerLP} from "src/interfaces/manager/base/IPositionManagerLP.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title InKindFacilityEnterTest
/// @notice Entry-side edges of InKindFacility: the mint gates, exact bounds, the security leg,
///         skipped zero transfers, reverts past the caps and previewEnter under pending PM fees.
contract InKindFacilityEnterTest is InKindFacilityBaseTest {
  using FixedPointMathLib for uint256;

  /// @dev Not a round fraction of the pool, so the fair mint floors.
  uint256 constant AMOUNT = 1_234_567_891_234_567_891_234;
  /// @dev Mirrors LibInKindView.MINT_ROUNDING_UNITS.
  uint256 constant MINT_ROUNDING_UNITS = 32;
  uint128 constant ARMED_CAP = 1_000e6;
  uint128 constant ARMED_AUTH = 100e6;

  bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

  function setUp() public override {
    super.setUp();
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _expectedDebt(uint256 amount) internal view returns (uint256) {
    return amount.mulDiv(positionManager.debtAmount(), positionManager.collateralAmount());
  }

  function _adjustedSupply() internal view returns (uint256) {
    (, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    return totalSupply_ + mgmtShares + perfShares + positionManager.virtualShareOffset();
  }

  /// @dev The NonNeutralMint gate: `S_adj * amount / C` plus 32 debt-wei of equity and one share.
  function _fairMint(uint256 amount) internal view returns (uint256 expected, uint256 tolerance) {
    uint256 supplyAdj = _adjustedSupply();
    expected = supplyAdj.mulDiv(amount, positionManager.collateralAmount());
    tolerance = supplyAdj.mulDivUp(MINT_ROUNDING_UNITS, positionManager.totalAssets() + 1) + 1;
  }

  function _mockDeposit(int256 sharesDelta) internal {
    vm.mockCall(
      address(positionManager), abi.encodeWithSelector(IPositionManagerLP.deposit.selector), abi.encode(sharesDelta)
    );
  }

  /// @dev Hands the facility what a mocked deposit would have produced.
  function _fundFacility(uint256 shares, uint256 debt) internal {
    vm.prank(seeder);
    positionManager.transfer(address(facility), shares);
    debtToken.setBalance(address(facility), debt);
  }

  function _absWord() internal view returns (uint256) {
    return _externalWord(address(absoluteCaps), POOL_ID, MULT_1X);
  }

  function _setAbsPoolAt(uint16 id, uint128 cap, uint128 hardCap) internal {
    vm.prank(owner);
    absoluteCaps.setCap(id, cap, hardCap);
  }

  /// @dev An entry of AMOUNT draws on an EXTERNAL capacity pool, the auth and the security cap.
  function _armCaps() internal {
    _setAbsPoolAt(POOL_ID, ARMED_CAP, ARMED_CAP);
    _setEntry(positionManager, _absWord(), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(ARMED_CAP);
    _setAuth(user, ARMED_AUTH, FAR_EXPIRY);
  }

  function _unleverPool() internal {
    uint256 borrowShares = morpho.position(marketId, address(borrowPosition)).borrowShares;
    debtToken.setBalance(address(this), debtToken.balanceOf(address(this)) + 100_000_000e6);
    debtToken.approve(address(morpho), type(uint256).max);
    morpho.repay(marketParams, 0, borrowShares, address(borrowPosition), "");
    assertEq(positionManager.debtAmount(), 0, "pool not unlevered");
  }

  function _dryRunEnter(uint256 amount) internal returns (uint256 shares, uint256 debt) {
    uint256 snap = vm.snapshotState();
    (shares, debt) = _enter(user, amount, receiver);
    vm.revertToState(snap);
  }

  function _enterAmount(uint256 minSharesOut) internal returns (uint256 shares, uint256 debt) {
    vm.prank(user);
    return facility.enter(address(positionManager), AMOUNT, 0, type(uint256).max, minSharesOut, receiver);
  }

  /// @dev Share slack of the preview estimate: `2 + a / C` debt-wei of equity, plus one share.
  function _previewSlack(uint256 amount) internal view returns (uint256) {
    return _adjustedSupply()
        .mulDivUp(2 + amount.divUp(positionManager.collateralAmount()), positionManager.totalAssets() + 1) + 1;
  }

  /// @dev Feeds previewEnter's (debt, shares) into enter's (minDebt, maxDebt, minSharesOut) and
  ///      matches the outcome field by field.
  function _assertPreviewFeedsEnterBounds() internal {
    (uint256 debt, uint256 shares, uint256 feeShares) = facility.previewEnter(address(positionManager), AMOUNT);
    uint256 slack = _previewSlack(AMOUNT);
    uint256 feeBefore = positionManager.balanceOf(feeRecipient);
    _fundEntrant(user, AMOUNT);

    vm.prank(user);
    (uint256 sharesOut, uint256 debtOut) =
      facility.enter(address(positionManager), AMOUNT, debt, debt, shares - slack, receiver);
    assertEq(debtOut, debt, "debt");
    assertApproxEqAbs(sharesOut, shares, slack, "shares");
    assertApproxEqAbs(positionManager.balanceOf(feeRecipient) - feeBefore, feeShares, slack, "fee shares");
  }

  function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256 count) {
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++count;
    }
  }

  function _countTransfersTo(Vm.Log[] memory logs, address token, address to) internal pure returns (uint256 count) {
    for (uint256 i; i < logs.length; ++i) {
      if (
        logs[i].emitter == token && logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER_TOPIC
          && logs[i].topics[2] == bytes32(uint256(uint160(to)))
      ) ++count;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        MINT GATES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_enter_revertsNonNeutralMintOneShareAboveTolerance() public {
    (uint256 expected, uint256 tolerance) = _fairMint(AMOUNT);
    _mockDeposit(int256(expected + tolerance + 1));
    _fundEntrant(user, AMOUNT);

    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonNeutralMint.selector, expected + tolerance + 1, expected));
    _enterAmount(0);
  }

  function test_enter_mintAtTheToleranceBoundPasses() public {
    vm.warp(block.timestamp + 1 days);
    (uint256 expected, uint256 tolerance) = _fairMint(AMOUNT);
    // an odd rounding term tells the trailing `+ 1` apart from `^ 1`
    assertEq(tolerance % 2, 0, "fixture: rounding term must be odd");
    uint256 minted = expected + tolerance;
    uint256 fee = minted.mulDivUp(DEFAULT_FEE_BPS, BPS);
    uint256 debt = _expectedDebt(AMOUNT);
    _fundFacility(minted, debt);
    _mockDeposit(int256(minted));
    _fundEntrant(user, AMOUNT);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.Entered(address(positionManager), user, receiver, AMOUNT, debt, minted - fee, fee);
    (uint256 shares,) = _enterAmount(0);

    assertEq(shares, minted - fee, "net shares");
    assertEq(positionManager.balanceOf(receiver), minted - fee, "receiver shares");
    assertEq(positionManager.balanceOf(feeRecipient), fee, "fee shares");
    assertEq(debtToken.balanceOf(receiver), debt, "receiver debt");
  }

  function test_enter_zeroMintRevertsInsufficientSharesOut() public {
    _mockDeposit(0);
    _fundEntrant(user, AMOUNT);

    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, 0, 0));
    _enterAmount(0);
  }

  function test_enter_burnRevertsInsufficientSharesOut() public {
    _mockDeposit(-1);
    _fundEntrant(user, AMOUNT);

    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InsufficientSharesOut.selector, 0, 7));
    _enterAmount(7);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     SLIPPAGE BOUNDS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_enter_exactDebtBoundsPass() public {
    uint256 debt = _expectedDebt(AMOUNT);
    _fundEntrant(user, AMOUNT);

    vm.prank(user);
    (, uint256 got) = facility.enter(address(positionManager), AMOUNT, debt, debt, 0, receiver);
    assertEq(got, debt, "debt");
    assertEq(debtToken.balanceOf(receiver), debt, "receiver debt");
  }

  function test_enter_revertsOnInvertedDebtBounds() public {
    uint256 debt = _expectedDebt(AMOUNT);
    _fundEntrant(user, AMOUNT);

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DebtOutOfBounds.selector, debt, debt + 1, debt - 1));
    facility.enter(address(positionManager), AMOUNT, debt + 1, debt - 1, 0, receiver);
  }

  function test_enter_exactMinSharesOutPasses() public {
    (uint256 net,) = _dryRunEnter(AMOUNT);
    _fundEntrant(user, AMOUNT);

    (uint256 shares,) = _enterAmount(net);
    assertEq(shares, net, "net shares");
    assertEq(positionManager.balanceOf(receiver), net, "receiver shares");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         MAX ENTER                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_maxEnter_revertsOnUnleveredPoolWhileTheOfferIsClosedToIt() public {
    _unleverPool();
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.UnleveredEntryDisabled.selector, address(positionManager)));
    facility.maxEnter(address(positionManager), user);
  }

  function test_maxEnter_oneUnitBudgetQuotesADustEntry() public {
    vm.warp(block.timestamp + 1 days);
    _setEntry(positionManager, 1, FAR_EXPIRY, DEFAULT_FEE_BPS);
    uint256 totalCollateral = positionManager.collateralAmount();
    uint256 totalDebt = positionManager.debtAmount();
    assertGt(totalCollateral % totalDebt, 0, "fixture: debt must not divide collateral");

    uint256 max = facility.maxEnter(address(positionManager), user);
    assertEq(max, totalCollateral / totalDebt, "max");
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, max));
    facility.previewEnter(address(positionManager), max);
    _fundEntrant(user, max);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.DustEntry.selector, max));
    facility.enter(address(positionManager), max, 0, type(uint256).max, 0, receiver);
  }

  function test_maxEnter_capacityAndSecurityWordsSharingAPoolCountItTwice() public {
    _setAbsPoolAt(POOL_ID, ARMED_CAP, ARMED_CAP);
    _setEntry(positionManager, _absWord(), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(_absWord());

    uint256 max = facility.maxEnter(address(positionManager), user);
    assertEq(max, uint256(ARMED_CAP).mulDiv(SEED_COLLATERAL, SEED_DEBT), "max");
    _fundEntrant(user, max);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.enter(address(positionManager), max, 0, type(uint256).max, 0, receiver);

    (, uint256 debt) = _enter(user, max / 2, receiver);
    assertEq(debt, ARMED_CAP / 2, "debt");
    (uint128 cap,) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, 0, "pool");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       SECURITY LEG                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_enter_expiredAuthEmitsNoAuthConsumed() public {
    _setAuth(user, ARMED_AUTH, uint40(block.timestamp));
    _fundEntrant(user, AMOUNT);

    vm.recordLogs();
    _enterAmount(0);
    assertEq(
      _countLogs(vm.getRecordedLogs(), address(facility), IInKindFacility.AuthConsumed.selector), 0, "AuthConsumed"
    );
  }

  function test_enter_authCoveringTheDebtSkipsTheExternalSecurityWord() public {
    _setAbsPoolAt(SECURITY_POOL_ID, ARMED_CAP, ARMED_CAP);
    _setSecurityCap(_externalWord(address(absoluteCaps), SECURITY_POOL_ID, MULT_1X));
    _setAuth(user, ARMED_CAP, FAR_EXPIRY);
    uint256 debt = _expectedDebt(AMOUNT);
    _fundEntrant(user, AMOUNT);

    vm.expectCall(address(absoluteCaps), abi.encodeWithSelector(IFacilityCaps.consume.selector), 0);
    _enterAmount(0);
    assertEq(facility.getAuth(address(underlyingToken), user).amount, ARMED_CAP - debt, "auth");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    UNLEVERED AND ZERO LEGS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_enter_unleveredIgnoresExternalWordsOfARevokedConsumer() public {
    _setAbsPoolAt(POOL_ID, ARMED_CAP, ARMED_CAP);
    vm.prank(owner);
    dynamicCaps.setCap(SECURITY_POOL_ID, ARMED_CAP, uint64(1 days), uint64(block.timestamp - 1 days));
    _setEntry(positionManager, _absWord(), FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    _setSecurityCap(_externalWord(address(dynamicCaps), SECURITY_POOL_ID, MULT_1X));
    _unleverPool();
    (uint256 expectedShares,) = _dryRunEnter(AMOUNT);
    vm.startPrank(owner);
    absoluteCaps.revokeRoles(address(facility), CAPS_CONSUMER_ROLE);
    dynamicCaps.revokeRoles(address(facility), CAPS_CONSUMER_ROLE);
    vm.stopPrank();
    _fundEntrant(user, AMOUNT);

    (uint256 shares, uint256 debt) = _enterAmount(0);
    assertEq(debt, 0, "debt");
    assertEq(shares, expectedShares, "shares");
    assertEq(positionManager.balanceOf(receiver), expectedShares, "receiver shares");
  }

  function test_enter_unleveredMovesNoDebtAsset() public {
    _unleverPool();
    _setEntry(positionManager, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS, true);
    _fundEntrant(user, AMOUNT);

    vm.recordLogs();
    _enterAmount(0);
    assertEq(_countLogs(vm.getRecordedLogs(), address(debtToken), TRANSFER_TOPIC), 0, "debt asset transfer");
  }

  function test_enter_zeroFeeSendsNoFeeShares() public {
    _openOffersNoFee();
    _fundEntrant(user, AMOUNT);

    vm.recordLogs();
    _enterAmount(0);
    assertEq(_countTransfersTo(vm.getRecordedLogs(), address(positionManager), feeRecipient), 0, "fee transfer");
  }

  function test_enter_feeTakingTheWholeMintSendsNoShares() public {
    uint256 debt = _expectedDebt(AMOUNT);
    _fundFacility(1, debt);
    _mockDeposit(1);
    _fundEntrant(user, AMOUNT);

    vm.recordLogs();
    (uint256 shares, uint256 got) = _enterAmount(0);
    assertEq(_countTransfersTo(vm.getRecordedLogs(), address(positionManager), receiver), 0, "share transfer");
    assertEq(shares, 0, "net shares");
    assertEq(got, debt, "debt");
    assertEq(positionManager.balanceOf(feeRecipient), 1, "fee shares");
    assertEq(debtToken.balanceOf(receiver), debt, "receiver debt");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  REVERTS PAST THE CAPS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_enter_revertsTransferFromFailedWithoutApproval() public {
    _armCaps();
    underlyingToken.setBalance(user, AMOUNT);

    vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
    _enterAmount(0);
  }

  function test_enter_revertsUnauthorizedWithoutMinterRole() public {
    _armCaps();
    vm.prank(owner);
    positionManager.revokeRoles(address(facility), PM_MINTER_ROLE);
    _fundEntrant(user, AMOUNT);

    vm.expectRevert(Ownable.Unauthorized.selector);
    _enterAmount(0);
  }

  function test_enter_revertsInsufficientBorrowCapacityOnMarketShortfall() public {
    _armCaps();
    uint256 debt = _expectedDebt(AMOUNT);
    morpho.withdraw(marketParams, borrowPosition.availableLiquidity() - (debt - 1), 0, address(this), address(this));
    _fundEntrant(user, AMOUNT);

    vm.expectRevert(LibManagerErrors.InsufficientBorrowCapacity.selector);
    _enterAmount(0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       PREVIEW ENTER                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_previewEnter_valuesFollowEnterBoundsOrder() public {
    _assertPreviewFeedsEnterBounds();
    _setPmFees(200, 2_000);
    oracle.setPrice(1.2e24);
    vm.warp(block.timestamp + 90 days);
    _assertPreviewFeedsEnterBounds();
    oracle.setPrice(0.8e24);
    _assertPreviewFeedsEnterBounds();
  }

  function test_previewEnter_exactUnderPendingPmFees() public {
    _setPmFees(200, 2_000);
    oracle.setPrice(1.2e24);
    vm.warp(block.timestamp + 90 days);
    (uint256 totalAssets_, uint256 totalSupply_, uint256 mgmtShares, uint256 perfShares) = positionManager.pendingFees();
    assertGt(mgmtShares, 0, "fixture: pending management fee");
    assertGt(perfShares, 0, "fixture: pending performance fee");
    uint256 debt = _expectedDebt(AMOUNT);
    uint256 quoted = positionManager.collateralAmountQuoted().mulDiv(AMOUNT, positionManager.collateralAmount());
    uint256 supplyAdj = totalSupply_ + mgmtShares + perfShares + positionManager.virtualShareOffset();
    uint256 minted = (quoted - debt).mulDiv(supplyAdj, totalAssets_ + 1);
    uint256 fee = minted.mulDivUp(DEFAULT_FEE_BPS, BPS);

    (uint256 previewDebt, uint256 previewShares, uint256 previewFee) =
      facility.previewEnter(address(positionManager), AMOUNT);
    assertEq(previewDebt, debt, "preview debt");
    assertEq(previewShares, minted - fee, "preview shares");
    assertEq(previewFee, fee, "preview fee");
  }
}
