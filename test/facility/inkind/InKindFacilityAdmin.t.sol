// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Vm} from "forge-std/Test.sol";
import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {InKindFacility} from "src/facility/inkind/InKindFacility.sol";
import {IInKindFacility} from "src/interfaces/facility/IInKindFacility.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title InKindFacilityAdminTest
/// @notice Initializer, ownership, role, pause and setter-validation edge cases of InKindFacility.
contract InKindFacilityAdminTest is InKindFacilityBaseTest {
  using LibClone for address;

  uint256 constant FACILITY_ROLE_1 = 1 << 1;

  address stranger;

  function setUp() public override {
    super.setUp();
    stranger = makeAddr("stranger");
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _openOffers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INITIALIZE                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_emitsOwnerRoleAndFeeRecipientInOrder() public {
    InKindFacility fresh = InKindFacility(address(implementation).clone());
    vm.expectEmit(true, true, true, true, address(fresh));
    emit Ownable.OwnershipTransferred(address(0), owner);
    vm.expectEmit(true, true, true, true, address(fresh));
    emit OwnableRoles.RolesUpdated(facilitator, FACILITY_FACILITATOR_ROLE);
    vm.expectEmit(true, true, true, true, address(fresh));
    emit IInKindFacility.FeeRecipientSet(feeRecipient);
    vm.expectEmit(true, true, true, true, address(fresh));
    emit Initializable.Initialized(1);
    fresh.initialize(owner, facilitator, feeRecipient);
  }

  function test_initialize_zeroFacilitatorGrantsNoRole() public {
    InKindFacility fresh = InKindFacility(address(implementation).clone());
    vm.recordLogs();
    fresh.initialize(owner, address(0), feeRecipient);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    assertEq(fresh.rolesOf(address(0)), 0, "role granted to the zero address");
    assertEq(logs.length, 3, "log count");
    assertEq(logs[0].topics[0], Ownable.OwnershipTransferred.selector, "first log");
    assertEq(logs[1].topics[0], IInKindFacility.FeeRecipientSet.selector, "second log");
    assertEq(logs[2].topics[0], Initializable.Initialized.selector, "third log");
  }

  function test_initialize_ownerIsTheArgumentNotTheCaller() public {
    InKindFacility fresh = InKindFacility(address(implementation).clone());
    vm.prank(stranger);
    fresh.initialize(owner, facilitator, feeRecipient);
    assertEq(fresh.owner(), owner, "owner");
    assertEq(fresh.rolesOf(stranger), 0, "caller got roles");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     OWNERSHIP AND ROLES                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_grantRoles_role1GrantsNoSetterPower() public {
    vm.prank(owner);
    facility.grantRoles(stranger, FACILITY_ROLE_1);

    vm.startPrank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setEntry(address(positionManager), 1e6, FAR_EXPIRY, 0, false);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setExit(address(positionManager), 1e6, FAR_EXPIRY, 0);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setSecurityCap(address(underlyingToken), address(debtToken), 1e6);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setAuth(address(underlyingToken), address(debtToken), user, 1e6, FAR_EXPIRY);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setFeeRecipient(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.pauseFor(1 days);
    vm.stopPrank();
  }

  function test_renounceOwnership_locksTheFeeRecipient() public {
    vm.prank(owner);
    facility.renounceOwnership();

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setFeeRecipient(stranger);
    (address recipient,,) = facility.config();
    assertEq(recipient, feeRecipient, "fee recipient changed");
  }

  function test_transferOwnership_movesOwnerOnlyPower() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    facility.transferOwnership(newOwner);

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setFeeRecipient(stranger);

    vm.prank(newOwner);
    facility.setFeeRecipient(stranger);
    (address recipient,,) = facility.config();
    assertEq(recipient, stranger, "fee recipient");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           PAUSE                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pauseFor_permanentPauseNeverLapses() public {
    vm.prank(owner);
    facility.pauseFor(type(uint256).max);
    vm.warp(uint256(type(uint40).max) - 1);

    (, bool isPaused, uint40 pausedUntil) = facility.config();
    assertTrue(isPaused, "lapsed");
    assertEq(pausedUntil, type(uint40).max, "pausedUntil");
  }

  function test_pauseFor_zeroEmitsTheUnpause() public {
    vm.prank(compliance);
    facility.pauseFor(1 days);

    vm.prank(compliance);
    vm.expectEmit(true, true, true, true, address(facility));
    emit IInKindFacility.InKindFacilityPausedSet(0);
    facility.pauseFor(0);

    (, bool isPaused, uint40 pausedUntil) = facility.config();
    assertFalse(isPaused, "paused");
    assertEq(pausedUntil, 0, "pausedUntil");
  }

  function test_pauseFor_complianceLiftsAnOwnerPermanentPause() public {
    vm.prank(owner);
    facility.pauseFor(type(uint256).max);

    vm.prank(compliance);
    facility.pauseFor(0);

    (, bool isPaused, uint40 pausedUntil) = facility.config();
    assertFalse(isPaused, "paused");
    assertEq(pausedUntil, 0, "pausedUntil");
  }

  function test_pauseFor_winsOverUnknownOffers() public {
    vm.prank(compliance);
    facility.pauseFor(1 days);
    address pm2 = address(positionManager2);

    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.previewEnter(pm2, 1_000e18);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.maxEnter(pm2, user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.previewExit(pm2, 1e18);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.maxExit(pm2);
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.enter(pm2, 1_000e18, 0, type(uint256).max, 0, receiver);
    vm.prank(user);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.exit(pm2, 1e18, type(uint256).max, 0, receiver, "");
  }

  function test_pauseFor_settersStayOpenWhilePaused() public {
    vm.prank(owner);
    facility.pauseFor(type(uint256).max);
    uint40 expiry = uint40(vm.getBlockTimestamp() + 1 days);

    _setEntry(positionManager, 1e6, expiry, 1);
    _setExit(positionManager, 2e6, expiry, 2);
    _setSecurityCap(3e6);
    _setAuth(user, 4e6, expiry);
    vm.prank(owner);
    facility.setFeeRecipient(stranger);

    assertEq(facility.getEntry(address(positionManager)).capacityCap, 1e6, "entry");
    assertEq(facility.getExit(address(positionManager)).cap, 2e6, "exit");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 3e6, "security cap");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 4e6, "auth");
    (address recipient, bool isPaused,) = facility.config();
    assertEq(recipient, stranger, "fee recipient");
    assertTrue(isPaused, "unpaused by a setter");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SETTER VALIDATION                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setEntryAndExit_disablingStillValidatesThePositionManager() public {
    address eoa = makeAddr("eoaPm");
    vm.startPrank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InvalidPositionManager.selector, eoa));
    facility.setEntry(eoa, 0, 0, 0, false);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.InvalidPositionManager.selector, eoa));
    facility.setExit(eoa, 0, 0, 0);
    vm.stopPrank();
  }

  function test_setSecurityCap_overwritesTheRemainingAmount() public {
    _setSecurityCap(1_000e6);
    (, uint256 first) = _enter(user, 2_000e18, receiver);
    assertEq(first, 1_000e6, "first debt");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 0, "drained");

    _setSecurityCap(300e6);
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 300e6, "overwritten");
    (, uint256 second) = _enter(user, 600e18, receiver);
    assertEq(second, 300e6, "second debt");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 0, "drained again");
  }

  function test_setAuth_overwritesTheRemainingAmount() public {
    _setSecurityCap(0);
    _setAuth(user, 600e6, FAR_EXPIRY);
    (, uint256 first) = _enter(user, 1_200e18, receiver);
    assertEq(first, 600e6, "first debt");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "drained");

    _setAuth(user, 200e6, FAR_EXPIRY);
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 200e6, "overwritten");
    (, uint256 second) = _enter(user, 400e18, receiver);
    assertEq(second, 200e6, "second debt");
    assertEq(facility.getAuth(address(underlyingToken), address(debtToken), user).amount, 0, "drained again");
  }

  function test_setEntryAndSecurityCap_multiplierSignBoundary() public {
    uint256 smallest = _externalWord(address(absoluteCaps), POOL_ID, 1);
    uint256 minusOne = _externalWord(address(absoluteCaps), POOL_ID, -1);

    _setEntry(positionManager, smallest, FAR_EXPIRY, 0);
    _setSecurityCap(smallest);
    assertEq(facility.getEntry(address(positionManager)).capacityCap, smallest, "entry word");
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), smallest, "security word");

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonConsumingCap.selector, minusOne));
    facility.setEntry(address(positionManager), minusOne, FAR_EXPIRY, 0, false);
    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(IInKindFacility.NonConsumingCap.selector, minusOne));
    facility.setSecurityCap(address(underlyingToken), address(debtToken), minusOne);
  }
}
