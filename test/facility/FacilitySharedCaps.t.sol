// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityBaseTest} from "./FacilityBase.t.sol";

import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title FacilitySharedCapsTest
/// @notice Tests consumption of EXTERNAL deposit caps by the facility, against both
///         FacilityAbsoluteCaps pools and FacilityDynamicCaps time-weighted caps
contract FacilitySharedCapsTest is FacilityBaseTest {
  using LibClone for address;

  FacilityAbsoluteCaps public caps;
  FacilityDynamicCaps public timeCaps;

  uint32 constant POOL_ID = 1;
  uint32 constant UNSET_ID = 99;
  // Q12.12 multipliers
  int24 constant MULT_1X = 4096;
  int24 constant MULT_1_5X = 6144;
  int24 constant MULT_9X = 36864;

  uint128 constant POOL_CAP = 10_000e18;
  uint128 constant RECOVERY = 1_000_000e18;
  uint64 constant RECOVERY_TIME = 24 hours;

  function setUp() public override {
    super.setUp();

    caps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    caps.initialize(owner, managers, consumers);
    vm.label(address(caps), "FacilityAbsoluteCaps");

    timeCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    timeCaps.initialize(owner, managers, consumers);
    vm.label(address(timeCaps), "FacilityDynamicCaps");

    vm.startPrank(owner);
    capsWhitelist.setAllowed(address(caps), true);
    capsWhitelist.setAllowed(address(timeCaps), true);
    vm.stopPrank();

    _setPool(POOL_CAP, POOL_CAP);
    // the fixture starts near timestamp zero, move past one recovery period so a zero origin is fully recovered
    vm.warp(block.timestamp + RECOVERY_TIME);
    vm.prank(owner);
    timeCaps.setCap(POOL_ID, RECOVERY, RECOVERY_TIME, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _setPool(uint128 cap, uint128 hardCap) internal {
    vm.prank(owner);
    caps.setCap(POOL_ID, cap, hardCap);
  }

  function _poolCap() internal view returns (uint128 cap) {
    (cap,) = caps.getCap(POOL_ID);
  }

  /// @notice Creates a debtToken-deposit intent whose cap points at the shared pool
  function _createPoolIntent(int24 multiplier) internal returns (uint256 intentId) {
    return _createIntentWithCaps(address(caps), multiplier);
  }

  /// @notice Creates a debtToken-deposit intent whose cap points at the time-weighted cap
  function _createTimeCapIntent(int24 multiplier) internal returns (uint256 intentId) {
    return _createIntentWithCaps(address(timeCaps), multiplier);
  }

  /// @notice Creates a debtToken-deposit intent with the default absolute cap
  function _createAbsoluteIntent() internal returns (uint256 intentId) {
    vm.prank(owner);
    intentId = facility.createIntent(_intentParamsWithTargetPM());
  }

  function _createIntentWithCaps(address capsContract, int24 multiplier) internal returns (uint256 intentId) {
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositCap = LibCaps.encodeExternal(capsContract, POOL_ID, multiplier);
    vm.prank(owner);
    intentId = facility.createIntent(props);
  }

  function _deposit(uint256 intentId, address depositor, uint256 amount) internal {
    _mintDebt(depositor, amount);
    vm.prank(depositor);
    facility.deposit(intentId, amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSUMPTION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_absoluteCap_decrementsAndRestores() public {
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_intentParamsWithTargetPM());

    _deposit(intentId, user, 1000e18);
    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.depositCap, DEFAULT_DEPOSIT_CAP - 1000e18, "Absolute cap should decrement on deposit");

    vm.prank(user);
    facility.withdraw(intentId, user, user, 400e18);
    (props,,,) = facility.getIntent(intentId);
    assertEq(props.depositCap, DEFAULT_DEPOSIT_CAP - 600e18, "Absolute cap should restore on withdrawal");
  }

  function test_deposit_externalCap_consumesSharedPool() public {
    uint256 intentId = _createPoolIntent(MULT_1_5X);

    _deposit(intentId, user, 1000e18);
    assertEq(_poolCap(), POOL_CAP - 1500e18, "Pool should shrink by amount x multiplier");
    assertEq(facility.balanceOf(user, intentId), 1000e18, "LP tokens still minted 1:1");

    // consumption rounds up in favor of the pool: 1 wei x 1.5 -> 2
    _deposit(intentId, user, 1);
    assertEq(_poolCap(), POOL_CAP - 1500e18 - 2, "Consumption should round up");
  }

  function test_deposit_externalCap_sharedAcrossIntents() public {
    uint256 leveredIntent = _createPoolIntent(MULT_9X);
    uint256 plainIntent = _createPoolIntent(MULT_1X);

    // 1000 at 9x consumes 9000 of the shared pool
    _deposit(leveredIntent, user, 1000e18);
    assertEq(_poolCap(), 1000e18, "Levered deposit should consume 9x");

    // only 1000 left for the 1x intent
    _mintDebt(user2, 1001e18);
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.deposit(plainIntent, 1001e18);

    _deposit(plainIntent, user2, 1000e18);
    assertEq(_poolCap(), 0, "Pool should be fully consumed");
  }

  function test_withdraw_externalCap_releasesPool() public {
    uint256 intentId = _createPoolIntent(MULT_1_5X);

    _deposit(intentId, user, 1000e18);
    assertEq(_poolCap(), POOL_CAP - 1500e18, "Deposit should consume the pool");

    vm.prank(user);
    facility.withdraw(intentId, user, user, 500e18);
    assertEq(_poolCap(), POOL_CAP - 1500e18 + 750e18, "Withdrawal should release amount x multiplier");
    assertEq(debtToken.balanceOf(user), 500e18, "Deposit asset should be returned");

    // release rounds down in favor of the pool: 1 wei x 1.5 -> 1
    vm.prank(user);
    facility.withdraw(intentId, user, user, 1);
    assertEq(_poolCap(), POOL_CAP - 1500e18 + 750e18 + 1, "Release should round down");
  }

  function test_deposit_externalCap_negativeMultiplier() public {
    // withdrawal-side intent: deposits release capacity into the pool instead of consuming it
    uint256 intentId = _createPoolIntent(-MULT_1X);
    _setPool(0, 5000e18);

    _deposit(intentId, user, 3000e18);
    assertEq(_poolCap(), 3000e18, "Deposit should release capacity into the pool");

    // releasing above the hard cap reverts
    _mintDebt(user, 2001e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.HardCapExceeded.selector, POOL_ID));
    facility.deposit(intentId, 2001e18);

    // withdrawing re-consumes the released capacity
    vm.prank(user);
    facility.withdraw(intentId, user, user, 1000e18);
    assertEq(_poolCap(), 2000e18, "Withdrawal should re-consume the released capacity");
  }

  function test_revertDeposit_externalCap_releasesPool() public {
    uint256 intentId = _createPoolIntent(MULT_1X);

    _deposit(intentId, user, 4000e18);
    assertEq(_poolCap(), POOL_CAP - 4000e18, "Deposit should consume the pool");

    vm.prank(pauser);
    facility.revertDeposit(intentId, user, user);

    assertEq(_poolCap(), POOL_CAP, "Reverted deposit should release its consumption");
    assertEq(facility.balanceOf(user, intentId), 0, "Shares should be burned");
    assertEq(debtToken.balanceOf(user), 4000e18, "Deposit asset should be returned");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     TIME-WEIGHTED CAPS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_timeCap_consumesThroughput() public {
    uint256 intentId = _createTimeCapIntent(MULT_1_5X);

    // 400k at 1.5x consumes 600k of the 1m per day
    _deposit(intentId, user, 400_000e18);
    assertEq(timeCaps.remaining(POOL_ID), 400_000e18, "Deposit should consume amount x multiplier");
    assertEq(facility.balanceOf(user, intentId), 400_000e18, "LP tokens still minted 1:1");

    // 300k at 1.5x needs 450k, more than what is left
    _mintDebt(user2, 300_000e18);
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.deposit(intentId, 300_000e18);

    // half a day recovers 500k, capped at 1m
    vm.warp(block.timestamp + 12 hours);
    assertEq(timeCaps.remaining(POOL_ID), 900_000e18, "Capacity should recover over time");
    _deposit(intentId, user2, 300_000e18);
    assertEq(timeCaps.remaining(POOL_ID), 450_000e18, "Recovered capacity should be consumable");
  }

  function test_deposit_timeCap_sharedAcrossIntentsAndFacilityRate() public {
    uint256 leveredIntent = _createTimeCapIntent(MULT_9X);
    uint256 plainIntent = _createTimeCapIntent(MULT_1X);

    _deposit(leveredIntent, user, 100_000e18);
    assertEq(timeCaps.remaining(POOL_ID), 100_000e18, "Levered deposit should consume 9x");

    _mintDebt(user2, 100_001e18);
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.deposit(plainIntent, 100_001e18);

    _deposit(plainIntent, user2, 100_000e18);
    assertEq(timeCaps.remaining(POOL_ID), 0, "Cap should be fully consumed");
  }

  function test_withdraw_timeCap_doesNotRelease() public {
    uint256 intentId = _createTimeCapIntent(MULT_1X);

    _deposit(intentId, user, 500_000e18);
    assertEq(timeCaps.remaining(POOL_ID), 500_000e18, "Deposit should consume the cap");

    vm.prank(user);
    facility.withdraw(intentId, user, user, 500_000e18);
    assertEq(timeCaps.remaining(POOL_ID), 500_000e18, "Withdrawal should not give capacity back");
    assertEq(debtToken.balanceOf(user), 500_000e18, "Deposit asset should be returned");
  }

  function test_revertDeposit_timeCap_doesNotRelease() public {
    uint256 intentId = _createTimeCapIntent(MULT_1X);

    _deposit(intentId, user, 500_000e18);
    vm.prank(pauser);
    facility.revertDeposit(intentId, user, user);

    assertEq(timeCaps.remaining(POOL_ID), 500_000e18, "Reverted deposit should not give capacity back");
    assertEq(facility.balanceOf(user, intentId), 0, "Shares should be burned");
    assertEq(debtToken.balanceOf(user), 500_000e18, "Deposit asset should be returned");
  }

  function test_deposit_timeCap_negativeMultiplierLimitsWithdrawals() public {
    // withdrawal-side intent: deposits are free, withdrawals consume the throughput
    uint256 intentId = _createTimeCapIntent(-MULT_1X);

    _deposit(intentId, user, 3_000_000e18);
    assertEq(timeCaps.remaining(POOL_ID), RECOVERY, "Deposit should not touch the cap");

    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, POOL_ID));
    facility.withdraw(intentId, user, user, RECOVERY + 1);

    vm.prank(user);
    facility.withdraw(intentId, user, user, RECOVERY);
    assertEq(timeCaps.remaining(POOL_ID), 0, "Withdrawal should consume the cap");

    vm.warp(block.timestamp + 6 hours);
    vm.prank(user);
    facility.withdraw(intentId, user, user, RECOVERY / 4);
    assertEq(timeCaps.remaining(POOL_ID), 0, "Recovered capacity should be withdrawable");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CAP MANAGEMENT                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_absoluteCap_partialFillErrorArgs() public {
    uint256 intentId = _createAbsoluteIntent();
    vm.prank(facilitator);
    facility.setDepositCap(intentId, 1000e18);

    _deposit(intentId, user, 600e18);

    // the error reports the remaining capacity and the attempted amount
    _mintDebt(user, 500e18);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.DepositCapExceeded.selector, intentId, 400e18, 500e18));
    facility.deposit(intentId, 500e18);
  }

  function test_setDepositCap_absoluteZeroRegrowsOnWithdraw() public {
    uint256 intentId = _createAbsoluteIntent();
    _deposit(intentId, user, 1000e18);

    vm.prank(facilitator);
    facility.setDepositCap(intentId, 0);
    _mintDebt(user2, 1e18);
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.DepositCapExceeded.selector, intentId, 0, 1e18));
    facility.deposit(intentId, 1e18);

    // a withdrawal regrows the zero word, reopening room for deposits
    vm.prank(user);
    facility.withdraw(intentId, user, user, 600e18);
    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.depositCap, 600e18, "Zero absolute cap should regrow on withdrawal");
    _deposit(intentId, user2, 600e18);
  }

  function test_setDepositCap_closeViaDynamicCaps() public {
    uint256 intentId = _createAbsoluteIntent();
    _deposit(intentId, user, 1000e18);

    // an unset FacilityDynamicCaps ID has zero recovery: deposits revert, releases are no-ops
    vm.prank(facilitator);
    facility.setDepositCap(intentId, LibCaps.encodeExternal(address(timeCaps), UNSET_ID, MULT_1X));

    _mintDebt(user2, 1e18);
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, UNSET_ID));
    facility.deposit(intentId, 1e18);

    vm.prank(user);
    facility.withdraw(intentId, user, user, 400e18);
    assertEq(debtToken.balanceOf(user), 400e18, "Withdrawal should still work");

    vm.prank(pauser);
    facility.revertDeposit(intentId, user, user);
    assertEq(debtToken.balanceOf(user), 1000e18, "Revert deposit should still work");
    assertEq(timeCaps.remaining(UNSET_ID), 0, "Closed cap should stay closed");

    // still closed after the exits, unlike a zero absolute word
    vm.prank(user2);
    vm.expectRevert(abi.encodeWithSelector(IFacilityCaps.InsufficientCap.selector, UNSET_ID));
    facility.deposit(intentId, 1e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         VALIDATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_capsWhitelist_disallowKeepsExistingIntents() public {
    uint256 intentId = _createPoolIntent(MULT_1X);
    _deposit(intentId, user, 1000e18);

    vm.prank(owner);
    capsWhitelist.setAllowed(address(caps), false);

    // existing words keep consuming and releasing
    _deposit(intentId, user, 1000e18);
    assertEq(_poolCap(), POOL_CAP - 2000e18, "Existing intent should keep consuming the pool");
    vm.prank(user);
    facility.withdraw(intentId, user, user, 500e18);
    assertEq(_poolCap(), POOL_CAP - 1500e18, "Existing intent should keep releasing to the pool");

    // new words pointing at the contract are rejected
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositCap = LibCaps.encodeExternal(address(caps), POOL_ID, MULT_1X);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(caps)));
    facility.createIntent(props);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(caps)));
    facility.setDepositCap(intentId, LibCaps.encodeExternal(address(caps), POOL_ID, MULT_1_5X));
  }

  function test_setDepositCap_revertOnInvalidEncoding() public {
    uint256 intentId = _createDefaultIntent();

    // unknown type byte
    uint256 unknownType = uint256(2) << 248;
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, unknownType));
    facility.setDepositCap(intentId, unknownType);

    // external cap pointing at an address the whitelist does not allow
    address eoa = makeAddr("eoa");
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, eoa));
    facility.setDepositCap(intentId, LibCaps.encodeExternal(eoa, POOL_ID, MULT_1X));

    // a real caps contract that is not whitelisted is rejected the same way
    address rogue = address(new FacilityAbsoluteCaps());
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, rogue));
    facility.setDepositCap(intentId, LibCaps.encodeExternal(rogue, POOL_ID, MULT_1X));

    // non-zero unused bits
    uint256 dirtyWord = LibCaps.encodeExternal(address(caps), POOL_ID, MULT_1X) | (uint256(1) << 216);
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, dirtyWord));
    facility.setDepositCap(intentId, dirtyWord);

    // type(int24).min multiplier has no int24 negation, so it could never be released
    uint256 minMultiplier = LibCaps.encodeExternal(address(caps), POOL_ID, type(int24).min);
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, minMultiplier));
    facility.setDepositCap(intentId, minMultiplier);
  }
}
