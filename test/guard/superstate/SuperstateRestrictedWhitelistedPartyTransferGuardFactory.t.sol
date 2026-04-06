// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SuperstateRestrictedWhitelistedPartyTransferGuardFactory} from
  "src/guard/superstate/SuperstateRestrictedWhitelistedPartyTransferGuardFactory.sol";
import {SuperstateRestrictedWhitelistedPartyTransferGuard} from
  "src/guard/superstate/SuperstateRestrictedWhitelistedPartyTransferGuard.sol";

import {MockSuperstateToken} from "test/mock/funds/MockSuperstateToken.sol";
import {MockAllowlist} from "test/mock/funds/MockAllowlist.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title SuperstateRestrictedWhitelistedPartyTransferGuardFactoryTest
contract SuperstateRestrictedWhitelistedPartyTransferGuardFactoryTest is Test {
  SuperstateRestrictedWhitelistedPartyTransferGuardFactory public factory;

  MockAllowlist public allowlist;
  MockSuperstateToken public uscc;

  address public beaconOwner;
  address public guardOwner;

  event TransferGuardCreated(address indexed transferGuard, address indexed owner);

  function setUp() public {
    beaconOwner = makeAddr("beaconOwner");
    guardOwner = makeAddr("guardOwner");

    allowlist = new MockAllowlist();
    uscc = new MockSuperstateToken("USCC", "USCC", address(allowlist), address(new MockERC20("USDC", "USDC", 6)));

    factory = new SuperstateRestrictedWhitelistedPartyTransferGuardFactory(beaconOwner, address(uscc));
  }

  function test_constructor_deploysBeacon() public view {
    assertTrue(factory.TRANSFER_GUARD_BEACON() != address(0));
  }

  function test_createTransferGuard_deploysAndInitializes() public {
    address guard = factory.createTransferGuard(guardOwner);

    assertTrue(guard != address(0));
    assertEq(SuperstateRestrictedWhitelistedPartyTransferGuard(guard).owner(), guardOwner);
    assertEq(SuperstateRestrictedWhitelistedPartyTransferGuard(guard).SUPERSTATE_TOKEN(), address(uscc));
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
    SuperstateRestrictedWhitelistedPartyTransferGuard(guard).initialize(guardOwner);
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
    SuperstateRestrictedWhitelistedPartyTransferGuard g =
      SuperstateRestrictedWhitelistedPartyTransferGuard(guard);
    address token = makeAddr("token");
    address facility = makeAddr("facility");
    address user = makeAddr("user");

    // Allow both on Superstate
    allowlist.setAllowed(facility, "USCC", true);
    allowlist.setAllowed(user, "USCC", true);

    // Neither whitelisted in guard → blocked
    assertFalse(g.canTransfer(token, facility, user, 100));

    // Whitelist facility → allowed
    vm.prank(guardOwner);
    g.setWhitelisted(facility, true);
    assertTrue(g.canTransfer(token, facility, user, 100));

    // Remove user from Superstate → blocked
    allowlist.setAllowed(user, "USCC", false);
    assertFalse(g.canTransfer(token, facility, user, 100));
  }
}
