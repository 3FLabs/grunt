// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
  WhitelistedPartyTransferGuardFactory
} from "src/guard/whitelisted-party/WhitelistedPartyTransferGuardFactory.sol";
import {WhitelistedPartyTransferGuard} from "src/guard/whitelisted-party/WhitelistedPartyTransferGuard.sol";

/// @title WhitelistedPartyTransferGuardFactoryTest
/// @notice Tests for the WhitelistedPartyTransferGuard factory.
contract WhitelistedPartyTransferGuardFactoryTest is Test {
  WhitelistedPartyTransferGuardFactory public factory;

  address public beaconOwner;
  address public guardOwner;

  event TransferGuardCreated(address indexed transferGuard, address indexed owner);

  function setUp() public {
    beaconOwner = makeAddr("beaconOwner");
    guardOwner = makeAddr("guardOwner");

    factory = new WhitelistedPartyTransferGuardFactory(beaconOwner);
  }

  function test_constructor_deploysBeacon() public view {
    assertTrue(factory.TRANSFER_GUARD_BEACON() != address(0));
  }

  function test_createTransferGuard_deploysAndInitializes() public {
    address guard = factory.createTransferGuard(guardOwner);

    assertTrue(guard != address(0));
    assertEq(WhitelistedPartyTransferGuard(guard).owner(), guardOwner);
    assertTrue(factory.isTransferGuard(guard));
  }

  function test_createTransferGuard_emitsEvent() public {
    vm.expectEmit(false, true, false, false);
    emit TransferGuardCreated(address(0), guardOwner);

    factory.createTransferGuard(guardOwner);
  }

  function test_createTransferGuard_cannotReinitialize() public {
    address guard = factory.createTransferGuard(guardOwner);

    vm.expectRevert();
    WhitelistedPartyTransferGuard(guard).initialize(guardOwner);
  }

  function test_isTransferGuard_returnsFalseForUnknown() public {
    assertFalse(factory.isTransferGuard(makeAddr("random")));
  }

  function test_isTransferGuard_tracksMultipleDeployments() public {
    address guard1 = factory.createTransferGuard(guardOwner);
    address guard2 = factory.createTransferGuard(guardOwner);

    assertTrue(factory.isTransferGuard(guard1));
    assertTrue(factory.isTransferGuard(guard2));
    assertTrue(guard1 != guard2);
  }

  function test_deployedGuard_fullyFunctional() public {
    address guard = factory.createTransferGuard(guardOwner);
    WhitelistedPartyTransferGuard g = WhitelistedPartyTransferGuard(guard);
    address token = makeAddr("token");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Initially blocked (neither whitelisted)
    assertFalse(g.canTransfer(token, alice, bob, 100));

    // Whitelist alice
    vm.prank(guardOwner);
    g.setWhitelisted(alice, true);

    assertTrue(g.canTransfer(token, alice, bob, 100));
  }
}
