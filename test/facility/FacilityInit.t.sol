// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {IFacility} from "src/interfaces/facility/IFacility.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title FacilityInitTest
/// @notice Tests for Facility initialization and basic view functions
contract FacilityInitTest is FacilityBaseTest {
  using LibClone for address;
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INITIALIZATION TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_setsOwner() public view {
    assertEq(facility.owner(), owner, "Owner should be set");
  }

  function test_initialize_setsFacilitatorRole() public view {
    assertTrue(facility.hasAllRoles(facilitator, FACILITATOR_ROLE), "Facilitator role should be granted");
  }

  function test_initialize_setsRepayTimelock() public view {
    (,, uint40 _repayTimelock) = facility.facilityConfig();
    assertEq(_repayTimelock, DEFAULT_REPAY_TIMELOCK, "Repay timelock should be set");
  }

  function test_initialize_setsDescriptor() public {
    // Verify descriptor is set by calling name() which delegates to descriptor
    uint256 intentId = _createDefaultIntent();
    string memory intentName = facility.name(intentId);
    assertEq(intentName, "3F facility intent #1", "Descriptor should be set");
  }

  function test_initialize_revertOnZeroOwner() public {
    Facility newFacility = Facility(address(new Facility()).clone());
    vm.expectRevert(LibCommonErrors.AddressZero.selector);
    newFacility.initialize(address(0), facilitator, address(descriptor), DEFAULT_REPAY_TIMELOCK);
  }

  function test_initialize_revertOnZeroDescriptor() public {
    Facility newFacility = Facility(address(new Facility()).clone());
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0)));
    newFacility.initialize(owner, facilitator, address(0), DEFAULT_REPAY_TIMELOCK);
  }

  function test_initialize_revertOnEOADescriptor() public {
    Facility newFacility = Facility(address(new Facility()).clone());
    address notContract = makeAddr("notContract");
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, notContract));
    newFacility.initialize(owner, facilitator, notContract, DEFAULT_REPAY_TIMELOCK);
  }

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert();
    facility.initialize(owner, facilitator, address(descriptor), DEFAULT_REPAY_TIMELOCK);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    DESCRIPTOR TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setDescriptor_ownerCanSet() public {
    IntentDescriptor newDescriptor = new IntentDescriptor();

    vm.prank(owner);
    facility.setDescriptor(address(newDescriptor));

    // Verify by checking name output
    uint256 intentId = _createDefaultIntent();
    string memory intentName = facility.name(intentId);
    assertTrue(bytes(intentName).length > 0, "New descriptor should work");
  }

  function test_setDescriptor_revertOnNonOwner() public {
    IntentDescriptor newDescriptor = new IntentDescriptor();

    vm.prank(user);
    vm.expectRevert();
    facility.setDescriptor(address(newDescriptor));
  }

  function test_setDescriptor_revertOnEOA() public {
    address notContract = makeAddr("notContract");
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, notContract));
    facility.setDescriptor(notContract);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   REPAY TIMELOCK TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setRepayTimelock_ownerCanSet() public {
    uint40 newTimelock = 2 hours;
    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit IFacility.RepayTimelockSet(newTimelock);
    facility.setRepayTimelock(newTimelock);

    (,, uint40 _repayTimelock) = facility.facilityConfig();
    assertEq(_repayTimelock, newTimelock, "Timelock should be updated");
  }

  function test_setRepayTimelock_revertOnNonOwner() public {
    vm.prank(user);
    vm.expectRevert();
    facility.setRepayTimelock(2 hours);
  }

  function test_setRepayTimelock_revertsOnZero() public {
    vm.prank(owner);
    vm.expectRevert(LibCommonErrors.AmountZero.selector);
    facility.setRepayTimelock(0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    PAUSE VIEW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_paused_initiallyNotPaused() public view {
    (bool isPaused, uint40 pausedUntil,) = facility.facilityConfig();
    assertFalse(isPaused, "Should not be paused initially");
    assertEq(pausedUntil, 0, "PausedUntil should be 0");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ERC-6909 METADATA TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_name_returnsDescriptorName() public {
    uint256 intentId = _createDefaultIntent();
    string memory intentName = facility.name(intentId);
    assertEq(intentName, "3F facility intent #1", "Name should match descriptor");
  }

  function test_symbol_returnsDescriptorSymbol() public {
    uint256 intentId = _createDefaultIntent();
    string memory intentSymbol = facility.symbol(intentId);
    assertEq(intentSymbol, "3F-INTENT-1", "Symbol should match descriptor");
  }

  function test_decimals_returnsDepositAssetDecimals() public {
    uint256 intentId = _createDefaultIntent();
    uint8 intentDecimals = facility.decimals(intentId);
    // PositionManager has 18 decimals
    assertEq(intentDecimals, 18, "Decimals should match deposit asset");
  }

  function test_tokenURI_returnsValidURI() public {
    uint256 intentId = _createDefaultIntent();
    string memory uri = facility.tokenURI(intentId);
    // Should start with data:application/json;base64,
    assertTrue(bytes(uri).length > 30, "Token URI should be non-empty");
  }

  function test_description_returnsDescriptorDescription() public {
    uint256 intentId = _createDefaultIntent();
    // Call description directly on descriptor (not exposed via Facility)
    string memory desc = descriptor.description(IFacility(address(facility)), intentId);
    // Check it contains expected content
    assertTrue(bytes(desc).length > 0, "Description should be non-empty");
    // Description format: "This is the intent id number X..."
    assertEq(
      desc,
      "This is the intent id number 1 to deposit or withdraw from the 3F protocol. Hold this token to participate in the facility's liquidity operations.",
      "Description should match"
    );
  }

  function test_totalSupply_initiallyZero() public {
    uint256 intentId = _createDefaultIntent();
    uint256 supply = facility.totalSupply(intentId);
    assertEq(supply, 0, "Total supply should be 0 initially");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTENT BALANCES TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_intentBalances_initiallyEmpty() public {
    uint256 intentId = _createDefaultIntent();
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(intentId);
    assertEq(tokens.length, 0, "Should have no tokens initially");
    assertEq(amounts.length, 0, "Should have no amounts initially");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    FUZZ TESTS                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_initialize_withDifferentOwners(address newOwner) public {
    vm.assume(newOwner != address(0));

    Facility newFacility = Facility(address(new Facility()).clone());
    newFacility.initialize(newOwner, facilitator, address(descriptor), DEFAULT_REPAY_TIMELOCK);

    assertEq(newFacility.owner(), newOwner, "Owner should be set correctly");
  }

  function testFuzz_initialize_withDifferentFacilitators(address newFacilitator) public {
    Facility newFacility = Facility(address(new Facility()).clone());
    newFacility.initialize(owner, newFacilitator, address(descriptor), DEFAULT_REPAY_TIMELOCK);

    assertTrue(newFacility.hasAllRoles(newFacilitator, FACILITATOR_ROLE), "Facilitator should have role");
  }
}
