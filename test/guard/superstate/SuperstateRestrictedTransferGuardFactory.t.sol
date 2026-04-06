// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SuperstateRestrictedTransferGuardFactory} from
  "src/guard/superstate/SuperstateRestrictedTransferGuardFactory.sol";
import {SuperstateRestrictedTransferGuard} from "src/guard/superstate/SuperstateRestrictedTransferGuard.sol";

import {MockSuperstateToken} from "test/mock/funds/MockSuperstateToken.sol";
import {MockAllowlist} from "test/mock/funds/MockAllowlist.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title SuperstateRestrictedTransferGuardFactoryTest
contract SuperstateRestrictedTransferGuardFactoryTest is Test {
  SuperstateRestrictedTransferGuardFactory public factory;

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

    factory = new SuperstateRestrictedTransferGuardFactory(beaconOwner, address(uscc));
  }

  function test_constructor_deploysBeacon() public view {
    assertTrue(factory.TRANSFER_GUARD_BEACON() != address(0));
  }

  function test_createTransferGuard_deploysAndInitializes() public {
    address guard = factory.createTransferGuard(guardOwner);

    assertTrue(guard != address(0));
    assertEq(SuperstateRestrictedTransferGuard(guard).owner(), guardOwner);
    assertEq(SuperstateRestrictedTransferGuard(guard).SUPERSTATE_TOKEN(), address(uscc));
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
    SuperstateRestrictedTransferGuard(guard).initialize(guardOwner);
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
    SuperstateRestrictedTransferGuard g = SuperstateRestrictedTransferGuard(guard);
    address token = makeAddr("token");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Allow both on Superstate allowlist
    allowlist.setAllowed(alice, "USCC", true);
    allowlist.setAllowed(bob, "USCC", true);

    // Should allow in default blocklist mode with both Superstate-allowed
    assertTrue(g.canTransfer(token, alice, bob, 100));

    // Remove bob from Superstate → blocked
    allowlist.setAllowed(bob, "USCC", false);
    assertFalse(g.canTransfer(token, alice, bob, 100));
  }
}
