// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {SharedCapsE2EBaseTest} from "./SharedCapsE2EBase.t.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";

/// @title RoleChangesE2ETest
/// @notice Role and registry changes while both facilities share the caps contracts: consumer
///         role revocations, PM MINTER_ROLE revocation, whitelist de-listing and pauses.
contract RoleChangesE2ETest is SharedCapsE2EBaseTest {
  uint64 constant SECURITY_RATE_ID = 7;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CAPS CONSUMER                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_revokeConsumer_facility_externalIntentFlowsRevertUnauthorized() public {
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    _depositIntent(intentId, depositor, 1_000e6);
    vm.prank(owner);
    absoluteCaps.revokeRoles(address(intents), CAPS_CONSUMER_ROLE);

    _fundDepositor(depositor2, 1e6);
    vm.prank(depositor2);
    vm.expectRevert(Ownable.Unauthorized.selector);
    intents.deposit(intentId, 1e6);

    vm.prank(depositor);
    vm.expectRevert(Ownable.Unauthorized.selector);
    intents.withdraw(intentId, depositor, depositor, 1e6);

    vm.prank(compliance);
    vm.expectRevert(Ownable.Unauthorized.selector);
    intents.revertDeposit(intentId, depositor, depositor);

    assertEq(intents.balanceOf(depositor, intentId), 1_000e6, "shares");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6, "pool");
  }

  function test_revokeConsumer_facility_absoluteIntentsAndInKindKeepWorking() public {
    vm.prank(owner);
    absoluteCaps.revokeRoles(address(intents), CAPS_CONSUMER_ROLE);

    uint256 intentId = _createIntent(2_000e6);
    _depositIntent(intentId, depositor, 1_000e6);
    vm.prank(depositor);
    intents.withdraw(intentId, depositor, depositor, 400e6);
    assertEq(intents.totalSupply(intentId), 600e6, "absolute intent");

    _enter(user, 1_000e18, receiver);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 500e6, "in-kind entries consume the pool");
  }

  function test_revokeConsumer_inKind_externalWordsRevertUnauthorized() public {
    _setExit(positionManager, _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _enter(user, 1_000e18, user);
    uint256 shares = positionManager.balanceOf(user);
    vm.prank(owner);
    absoluteCaps.revokeRoles(address(facility), CAPS_CONSUMER_ROLE);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    _approveExit(positionManager, user, shares, 1_000e6);
    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    assertEq(positionManager.balanceOf(user), shares, "shares");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 500e6, "pool");
  }

  function test_revokeConsumer_inKind_absoluteWordsAndIntentsKeepWorking() public {
    vm.prank(owner);
    absoluteCaps.revokeRoles(address(facility), CAPS_CONSUMER_ROLE);
    _setEntry(positionManager, 1_000e6, FAR_EXPIRY, DEFAULT_FEE_BPS);

    _enter(user, 1_000e18, user);
    assertEq(facility.getEntry(address(positionManager)).capacityCap, 500e6, "absolute capacity");

    uint256 shares = positionManager.balanceOf(user);
    (uint256 debtIn,) = _exitMirror(positionManager, shares, DEFAULT_FEE_BPS);
    _exit(user, shares, receiver);
    assertEq(facility.getExit(address(positionManager)).cap, LibCaps.MAX_ABSOLUTE - debtIn, "absolute exit word");

    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    _depositIntent(intentId, depositor, 1_000e6);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6, "intents consume the pool");
  }

  function test_revokeConsumer_securityCaps_onlyAuthCoveredEntriesPass() public {
    _setRateFull(SECURITY_RATE_ID, 1_000e6);
    _setSecurityCap(_rateWord(SECURITY_RATE_ID, MULT_1X));
    _setAuth(user, 500e6, FAR_EXPIRY);
    vm.prank(owner);
    dynamicCaps.revokeRoles(address(facility), CAPS_CONSUMER_ROLE);

    _fundEntrant(depositor, 1_000e18);
    vm.prank(depositor);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    _enter(user, 1_000e18, receiver);
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "auth");
    assertEq(_dynRemaining(SECURITY_RATE_ID), 1_000e6, "security");
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 500e6, "capacity");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         PM MINTER                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_revokeMinter_inKind_entryRevertsAndCapsRollBack() public {
    _setAuth(user, 300e6, FAR_EXPIRY);
    vm.prank(owner);
    positionManager.revokeRoles(address(facility), PM_MINTER_ROLE);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP, "capacity");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 300e6, "auth");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), LibCaps.MAX_ABSOLUTE, "security");
    assertEq(underlyingToken.balanceOf(user), 1_000e18, "underlying");
  }

  function test_revokeMinter_inKind_blocksOnlyThatPositionManager() public {
    _enter(user, 1_000e18, user);
    uint256 shares = positionManager.balanceOf(user);
    vm.prank(owner);
    positionManager.revokeRoles(address(facility), PM_MINTER_ROLE);

    _approveExit(positionManager, user, shares, 1_000e6);
    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.exit(address(positionManager), shares, type(uint256).max, 0, receiver, "");

    _setEntry(positionManager2, _poolWord(POOL_ID, MULT_1X), FAR_EXPIRY, DEFAULT_FEE_BPS);
    _enter(positionManager2, user, 1_000e18, receiver);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6, "PM2 entries consume the pool");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         WHITELIST                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_delistCaps_storedWordsKeepConsumingInBothFacilities() public {
    _setRateFull(SECURITY_RATE_ID, 1_000e6);
    _setSecurityCap(_rateWord(SECURITY_RATE_ID, MULT_1X));
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    vm.startPrank(owner);
    whitelist.setAllowed(address(absoluteCaps), false);
    whitelist.setAllowed(address(dynamicCaps), false);
    vm.stopPrank();

    _depositIntent(intentId, depositor, 1_000e6);
    _enter(user, 1_000e18, receiver);
    vm.prank(depositor);
    intents.withdraw(intentId, depositor, depositor, 400e6);

    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_100e6, "pool");
    assertEq(_dynRemaining(SECURITY_RATE_ID), 500e6, "security");
  }

  function test_delistCaps_resettingAStoredWordRevertsInBothFacilities() public {
    uint256 entryWord = _poolWord(POOL_ID, MULT_1X);
    uint256 exitWord = _poolWord(POOL_ID, MULT_NEG_1X);
    uint256 securityWord = _rateWord(SECURITY_RATE_ID, MULT_1X);
    _setRateFull(SECURITY_RATE_ID, 1_000e6);
    _setSecurityCap(securityWord);
    _setExit(positionManager, exitWord, FAR_EXPIRY, DEFAULT_FEE_BPS);
    uint256 intentId = _createIntent(entryWord);
    vm.startPrank(owner);
    whitelist.setAllowed(address(absoluteCaps), false);
    whitelist.setAllowed(address(dynamicCaps), false);
    vm.stopPrank();

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(absoluteCaps)));
    intents.setDepositCap(intentId, entryWord);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(absoluteCaps)));
    facility.setEntry(address(positionManager), entryWord, FAR_EXPIRY, DEFAULT_FEE_BPS, false);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(absoluteCaps)));
    facility.setExit(address(positionManager), exitWord, uint40(block.timestamp + 1 days), DEFAULT_FEE_BPS);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(dynamicCaps)));
    facility.setSecurityCap(address(underlyingToken), address(debtToken), securityWord);

    (IntentProperties memory props,,,) = intents.getIntent(intentId);
    assertEq(props.depositCap, entryWord, "intent word");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, entryWord, "entry word");
    assertEq(facility.getExit(address(positionManager)).cap, exitWord, "exit word");
    assertEq(facility.getExit(address(positionManager)).expiry, FAR_EXPIRY, "exit expiry");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), securityWord, "security word");

    _depositIntent(intentId, depositor, 1_000e6);
    (uint256 shares,) = _enter(user, 1_000e18, user);
    (, uint256 debtIn) = _exit(user, shares, receiver);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_500e6 + debtIn, "stored words keep consuming");
    assertEq(_dynRemaining(SECURITY_RATE_ID), 500e6, "security");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           PAUSE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pause_inKindByCompliance_leavesIntentsConsuming() public {
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    vm.prank(compliance);
    facility.pauseFor(1 days);

    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);

    _depositIntent(intentId, depositor, 1_000e6);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 1_000e6, "intents consume the pool");
  }

  function test_pause_facilityByCompliance_leavesInKindConsuming() public {
    uint256 intentId = _createIntent(_poolWord(POOL_ID, MULT_1X));
    vm.prank(compliance);
    intents.pauseFor(1 days);

    _fundDepositor(depositor, 1_000e6);
    vm.prank(depositor);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    intents.deposit(intentId, 1_000e6);

    _enter(user, 1_000e18, receiver);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 500e6, "entries consume the pool");
  }

  function test_pause_stopsOffersARevokedFacilitatorCannotClose() public {
    vm.prank(owner);
    facility.revokeRoles(facilitator, FACILITY_FACILITATOR_ROLE);

    vm.prank(facilitator);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setEntry(address(positionManager), 0, 0, 0, false);

    _enter(user, 1_000e18, receiver);
    assertEq(_poolCap(POOL_ID), SHARED_POOL_CAP - 500e6, "the offer stays live");

    vm.prank(compliance);
    facility.pauseFor(type(uint256).max);
    _fundEntrant(user, 1_000e18);
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.enter(address(positionManager), 1_000e18, 0, type(uint256).max, 0, receiver);
  }
}
