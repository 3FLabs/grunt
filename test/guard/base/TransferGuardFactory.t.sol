// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransferGuardFactory} from "src/guard/base/TransferGuardFactory.sol";
import {TransferGuard, AddressStatus} from "src/guard/base/TransferGuard.sol";
import {UpgradeableBeacon} from "lib/solady/src/utils/UpgradeableBeacon.sol";

/// @title TransferGuardFactoryTest
/// @notice Test suite for TransferGuardFactory contract
contract TransferGuardFactoryTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  TransferGuardFactory public factory;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public beaconOwner;
  address public guardOwner;
  address public user;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  event TransferGuardCreated(address indexed transferGuard, address indexed owner);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    beaconOwner = makeAddr("beaconOwner");
    guardOwner = makeAddr("guardOwner");
    user = makeAddr("user");

    factory = new TransferGuardFactory(beaconOwner);
    vm.label(address(factory), "TransferGuardFactory");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONSTRUCTOR TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constructor_deploysBeacon() public view {
    address beacon = factory.TRANSFER_GUARD_BEACON();
    assertTrue(beacon != address(0), "Beacon should be deployed");
  }

  function test_constructor_beaconHasCorrectOwner() public view {
    address beacon = factory.TRANSFER_GUARD_BEACON();
    assertEq(UpgradeableBeacon(beacon).owner(), beaconOwner, "Beacon owner should be set correctly");
  }

  function test_constructor_beaconHasImplementation() public view {
    address beacon = factory.TRANSFER_GUARD_BEACON();
    address implementation = UpgradeableBeacon(beacon).implementation();
    assertTrue(implementation != address(0), "Beacon should have implementation");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 CREATE TRANSFER GUARD TESTS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_createTransferGuard_emitsEvent() public {
    vm.expectEmit(false, true, false, false);
    emit TransferGuardCreated(address(0), guardOwner);

    factory.createTransferGuard(guardOwner);
  }

  function test_createTransferGuard_anyoneCanCall() public {
    vm.prank(user);
    address guard = factory.createTransferGuard(guardOwner);

    assertTrue(guard != address(0), "Anyone should be able to create transfer guard");
    assertEq(TransferGuard(guard).owner(), guardOwner);
  }

  function test_createTransferGuard_cannotReinitialize() public {
    address guard = factory.createTransferGuard(guardOwner);

    vm.expectRevert();
    TransferGuard(guard).initialize(user);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  DEPLOYMENT TRACKING TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isTransferGuard_returnsTrueForDeployed() public {
    address guard = factory.createTransferGuard(guardOwner);
    assertTrue(factory.isTransferGuard(guard));
  }

  function test_isTransferGuard_returnsFalseForUnknown() public view {
    assertFalse(factory.isTransferGuard(address(0xdead)));
  }

  function test_isTransferGuard_tracksMultipleDeployments() public {
    address guard1 = factory.createTransferGuard(guardOwner);
    address guard2 = factory.createTransferGuard(user);

    assertTrue(factory.isTransferGuard(guard1));
    assertTrue(factory.isTransferGuard(guard2));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      UPGRADE TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_beaconUpgrade_onlyOwner() public {
    address beacon = factory.TRANSFER_GUARD_BEACON();

    // Deploy new implementation
    TransferGuard newImplementation = new TransferGuard();

    // Non-owner cannot upgrade
    vm.prank(user);
    vm.expectRevert();
    UpgradeableBeacon(beacon).upgradeTo(address(newImplementation));

    // Owner can upgrade
    vm.prank(beaconOwner);
    UpgradeableBeacon(beacon).upgradeTo(address(newImplementation));

    assertEq(UpgradeableBeacon(beacon).implementation(), address(newImplementation), "Implementation should be updated");
  }

  function test_beaconUpgrade_affectsAllProxies() public {
    // Create two guards
    address guard1 = factory.createTransferGuard(guardOwner);
    address guard2 = factory.createTransferGuard(user);

    // Set some state
    vm.prank(guardOwner);
    TransferGuard(guard1).setAddressStatus(user, AddressStatus.BLOCKLIST);

    vm.prank(user);
    TransferGuard(guard2).setAddressStatus(guardOwner, AddressStatus.WHITELIST);

    // Verify state before upgrade
    assertEq(uint8(TransferGuard(guard1).addressStatus(user)), uint8(AddressStatus.BLOCKLIST));
    assertEq(uint8(TransferGuard(guard2).addressStatus(guardOwner)), uint8(AddressStatus.WHITELIST));

    // Upgrade beacon
    address beacon = factory.TRANSFER_GUARD_BEACON();
    TransferGuard newImplementation = new TransferGuard();

    vm.prank(beaconOwner);
    UpgradeableBeacon(beacon).upgradeTo(address(newImplementation));

    // State should be preserved after upgrade
    assertEq(uint8(TransferGuard(guard1).addressStatus(user)), uint8(AddressStatus.BLOCKLIST));
    assertEq(uint8(TransferGuard(guard2).addressStatus(guardOwner)), uint8(AddressStatus.WHITELIST));

    // Functions should still work
    assertEq(TransferGuard(guard1).owner(), guardOwner);
    assertEq(TransferGuard(guard2).owner(), user);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   FUNCTIONAL TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deployedGuard_fullyFunctional() public {
    address guard = factory.createTransferGuard(guardOwner);
    TransferGuard tg = TransferGuard(guard);

    address token = makeAddr("token");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Set token config (whitelist mode)
    vm.prank(guardOwner);
    tg.setTokenConfig(token, false, true);

    // Set address status for both parties
    vm.startPrank(guardOwner);
    tg.setAddressStatus(alice, AddressStatus.WHITELIST);
    tg.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    // Test canTransfer
    assertTrue(tg.canTransfer(token, alice, bob, 200_000e18));

    // Test pause
    vm.prank(guardOwner);
    tg.pause(token);
    assertFalse(tg.canTransfer(token, alice, bob, 1000e18));

    // Test unpause
    vm.prank(guardOwner);
    tg.unpause(token);
    assertTrue(tg.canTransfer(token, alice, bob, 200_000e18));
  }

  function test_deployedGuard_blocklistMode() public {
    address guard = factory.createTransferGuard(guardOwner);
    TransferGuard tg = TransferGuard(guard);

    address token = makeAddr("token");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Blocklist mode is default
    assertFalse(tg.isWhitelistMode(token));

    // Should allow transfers between any non-blocklisted addresses
    assertTrue(tg.canTransfer(token, alice, bob, 1000e18));

    // Blocklist bob
    vm.prank(guardOwner);
    tg.setAddressStatus(bob, AddressStatus.BLOCKLIST);

    // Now transfers to bob should fail
    assertFalse(tg.canTransfer(token, alice, bob, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_createTransferGuard(address owner_) public {
    vm.assume(owner_ != address(0));

    address guard = factory.createTransferGuard(owner_);

    assertEq(TransferGuard(guard).owner(), owner_);
  }

  function testFuzz_multipleDeployments(uint8 count) public {
    count = uint8(bound(count, 1, 50));

    address[] memory guards = new address[](count);
    for (uint8 i = 0; i < count; i++) {
      guards[i] = factory.createTransferGuard(makeAddr(string(abi.encodePacked("owner", i))));
    }

    // Verify all unique
    for (uint8 i = 0; i < count; i++) {
      for (uint8 j = i + 1; j < count; j++) {
        assertTrue(guards[i] != guards[j], "All guards should be unique");
      }
    }
  }
}
