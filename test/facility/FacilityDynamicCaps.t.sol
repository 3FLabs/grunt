// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityBaseTest} from "./FacilityBase.t.sol";

import {FacilityCaps} from "src/facility/caps/FacilityCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title FacilityDynamicCapsTest
/// @notice Tests consumption of DYNAMIC shared deposit caps (FacilityCaps pools) by the facility
contract FacilityDynamicCapsTest is FacilityBaseTest {
  using LibClone for address;

  FacilityCaps public caps;

  uint32 constant POOL_ID = 1;
  // Q12.12 multipliers
  int24 constant MULT_1X = 4096;
  int24 constant MULT_1_5X = 6144;
  int24 constant MULT_9X = 36864;

  uint128 constant POOL_CAP = 10_000e18;

  function setUp() public override {
    super.setUp();

    caps = FacilityCaps(address(new FacilityCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    caps.initialize(owner, managers, consumers);
    vm.label(address(caps), "FacilityCaps");

    _setPool(POOL_CAP, POOL_CAP);
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
  function _createDynamicIntent(int24 multiplier) internal returns (uint256 intentId) {
    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositCap = LibCaps.encodeDynamic(address(caps), POOL_ID, multiplier);
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

  function test_deposit_dynamicCap_consumesSharedPool() public {
    uint256 intentId = _createDynamicIntent(MULT_1_5X);

    _deposit(intentId, user, 1000e18);
    assertEq(_poolCap(), POOL_CAP - 1500e18, "Pool should shrink by amount x multiplier");
    assertEq(facility.balanceOf(user, intentId), 1000e18, "LP tokens still minted 1:1");

    // consumption rounds up in favor of the pool: 1 wei x 1.5 -> 2
    _deposit(intentId, user, 1);
    assertEq(_poolCap(), POOL_CAP - 1500e18 - 2, "Consumption should round up");
  }

  function test_deposit_dynamicCap_sharedAcrossIntents() public {
    uint256 leveredIntent = _createDynamicIntent(MULT_9X);
    uint256 plainIntent = _createDynamicIntent(MULT_1X);

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

  function test_withdraw_dynamicCap_releasesPool() public {
    uint256 intentId = _createDynamicIntent(MULT_1_5X);

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

  function test_deposit_dynamicCap_negativeMultiplier() public {
    // withdrawal-side intent: deposits release capacity into the pool instead of consuming it
    uint256 intentId = _createDynamicIntent(-MULT_1X);
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

  function test_revertDeposit_dynamicCap_releasesPool() public {
    uint256 intentId = _createDynamicIntent(MULT_1X);

    _deposit(intentId, user, 4000e18);
    assertEq(_poolCap(), POOL_CAP - 4000e18, "Deposit should consume the pool");

    vm.prank(pauser);
    facility.revertDeposit(intentId, user, user);

    assertEq(_poolCap(), POOL_CAP, "Reverted deposit should release its consumption");
    assertEq(facility.balanceOf(user, intentId), 0, "Shares should be burned");
    assertEq(debtToken.balanceOf(user), 4000e18, "Deposit asset should be returned");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         VALIDATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setDepositCap_revertOnInvalidEncoding() public {
    uint256 intentId = _createDefaultIntent();

    // unknown type byte
    uint256 unknownType = uint256(2) << 248;
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, unknownType));
    facility.setDepositCap(intentId, unknownType);

    // dynamic cap pointing at a codeless address (consume() would silently succeed)
    address eoa = makeAddr("eoa");
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, eoa));
    facility.setDepositCap(intentId, LibCaps.encodeDynamic(eoa, POOL_ID, MULT_1X));

    // non-zero unused bits
    uint256 dirtyWord = LibCaps.encodeDynamic(address(caps), POOL_ID, MULT_1X) | (uint256(1) << 216);
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, dirtyWord));
    facility.setDepositCap(intentId, dirtyWord);

    // type(int24).min multiplier has no int24 negation, so it could never be released
    uint256 minMultiplier = LibCaps.encodeDynamic(address(caps), POOL_ID, type(int24).min);
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, minMultiplier));
    facility.setDepositCap(intentId, minMultiplier);
  }
}
