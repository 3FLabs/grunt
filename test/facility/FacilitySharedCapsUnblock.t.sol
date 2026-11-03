// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityBaseTest} from "./FacilityBase.t.sol";

import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";

/// @title FacilitySharedCapsUnblockTest
/// @notice Releases blocked by an EXTERNAL cap word and the documented ways to unblock them
contract FacilitySharedCapsUnblockTest is FacilityBaseTest {
  using LibClone for address;

  FacilityAbsoluteCaps public caps;
  FacilityDynamicCaps public timeCaps;

  uint16 constant POOL_ID = 1;
  uint16 constant OTHER_POOL_ID = 2;
  int24 constant MULT_1X = 4096;
  int24 constant MULT_1_5X = 6144;
  uint128 constant POOL_CAP = 10_000e18;
  uint128 constant RECOVERY = 1_000_000e18;
  uint64 constant RECOVERY_TIME = 24 hours;
  uint256 constant CAPS_CONSUMER_ROLE = 1 << 1;

  function setUp() public override {
    super.setUp();

    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    caps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    caps.initialize(owner, managers, consumers);
    timeCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    timeCaps.initialize(owner, managers, consumers);

    vm.warp(vm.getBlockTimestamp() + RECOVERY_TIME);
    vm.startPrank(owner);
    capsWhitelist.setAllowed(address(caps), true);
    capsWhitelist.setAllowed(address(timeCaps), true);
    caps.setCap(POOL_ID, POOL_CAP, POOL_CAP);
    caps.setCap(OTHER_POOL_ID, POOL_CAP, POOL_CAP);
    timeCaps.setCap(POOL_ID, RECOVERY, RECOVERY_TIME, 0);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _createIntent(address capsContract, uint64 capId, int24 multiplier) internal returns (uint256 intentId) {
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositCap = LibCaps.encodeExternal(capsContract, capId, multiplier);
    vm.prank(owner);
    intentId = facility.createIntent(props);
  }

  function _deposit(uint256 intentId, address depositor, uint256 amount) internal {
    _mintDebt(depositor, amount);
    vm.prank(depositor);
    facility.deposit(intentId, amount);
  }

  function _revokeConsumer(address capsContract) internal {
    vm.prank(owner);
    FacilityAbsoluteCaps(capsContract).revokeRoles(address(facility), CAPS_CONSUMER_ROLE);
  }

  function _poolCap(uint16 poolId) internal view returns (uint128 cap) {
    (cap,) = caps.getCap(poolId);
  }

  function _headroom(uint16 poolId) internal view returns (uint256) {
    (uint128 cap, uint128 hardCap) = caps.getCap(poolId);
    return hardCap - cap;
  }

  /// @dev `user` consumes 1000e18 of POOL_ID at +1x, then `user2` credits it back to the hard cap at -1x
  function _fillToHardCap() internal returns (uint256 intentId) {
    intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    uint256 creditIntent = _createIntent(address(caps), POOL_ID, -MULT_1X);
    _deposit(intentId, user, 1000e18);
    _deposit(creditIntent, user2, 1000e18);
    assertEq(_poolCap(POOL_ID), POOL_CAP, "Third party credit should fill the pool");
  }

  function _expectHardCapExceeded(uint64 capId) internal {
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, capId));
  }

  function _resolveStart(uint256 intentId) internal view returns (uint40) {
    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    return props.resolveStart;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONSUMER ROLE REVOKED                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_revertWhenConsumerRevoked() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _revokeConsumer(address(caps));

    _mintDebt(user, 1000e18);
    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.deposit(intentId, 1000e18);
  }

  function test_withdraw_revertWhenConsumerRevoked() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(intentId, user, 1000e18);
    _revokeConsumer(address(caps));

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.withdraw(intentId, user, user, 1000e18);
  }

  function test_revertDeposit_revertWhenConsumerRevoked() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(intentId, user, 1000e18);
    _revokeConsumer(address(caps));

    vm.prank(pauser);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.revertDeposit(intentId, user, user);
  }

  function test_withdraw_dynamicCaps_revertWhenConsumerRevoked() public {
    uint256 intentId = _createIntent(address(timeCaps), POOL_ID, MULT_1X);
    _deposit(intentId, user, 1000e18);
    _revokeConsumer(address(timeCaps));

    // the release is a no-op on FacilityDynamicCaps but still a role-gated call
    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.withdraw(intentId, user, user, 1000e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       UNBLOCK PATHS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdraw_unblockedByZeroWordWhileDepositing() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(intentId, user, 1000e18);
    _revokeConsumer(address(caps));

    vm.prank(facilitator);
    facility.setDepositCap(intentId, 0);
    vm.prank(user);
    facility.withdraw(intentId, user, user, 1000e18);

    assertEq(debtToken.balanceOf(user), 1000e18, "Withdrawal should pay out");
    assertEq(facility.totalSupply(intentId), 0, "Shares should be burned");
    assertEq(_poolCap(POOL_ID), POOL_CAP - 1000e18, "Zero word release should not touch the pool");
  }

  function test_revertDeposit_unblockedByZeroWordWhileResolving() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(intentId, user, 1000e18);
    vm.warp(_resolveStart(intentId));
    assertTrue(_isResolving(intentId), "Intent should be resolving");
    _revokeConsumer(address(caps));

    vm.prank(pauser);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.revertDeposit(intentId, user, user);

    vm.prank(facilitator);
    facility.setDepositCap(intentId, 0);
    vm.prank(pauser);
    facility.revertDeposit(intentId, user, user);

    assertEq(debtToken.balanceOf(user), 1000e18, "Reverted deposit should pay out");
    assertEq(facility.totalSupply(intentId), 0, "Shares should be burned");
    assertEq(_poolCap(POOL_ID), POOL_CAP - 1000e18, "Zero word release should not touch the pool");
  }

  function test_withdraw_unblockedByConsumerRegrant() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1_5X);
    _deposit(intentId, user, 1000e18);
    _revokeConsumer(address(caps));

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.withdraw(intentId, user, user, 1000e18);

    vm.prank(owner);
    caps.grantRoles(address(facility), CAPS_CONSUMER_ROLE);
    vm.prank(user);
    facility.withdraw(intentId, user, user, 1000e18);

    assertEq(debtToken.balanceOf(user), 1000e18, "Withdrawal should pay out");
    assertEq(_poolCap(POOL_ID), POOL_CAP, "Release should give the pool its consumption back");
  }

  function test_withdraw_negativeMultiplier_drainedPoolUnblockedByZeroWord() public {
    vm.prank(owner);
    caps.setCap(POOL_ID, 0, POOL_CAP);
    uint256 exitIntent = _createIntent(address(caps), POOL_ID, -MULT_1X);
    uint256 entryIntent = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(exitIntent, user, 1000e18);
    _deposit(entryIntent, user2, 1000e18);
    assertEq(_poolCap(POOL_ID), 0, "Pool should be drained");

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.withdraw(exitIntent, user, user, 1);

    vm.prank(facilitator);
    facility.setDepositCap(exitIntent, 0);
    vm.prank(user);
    facility.withdraw(exitIntent, user, user, 1000e18);

    assertEq(debtToken.balanceOf(user), 1000e18, "Withdrawal should pay out");
    assertEq(_poolCap(POOL_ID), 0, "Zero word release should not touch the pool");
  }

  function test_withdraw_negativeMultiplier_drainedPoolUnblockedByAdjustCap() public {
    vm.prank(owner);
    caps.setCap(POOL_ID, 0, POOL_CAP);
    uint256 exitIntent = _createIntent(address(caps), POOL_ID, -MULT_1X);
    uint256 entryIntent = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(exitIntent, user, 1000e18);
    _deposit(entryIntent, user2, 1000e18);

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.withdraw(exitIntent, user, user, 1);

    vm.prank(owner);
    caps.adjustCap(POOL_ID, 1000e18);
    vm.prank(user);
    facility.withdraw(exitIntent, user, user, 1000e18);

    assertEq(debtToken.balanceOf(user), 1000e18, "Withdrawal should pay out");
    assertEq(_poolCap(POOL_ID), 0, "Withdrawal should consume the added capacity");
  }

  function test_withdraw_negativeMultiplier_drainedPoolUnblockedBySetCap() public {
    vm.prank(owner);
    caps.setCap(POOL_ID, 0, POOL_CAP);
    uint256 exitIntent = _createIntent(address(caps), POOL_ID, -MULT_1X);
    uint256 entryIntent = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(exitIntent, user, 1000e18);
    _deposit(entryIntent, user2, 1000e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.withdraw(exitIntent, user, user, 1);

    vm.prank(owner);
    caps.setCap(POOL_ID, 1000e18, POOL_CAP);
    vm.prank(user);
    facility.withdraw(exitIntent, user, user, 1000e18);

    assertEq(debtToken.balanceOf(user), 1000e18, "Withdrawal should pay out");
    assertEq(_poolCap(POOL_ID), 0, "Withdrawal should consume the restored capacity");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HARD CAP                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdraw_revertHardCapExceededWhenThirdPartyFillsPool() public {
    uint256 intentId = _fillToHardCap();

    vm.prank(user);
    _expectHardCapExceeded(POOL_ID);
    facility.withdraw(intentId, user, user, 1);

    vm.prank(pauser);
    _expectHardCapExceeded(POOL_ID);
    facility.revertDeposit(intentId, user, user);

    assertEq(facility.balanceOf(user, intentId), 1000e18, "Shares should stay");
    assertEq(debtToken.balanceOf(user), 0, "Nothing should pay out");
  }

  function test_withdraw_revertHardCapExceededAfterWiderWordRoundTrip() public {
    vm.startPrank(owner);
    caps.setCap(POOL_ID, 1000e18, 1000e18);
    caps.setCap(OTHER_POOL_ID, 2000e18, 2000e18);
    vm.stopPrank();
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    uint256 wideIntent = _createIntent(address(caps), uint64(POOL_ID) | (uint64(OTHER_POOL_ID) << 16), MULT_1X);
    _deposit(intentId, user, 600e18);

    _deposit(wideIntent, user2, 1400e18);
    vm.prank(user2);
    facility.withdraw(wideIntent, user2, user2, 1400e18);
    assertEq(_poolCap(POOL_ID), 1000e18, "Release should refill the first pool");
    assertEq(_poolCap(OTHER_POOL_ID), 1400e18, "Second pool should keep the consumption nobody owes");

    vm.prank(user);
    _expectHardCapExceeded(POOL_ID);
    facility.withdraw(intentId, user, user, 600e18);

    vm.startPrank(owner);
    caps.setCap(POOL_ID, 400e18, 1000e18);
    caps.setCap(OTHER_POOL_ID, 2000e18, 2000e18);
    vm.stopPrank();
    vm.prank(user);
    facility.withdraw(intentId, user, user, 600e18);

    assertEq(debtToken.balanceOf(user), 600e18, "Withdrawal should pay out");
    assertEq(_poolCap(POOL_ID), 1000e18, "Reconciled pool should take the release");
  }

  function test_withdraw_hardCapNotUnblockedByAdjustCap() public {
    uint256 intentId = _fillToHardCap();

    vm.prank(owner);
    caps.adjustCap(POOL_ID, 5000e18);
    assertEq(_headroom(POOL_ID), 0, "Growing should keep the headroom");
    vm.prank(user);
    _expectHardCapExceeded(POOL_ID);
    facility.withdraw(intentId, user, user, 1);

    vm.prank(owner);
    caps.adjustCap(POOL_ID, -10_000e18);
    assertEq(_headroom(POOL_ID), 0, "Shrinking should keep the headroom");
    vm.prank(user);
    _expectHardCapExceeded(POOL_ID);
    facility.withdraw(intentId, user, user, 1);

    vm.prank(owner);
    caps.adjustCap(POOL_ID, -int256(uint256(2 * POOL_CAP)));
    assertEq(_headroom(POOL_ID), 0, "Shrinking to zero should keep the headroom");
    vm.prank(pauser);
    _expectHardCapExceeded(POOL_ID);
    facility.revertDeposit(intentId, user, user);
  }

  function test_withdraw_hardCapUnblockedBySetCap() public {
    uint256 intentId = _fillToHardCap();
    vm.prank(user);
    _expectHardCapExceeded(POOL_ID);
    facility.withdraw(intentId, user, user, 1000e18);

    vm.prank(owner);
    caps.setCap(POOL_ID, POOL_CAP, POOL_CAP + 1000e18);
    vm.prank(user);
    facility.withdraw(intentId, user, user, 1000e18);

    assertEq(debtToken.balanceOf(user), 1000e18, "Withdrawal should pay out");
    assertEq(_poolCap(POOL_ID), POOL_CAP + 1000e18, "Release should use the raised hard cap");
  }

  function test_revertDeposit_hardCapWhileResolvingUnblockedBySetCap() public {
    uint256 intentId = _fillToHardCap();
    vm.warp(_resolveStart(intentId));
    assertTrue(_isResolving(intentId), "Intent should be resolving");

    vm.prank(pauser);
    _expectHardCapExceeded(POOL_ID);
    facility.revertDeposit(intentId, user, user);

    vm.prank(owner);
    caps.setCap(POOL_ID, POOL_CAP - 1000e18, POOL_CAP);
    vm.prank(pauser);
    facility.revertDeposit(intentId, user, user);

    assertEq(debtToken.balanceOf(user), 1000e18, "Reverted deposit should pay out");
    assertEq(_poolCap(POOL_ID), POOL_CAP, "Release should fill the lowered pool");
  }

  function testFuzz_withdraw_revertHardCapExceededAboveHeadroom(uint256 consumed, uint256 credited, uint256 amount)
    public
  {
    consumed = bound(consumed, 1, POOL_CAP);
    credited = bound(credited, 0, consumed);
    amount = bound(amount, 1, consumed);
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(intentId, user, consumed);
    if (credited > 0) _deposit(_createIntent(address(caps), POOL_ID, -MULT_1X), user2, credited);
    uint256 poolBefore = _poolCap(POOL_ID);

    vm.prank(user);
    if (amount > consumed - credited) {
      _expectHardCapExceeded(POOL_ID);
      facility.withdraw(intentId, user, user, amount);
      assertEq(_poolCap(POOL_ID), poolBefore, "Reverted release should leave the pool");
      return;
    }
    facility.withdraw(intentId, user, user, amount);
    assertEq(_poolCap(POOL_ID), poolBefore + amount, "Release should credit the pool");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        WORD SWITCH                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setDepositCap_switchProcedure() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(intentId, user, 1000e18);

    vm.prank(facilitator);
    facility.setDepositCap(intentId, 0);
    vm.prank(user);
    facility.withdraw(intentId, user, user, 1000e18);
    assertEq(facility.totalSupply(intentId), 0, "Outstanding shares should have exited");

    vm.prank(facilitator);
    facility.setDepositCap(intentId, LibCaps.encodeExternal(address(caps), OTHER_POOL_ID, MULT_1X));
    _deposit(intentId, user2, 500e18);
    assertEq(_poolCap(OTHER_POOL_ID), POOL_CAP - 500e18, "New word should consume its own pool");
    vm.prank(user2);
    facility.withdraw(intentId, user2, user2, 500e18);

    assertEq(_poolCap(OTHER_POOL_ID), POOL_CAP, "New word round trip should restore its pool");
    assertEq(_poolCap(POOL_ID), POOL_CAP - 1000e18, "Exits under the zero word leave the old pool debited");

    vm.prank(owner);
    caps.adjustCap(POOL_ID, 1000e18);
    assertEq(_headroom(POOL_ID), 1000e18, "adjustCap should keep the stranded consumption");

    vm.prank(owner);
    caps.setCap(POOL_ID, POOL_CAP, POOL_CAP);
    assertEq(_headroom(POOL_ID), 0, "setCap should reconcile the old pool");
    uint256 next = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(next, user, POOL_CAP);
    assertEq(_poolCap(POOL_ID), 0, "Reconciled pool should serve its full cap");
  }

  function test_setDepositCap_switchNegativeWordThenReconcileWithSetCap() public {
    vm.prank(owner);
    caps.setCap(POOL_ID, 5000e18, POOL_CAP);
    uint256 exitIntent = _createIntent(address(caps), POOL_ID, -MULT_1X);
    _deposit(exitIntent, user, 1000e18);
    assertEq(_poolCap(POOL_ID), 6000e18, "Deposit should credit the pool");

    vm.prank(facilitator);
    facility.setDepositCap(exitIntent, 0);
    vm.prank(user);
    facility.withdraw(exitIntent, user, user, 1000e18);
    assertEq(caps.available(POOL_ID, MULT_1X), 6000e18, "Exits under the zero word leave the credit for anyone");

    vm.prank(owner);
    caps.setCap(POOL_ID, 5000e18, POOL_CAP);
    (uint128 cap, uint128 hardCap) = caps.getCap(POOL_ID);
    assertEq(cap, 5000e18, "setCap should drop the stranded credit");
    assertEq(hardCap, POOL_CAP, "setCap should keep the hard cap");

    uint256 entryIntent = _createIntent(address(caps), POOL_ID, MULT_1X);
    _mintDebt(user2, 5000e18 + 1);
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.deposit(entryIntent, 5000e18 + 1);
  }

  function test_withdraw_releasesIntoCurrentWord() public {
    uint256 intentId = _createIntent(address(caps), POOL_ID, MULT_1X);
    _deposit(intentId, user, 1000e18);
    vm.prank(facilitator);
    facility.setDepositCap(intentId, LibCaps.encodeExternal(address(caps), OTHER_POOL_ID, MULT_1X));

    vm.prank(user);
    _expectHardCapExceeded(OTHER_POOL_ID);
    facility.withdraw(intentId, user, user, 400e18);

    vm.prank(owner);
    caps.setCap(OTHER_POOL_ID, 5000e18, POOL_CAP);
    vm.prank(user);
    facility.withdraw(intentId, user, user, 400e18);

    assertEq(_poolCap(OTHER_POOL_ID), 5400e18, "Release should credit the current word's pool");
    assertEq(_poolCap(POOL_ID), POOL_CAP - 1000e18, "Release should not credit the pool that was consumed");
  }
}
