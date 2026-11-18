// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test, Vm} from "forge-std/Test.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

import {FacilityCapsBase} from "src/facility/caps/FacilityCapsBase.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";

/// @notice FacilityCapsBase with one entry point gated by each role.
contract FacilityCapsBaseHarness is FacilityCapsBase {
  uint256 public consumed;
  uint256 public managed;

  function available(uint64, int24) external pure returns (uint256) {
    return 0;
  }

  function consume(uint64, uint256 amount, int24) external onlyRoles(CAPS_CONSUMER_ROLE) {
    consumed += amount;
  }

  function manage() external onlyRoles(CAPS_MANAGER_ROLE) {
    managed++;
  }
}

/// @title FacilityCapsBaseTest
/// @notice Unit tests for the roles and initialization shared by the caps contracts
contract FacilityCapsBaseTest is Test {
  using LibClone for address;

  FacilityCapsBaseHarness public caps;
  FacilityCapsBaseHarness public implementation;

  address owner = makeAddr("owner");
  address manager = makeAddr("manager");
  address consumer = makeAddr("consumer");
  address facility = makeAddr("facility");
  address stranger = makeAddr("stranger");

  uint256 constant CAPS_MANAGER_ROLE = 1 << 0;
  uint256 constant CAPS_CONSUMER_ROLE = 1 << 1;

  function setUp() public {
    implementation = new FacilityCapsBaseHarness();
    caps = _fresh();
    caps.initialize(owner, _list(manager), _list(consumer));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _fresh() internal returns (FacilityCapsBaseHarness) {
    return FacilityCapsBaseHarness(address(implementation).clone());
  }

  function _list(address a) internal pure returns (address[] memory list) {
    list = new address[](1);
    list[0] = a;
  }

  function _list(address a, address b) internal pure returns (address[] memory list) {
    list = new address[](2);
    list[0] = a;
    list[1] = b;
  }

  function _assertOwnershipLog(Vm.Log memory log, address target, address newOwner) internal pure {
    assertEq(log.emitter, target, "Event should come from the caps contract");
    assertEq(log.topics[0], Ownable.OwnershipTransferred.selector, "Event should be OwnershipTransferred");
    assertEq(log.topics[1], bytes32(0), "Previous owner should be zero");
    assertEq(log.topics[2], bytes32(uint256(uint160(newOwner))), "New owner should be set");
  }

  function _assertRolesLog(Vm.Log memory log, address target, address user, uint256 roles) internal pure {
    assertEq(log.emitter, target, "Event should come from the caps contract");
    assertEq(log.topics[0], OwnableRoles.RolesUpdated.selector, "Event should be RolesUpdated");
    assertEq(log.topics[1], bytes32(uint256(uint160(user))), "Event should carry the user");
    assertEq(log.topics[2], bytes32(roles), "Event should carry the updated roles");
  }

  function _assertInitializedLog(Vm.Log memory log, address target) internal pure {
    assertEq(log.emitter, target, "Event should come from the caps contract");
    assertEq(log.topics[0], Initializable.Initialized.selector, "Event should be Initialized");
    assertEq(log.data, abi.encode(uint64(1)), "Version should be 1");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_emptyArraysGrantNoRoles() public {
    FacilityCapsBaseHarness fresh = _fresh();
    address[] memory none = new address[](0);

    vm.recordLogs();
    fresh.initialize(owner, none, none);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    assertEq(logs.length, 2, "Only ownership and initialization should be logged");
    _assertOwnershipLog(logs[0], address(fresh), owner);
    _assertInitializedLog(logs[1], address(fresh));
    assertEq(fresh.owner(), owner, "Owner should be set");
    assertEq(fresh.rolesOf(owner), 0, "Owner should hold no role");
  }

  function test_initialize_grantsEveryListedAccount() public {
    FacilityCapsBaseHarness fresh = _fresh();
    address otherManager = makeAddr("otherManager");

    vm.recordLogs();
    fresh.initialize(owner, _list(manager, otherManager), _list(consumer, manager));
    Vm.Log[] memory logs = vm.getRecordedLogs();

    assertEq(logs.length, 6, "Each grant should be logged once");
    _assertOwnershipLog(logs[0], address(fresh), owner);
    _assertRolesLog(logs[1], address(fresh), manager, CAPS_MANAGER_ROLE);
    _assertRolesLog(logs[2], address(fresh), otherManager, CAPS_MANAGER_ROLE);
    _assertRolesLog(logs[3], address(fresh), consumer, CAPS_CONSUMER_ROLE);
    _assertRolesLog(logs[4], address(fresh), manager, CAPS_MANAGER_ROLE | CAPS_CONSUMER_ROLE);
    _assertInitializedLog(logs[5], address(fresh));

    assertEq(fresh.rolesOf(manager), CAPS_MANAGER_ROLE | CAPS_CONSUMER_ROLE, "Listed twice should hold both roles");
    assertEq(fresh.rolesOf(otherManager), CAPS_MANAGER_ROLE, "Second manager should be granted");
    assertEq(fresh.rolesOf(consumer), CAPS_CONSUMER_ROLE, "Consumer should be granted");
    assertEq(fresh.rolesOf(owner), 0, "Owner should hold no role");
  }

  function test_initialize_bindsOwnerArgumentNotCaller() public {
    FacilityCapsBaseHarness fresh = _fresh();
    address[] memory none = new address[](0);

    vm.prank(stranger);
    fresh.initialize(owner, none, none);
    assertEq(fresh.owner(), owner, "Owner should be the argument");
    assertEq(fresh.rolesOf(stranger), 0, "Caller should hold no role");

    vm.prank(stranger);
    vm.expectRevert(Ownable.Unauthorized.selector);
    fresh.grantRoles(stranger, CAPS_MANAGER_ROLE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ROLE LIFECYCLE                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_grantRoles_newConsumerCanConsume() public {
    vm.prank(facility);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.consume(1, 5, 4096);

    vm.expectEmit(true, true, true, true, address(caps));
    emit OwnableRoles.RolesUpdated(facility, CAPS_CONSUMER_ROLE);
    vm.prank(owner);
    caps.grantRoles(facility, CAPS_CONSUMER_ROLE);

    vm.prank(facility);
    caps.consume(1, 5, 4096);
    assertEq(caps.consumed(), 5, "Granted consumer should consume");
  }

  function test_revokeRoles_removesOnlyThatRole() public {
    vm.prank(owner);
    caps.grantRoles(manager, CAPS_CONSUMER_ROLE);

    vm.expectEmit(true, true, true, true, address(caps));
    emit OwnableRoles.RolesUpdated(manager, CAPS_MANAGER_ROLE);
    vm.prank(owner);
    caps.revokeRoles(manager, CAPS_CONSUMER_ROLE);

    vm.prank(manager);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.consume(1, 5, 4096);

    vm.prank(manager);
    caps.manage();
    assertEq(caps.managed(), 1, "Manager role should be kept");
  }

  function test_renounceRoles_managerLosesAccess() public {
    vm.expectEmit(true, true, true, true, address(caps));
    emit OwnableRoles.RolesUpdated(manager, 0);
    vm.prank(manager);
    caps.renounceRoles(CAPS_MANAGER_ROLE);

    vm.prank(manager);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.manage();
  }

  function test_grantRoles_revertOnRoleHolders() public {
    vm.prank(manager);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.grantRoles(facility, CAPS_CONSUMER_ROLE);

    vm.prank(consumer);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.grantRoles(facility, CAPS_CONSUMER_ROLE);
  }

  function test_transferOwnership_keepsRoleHolders() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    caps.transferOwnership(newOwner);

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.revokeRoles(consumer, CAPS_CONSUMER_ROLE);

    vm.prank(manager);
    caps.manage();
    vm.prank(consumer);
    caps.consume(1, 5, 4096);
    assertEq(caps.managed(), 1, "Manager should keep managing");
    assertEq(caps.consumed(), 5, "Consumer should keep consuming");

    vm.prank(newOwner);
    caps.revokeRoles(consumer, CAPS_CONSUMER_ROLE);
    assertEq(caps.rolesOf(consumer), 0, "New owner should control roles");
  }

  function test_renounceOwnership_freezesRoles() public {
    vm.prank(owner);
    caps.renounceOwnership();

    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    caps.revokeRoles(consumer, CAPS_CONSUMER_ROLE);

    vm.prank(manager);
    caps.manage();
    vm.prank(consumer);
    caps.consume(1, 5, 4096);
    assertEq(caps.managed(), 1, "Manager should keep managing");
    assertEq(caps.consumed(), 5, "Consumer should keep consuming");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          VALIDATE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_validate_revertOnMinMultiplier(uint64 id) public {
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    caps.validate(id, type(int24).min);
  }

  function testFuzz_validate_revertOnZeroMultiplier(uint64 id) public {
    vm.expectRevert(IFacilityCaps.InvalidMultiplier.selector);
    caps.validate(id, 0);
  }

  function testFuzz_validate_acceptsAnyIdByDefault(uint64 id, int24 multiplier) public view {
    multiplier = int24(bound(multiplier, type(int24).min + 1, type(int24).max));
    vm.assume(multiplier != 0);
    caps.validate(id, multiplier);
  }
}
