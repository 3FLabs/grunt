// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {SharedCapsE2EBaseTest} from "./SharedCapsE2EBase.t.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title SharedCapsE2ETest
/// @notice Facility intents and InKindFacility entries and exits on one FacilityAbsoluteCaps pool,
///         its drift to the hard cap under a negative exit word, the [asset pool, shared pool]
///         layout, and a FacilityDynamicCaps security cap shared by PM and PM2.
contract SharedCapsE2ETest is SharedCapsE2EBaseTest {
  using FixedPointMathLib for uint256;

  int24 constant MULT_1_5X = 6144;
  uint16 constant INTENT_POOL_ID = 4;
  uint16 constant INKIND_POOL_ID = 5;
  uint64 constant SECURITY_RATE_ID = 7;
  uint128 constant SECURITY_RECOVERY = 1_200e6;

  /// @dev Security on a dynamic cap shared by every PM wrapping the underlying, PM2 opened too.
  function _useRateSecurity() internal {
    _setRateFull(SECURITY_RATE_ID, SECURITY_RECOVERY);
    _setSecurityCap(_rateWord(SECURITY_RATE_ID, MULT_1X));
    _setEntry(positionManager2, _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager2, LibCaps.MAX_ABSOLUTE, FAR_EXPIRY, DEFAULT_FEE_BPS);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        SHARED POOL                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_sharedPool_depositAndEntryConsumeExactly() public {
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1_5X));
    uint256 amount = 1_000e6 + 1;
    // scaled to 18 decimals a 6-decimal amount is a multiple of 2^12: 1.5x charges it exactly
    uint256 charge = _capsUnits(amount) * 3 / 2;
    uint256 pool = _capsUnits(SHARED_POOL_CAP);
    _fundDepositor(depositor, amount);
    vm.prank(depositor);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(POOL_ID, _capsUnits(amount), MULT_1_5X, charge, uint128(pool - charge));
    intents.deposit(intentId, amount);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(
      POOL_ID, _capsUnits(500e6), MULT_1X, _capsUnits(500e6), uint128(pool - charge - _capsUnits(500e6))
    );
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    assertEq(debtToken.balanceOf(receiver), 500e6, "entry debt");
    (uint128 cap,) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, pool - charge - _capsUnits(500e6), "pool");
  }

  function test_sharedPool_withdrawAndRevertDepositReleaseOnlyTheIntentCharge() public {
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1_5X));
    _depositIntent(intentId, depositor, 1_000e6 + 1);
    _depositIntent(intentId, depositor2, 2_000e6);
    _enter(user, 1_000e18, receiver);
    // 6-decimal amounts scale to multiples of 2^12, so the 1.5x charges are exact both ways
    uint256 charge1 = _capsUnits(1_000e6 + 1) * 3 / 2;
    uint256 charge2 = _capsUnits(3_000e6);
    uint256 afterFlows = _capsUnits(SHARED_POOL_CAP - 500e6) - charge1 - charge2;
    (uint128 cap,) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, afterFlows, "after deposits and entry");

    vm.prank(depositor);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(POOL_ID, _capsUnits(1_000e6 + 1), -MULT_1_5X, charge1, uint128(afterFlows + charge1));
    intents.withdraw(intentId, depositor, depositor, 1_000e6 + 1);

    vm.prank(compliance);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(
      POOL_ID, _capsUnits(2_000e6), -MULT_1_5X, charge2, uint128(afterFlows + charge1 + charge2)
    );
    intents.revertDeposit(intentId, depositor2, depositor2);

    // the entry stays charged and the round trip gives back exactly what it took
    (cap,) = absoluteCaps.getCap(POOL_ID);
    assertEq(cap, _capsUnits(SHARED_POOL_CAP - 500e6), "pool");
  }

  function test_sharedPool_positiveExitWordConsumesTheMirroredDebt() public {
    _setExit(positionManager, _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _enter(user, 1_000e18, user);
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    _depositIntent(intentId, depositor, 1_000e6);
    uint128 beforeExit = SHARED_POOL_CAP - 1_500e6;
    assertEq(_poolCap(POOL_ID), beforeExit, "before exit");

    uint256 shares = positionManager.balanceOf(user);
    (uint256 debtIn,) = _exitMirror(positionManager, shares, DEFAULT_FEE_BPS);
    _approveExit(positionManager, user, shares, 2 * debtIn);
    vm.prank(user);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(
      POOL_ID, _capsUnits(debtIn), MULT_1X, _capsUnits(debtIn), uint128(_capsUnits(beforeExit - debtIn))
    );
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    assertEq(_poolCap(POOL_ID), beforeExit - debtIn, "pool");
  }

  function test_sharedPool_negativeExitWordHandsCapacityToIntents() public {
    _setExit(positionManager, _poolWord(POOL_ID, MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _enter(user, 1_000e18, user);
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    _depositIntent(intentId, depositor, SHARED_POOL_CAP - 500e6);
    assertEq(_poolCap(POOL_ID), 0, "drained");

    uint256 shares = positionManager.balanceOf(user);
    (uint256 debtIn,) = _exitMirror(positionManager, shares, DEFAULT_FEE_BPS);
    _approveExit(positionManager, user, shares, 2 * debtIn);
    vm.prank(user);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(
      POOL_ID, _capsUnits(debtIn), MULT_NEG_1X, _capsUnits(debtIn), uint128(_capsUnits(debtIn))
    );
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    _fundDepositor(depositor2, debtIn + 1);
    vm.prank(depositor2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, uint64(POOL_ID)));
    intents.deposit(intentId, debtIn + 1);
    vm.prank(depositor2);
    intents.deposit(intentId, debtIn);
    assertEq(_poolCap(POOL_ID), 0, "pool");
  }

  function test_sharedPool_negativeExitWordDriftsToHardCapUntilSetCap() public {
    _setExit(positionManager, _poolWord(POOL_ID, MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    _depositIntent(intentId, depositor, 1_000e6);
    (uint256 shares,) = _enter(user, 1_000e18, user);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_500e6, "after deposit and entry");

    // seeded shares never consumed the pool
    (, uint256 seederDebtIn) = _exit(seeder, facility.maxExit(address(positionManager)), seeder);
    uint128 drifted = _poolCap(POOL_ID);
    assertEq(drifted, SHARED_POOL_CAP - 1_500e6 + seederDebtIn, "seeder exit credits the pool");
    assertLt(SHARED_POOL_CAP - drifted, 1e6, "pool at its hard cap");

    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    intents.withdraw(intentId, depositor, depositor, 1_000e6);

    vm.prank(compliance);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    intents.revertDeposit(intentId, depositor, depositor);

    (uint256 debtIn,) = _exitMirror(positionManager, shares, DEFAULT_FEE_BPS);
    _approveExit(positionManager, user, shares, 2 * debtIn);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    _setPool(POOL_ID, drifted, SHARED_POOL_CAP + uint128(seederDebtIn));
    vm.prank(depositor);
    intents.withdraw(intentId, depositor, depositor, 1_000e6);
    vm.prank(user);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    assertEq(debtToken.balanceOf(depositor), 1_000e6, "withdrawal");
    assertEq(positionManager.balanceOf(user), 0, "exited");
    assertEq(_poolCap(POOL_ID), drifted + 1_000e6 + debtIn, "pool");
  }

  function test_sharedPool_interestCreditBlocksWithdrawUntilEntriesConsumeHeadroom() public {
    _setEntry(positionManager, _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, 0);
    _setExit(positionManager, _poolWord(POOL_ID, MULT_NEG_1X), FAR_EXPIRY, 0);
    (uint256 shares, uint256 debt) = _enter(user, 1_000e18, user);
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    _depositIntent(intentId, depositor, 1_000e6);

    vm.warp(block.timestamp + 1 days);
    (, uint256 debtIn) = _exit(user, shares, user);
    assertGt(debtIn, debt, "exit credits interest");
    uint256 drift = debtIn - debt;
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6 + drift, "pool after round trip");

    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, uint64(POOL_ID)));
    intents.withdraw(intentId, depositor, depositor, 1_000e6 - drift + 1);
    vm.prank(depositor);
    intents.withdraw(intentId, depositor, depositor, 1_000e6 - drift);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP, "pool at its hard cap");

    (, uint256 entryDebt) = _enter(makeAddr("entrant"), 1e18, receiver);
    assertGe(entryDebt, drift, "entry frees the headroom");
    vm.prank(depositor);
    intents.withdraw(intentId, depositor, depositor, drift);
    assertEq(intents.balanceOf(depositor, intentId), 0, "withdrawn");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - entryDebt + drift, "pool");
  }

  function test_sharedPool_entryRevertsInsufficientCapOnceIntentsDrainIt() public {
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    _depositIntent(intentId, depositor, SHARED_POOL_CAP - 499e6);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, uint64(POOL_ID)));
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    vm.prank(user);
    facility.enter(address(positionManager), 998e18, 0, type(uint256).max, 0, receiver);
    assertEq(debtToken.balanceOf(receiver), 499e6, "entry debt");
    assertEq(_poolCap(POOL_ID), 0, "pool");
  }

  function test_sharedPool_depositRevertsInsufficientCapOnceEntriesDrainIt() public {
    _enter(user, 19_000e18, receiver);
    assertEq(_poolCap(POOL_ID), 500e6, "after entry");
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));

    _fundDepositor(depositor, 500e6 + 1);
    vm.prank(depositor);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, uint64(POOL_ID)));
    intents.deposit(intentId, 500e6 + 1);

    vm.prank(depositor);
    intents.deposit(intentId, 500e6);
    assertEq(_poolCap(POOL_ID), 0, "pool");
  }

  function test_assetAndSharedPools_eachConsumerSpillsIntoTheSharedPool() public {
    _setPool(INTENT_POOL_ID, 1_000e6, 1_000e6);
    _setPool(INKIND_POOL_ID, 400e6, 400e6);
    _setPool(POOL_ID, 2_000e6, 2_000e6);
    uint64 intentIds = uint64(INTENT_POOL_ID) | (uint64(POOL_ID) << 16);
    uint64 inKindIds = uint64(INKIND_POOL_ID) | (uint64(POOL_ID) << 16);
    uint256 intentId = _createIntent(_poolWord(intentIds, MULT_1X));
    _setEntry(positionManager, _poolWord(inKindIds, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);

    _fundDepositor(depositor, 1_500e6);
    vm.prank(depositor);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(INTENT_POOL_ID, _capsUnits(1_500e6), MULT_1X, _capsUnits(1_000e6), 0);
    vm.expectEmit(true, false, false, true, address(absoluteCaps));
    emit IFacilityCaps.CapConsumed(
      POOL_ID, _capsUnits(1_500e6), MULT_1X, _capsUnits(500e6), uint128(_capsUnits(1_500e6))
    );
    intents.deposit(intentId, 1_500e6);

    _enter(user, 1_000e18, receiver);
    assertEq(_poolCap(INKIND_POOL_ID), 0, "in-kind asset pool");
    assertEq(_poolCap(POOL_ID), 1_400e6, "shared pool");

    // 1_401e6 of debt: the in-kind asset pool is empty and the shared pool holds 1_400e6
    _fundEntrant(user, 2_802e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, inKindIds));
    facility.enter(address(positionManager), 2_802e18, 0, type(uint256).max, 0, receiver);

    vm.prank(depositor);
    intents.withdraw(intentId, depositor, depositor, 1_500e6);
    assertEq(_poolCap(INTENT_POOL_ID), 1_000e6, "intent asset pool refilled first");
    assertEq(_poolCap(POOL_ID), 1_900e6, "shared pool keeps the in-kind spill");
    assertEq(_poolCap(INKIND_POOL_ID), 0, "in-kind asset pool untouched");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   DYNAMIC SECURITY CAP                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rateSecurity_authSpillsOverAcrossPositionManagers() public {
    _useRateSecurity();
    _setAuth(user, 300e6, FAR_EXPIRY);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectEmit(true, true, false, true, address(facility));
    emit IInKindFacility.AuthConsumed(address(underlyingToken), address(debtToken), user, 300e6, 0);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
    assertEq(_dynRemaining(SECURITY_RATE_ID), SECURITY_RECOVERY - 200e6, "PM entry");

    _enter(positionManager2, user, 1_000e18, receiver);
    assertEq(_dynRemaining(SECURITY_RATE_ID), SECURITY_RECOVERY - 700e6, "PM2 entry");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "auth");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6, "capacity of both PMs");
  }

  function test_rateSecurity_recoversOverTimeAndMaxEnterTracksIt() public {
    _useRateSecurity();
    _enter(user, 2_000e18, receiver);
    assertEq(_dynRemaining(SECURITY_RATE_ID), 200e6, "after entry");
    // keyed by the underlying: both PMs quote the same room at their own ratio
    assertEq(facility.maxEnter(address(positionManager), user), 400e18, "PM quote");
    assertEq(facility.maxEnter(address(positionManager2), user), 400e18, "PM2 quote");

    _fundEntrant(user, 401e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, SECURITY_RATE_ID));
    facility.enter(address(positionManager2), 401e18, 0, type(uint256).max, 0, receiver);

    vm.warp(block.timestamp + 6 hours);
    assertEq(_dynRemaining(SECURITY_RATE_ID), 500e6, "after 6h");
    uint256 quote = facility.maxEnter(address(positionManager2), user);
    assertEq(
      quote, uint256(500e6).mulDiv(positionManager2.collateralAmount(), positionManager2.debtAmount()), "quote after 6h"
    );

    uint256 debtBefore = debtToken.balanceOf(receiver);
    _enter(positionManager2, user, quote, receiver);
    assertEq(debtToken.balanceOf(receiver) - debtBefore, 500e6 - 1, "quoted debt");
    assertEq(_dynRemaining(SECURITY_RATE_ID), 0, "after quoted entry");

    vm.warp(block.timestamp + 1 days);
    assertEq(_dynRemaining(SECURITY_RATE_ID), SECURITY_RECOVERY, "full recovery");
  }

  function test_rateSecurity_negativeExitWordGivesNothingBack() public {
    _useRateSecurity();
    _setExit(positionManager, _rateWord(SECURITY_RATE_ID, MULT_NEG_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _enter(user, 1_000e18, user);
    assertEq(_dynRemaining(SECURITY_RATE_ID), 700e6, "after entry");

    _exit(user, positionManager.balanceOf(user), receiver);
    assertEq(positionManager.balanceOf(user), 0, "exited");
    assertEq(_dynRemaining(SECURITY_RATE_ID), 700e6, "after exit");
  }

  function test_rateCap_throughputSharedByIntentAndSecurityWord() public {
    _useRateSecurity();
    uint256 intentId = _createIntent(_rateWord(SECURITY_RATE_ID, MULT_1X));
    _depositIntent(intentId, depositor, 400e6);
    _enter(user, 1_000e18, receiver);
    assertEq(_dynRemaining(SECURITY_RATE_ID), 300e6, "after deposit and entry");

    vm.prank(depositor);
    intents.withdraw(intentId, depositor, depositor, 400e6);
    assertEq(_dynRemaining(SECURITY_RATE_ID), 300e6, "withdrawals give nothing back");

    _fundDepositor(depositor2, 300e6 + 1);
    vm.prank(depositor2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, SECURITY_RATE_ID));
    intents.deposit(intentId, 300e6 + 1);
  }
}
