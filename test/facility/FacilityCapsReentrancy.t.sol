// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityBaseTest} from "./FacilityBase.t.sol";

import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {FacilityCapsBase} from "src/facility/caps/FacilityCapsBase.sol";
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {IFacilityLP} from "src/interfaces/facility/base/IFacilityLP.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";

/// @notice Whitelisted caps contract that calls back into the facility from consume()
contract CapsReentrancyAttacker is FacilityCapsBase {
  address public target;
  bytes public payload;

  function arm(address target_, bytes calldata payload_) external {
    target = target_;
    payload = payload_;
  }

  function available(uint64, int24) external pure returns (uint256) {
    return type(uint256).max;
  }

  function consume(uint64, uint256, int24) external onlyRoles(CAPS_CONSUMER_ROLE) {
    if (payload.length == 0) return;
    (bool success, bytes memory data) = target.call(payload);
    if (!success) {
      assembly ("memory-safe") {
        revert(add(data, 0x20), mload(data))
      }
    }
  }
}

/// @title FacilityCapsReentrancyTest
/// @notice The reentrancy guard covers the external call into a caps contract
contract FacilityCapsReentrancyTest is FacilityBaseTest {
  using LibClone for address;

  CapsReentrancyAttacker public caps;
  uint256 public intentId;

  int24 constant MULT_1X = 4096;
  uint256 constant AMOUNT = 1000e18;

  function setUp() public override {
    super.setUp();

    address[] memory managers = new address[](0);
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    caps = CapsReentrancyAttacker(address(new CapsReentrancyAttacker()).clone());
    caps.initialize(owner, managers, consumers);

    vm.startPrank(owner);
    capsWhitelist.setAllowed(address(caps), true);
    // access checks cannot be what stops the re-entered calls
    facility.grantRoles(address(caps), COMPLIANCE_ROLE);
    vm.stopPrank();

    IntentProperties memory props = _intentParamsWithTargetPM();
    props.depositCap = LibCaps.encodeExternal(address(caps), 1, MULT_1X);
    vm.prank(owner);
    intentId = facility.createIntent(props);
  }

  /// @dev Facility entry points re-entered from the caps call
  function _reentries() internal view returns (bytes[] memory calls) {
    calls = new bytes[](5);
    calls[0] = abi.encodeCall(IFacilityLP.deposit, (intentId, 1));
    calls[1] = abi.encodeCall(IFacilityLP.withdraw, (intentId, user, user, 1));
    calls[2] = abi.encodeCall(IFacilityLP.revertDeposit, (intentId, user, user));
    calls[3] = abi.encodeCall(IFacilityLP.claim, (intentId, user, user, 1));
    calls[4] = abi.encodeCall(IFacility.intentBalances, (intentId));
  }

  function _deposit(uint256 amount) internal {
    _mintDebt(user, amount);
    vm.prank(user);
    facility.deposit(intentId, amount);
  }

  function test_deposit_revertOnReentryFromCaps() public {
    _mintDebt(user, AMOUNT);
    bytes[] memory calls = _reentries();
    for (uint256 i = 0; i < calls.length; i++) {
      caps.arm(address(facility), calls[i]);
      vm.prank(user);
      vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
      facility.deposit(intentId, AMOUNT);
    }
  }

  function test_withdraw_revertOnReentryFromCaps() public {
    _deposit(AMOUNT);
    bytes[] memory calls = _reentries();
    for (uint256 i = 0; i < calls.length; i++) {
      caps.arm(address(facility), calls[i]);
      vm.prank(user);
      vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
      facility.withdraw(intentId, user, user, AMOUNT);
    }
  }

  function test_revertDeposit_revertOnReentryFromCaps() public {
    _deposit(AMOUNT);
    bytes[] memory calls = _reentries();
    for (uint256 i = 0; i < calls.length; i++) {
      caps.arm(address(facility), calls[i]);
      vm.prank(pauser);
      vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
      facility.revertDeposit(intentId, user, user);
    }
  }
}
