// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
  SuperstateRestrictedWhitelistedPartyTransferGuard
} from "src/guard/superstate/SuperstateRestrictedWhitelistedPartyTransferGuard.sol";
import {LibPause} from "src/libs/common/LibPause.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {MockSuperstateToken} from "test/mock/funds/MockSuperstateToken.sol";
import {MockAllowlist} from "test/mock/funds/MockAllowlist.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title SuperstateRestrictedWhitelistedPartyTransferGuardTest
/// @notice Tests combined whitelisted-party + Superstate allowlist guard logic.
contract SuperstateRestrictedWhitelistedPartyTransferGuardTest is Test {
  SuperstateRestrictedWhitelistedPartyTransferGuard public guard;

  MockAllowlist public allowlist;
  MockSuperstateToken public uscc;

  address public owner;
  address public compliance;
  address public pauser;
  address public token;
  address public alice;
  address public bob;
  address public facility;

  uint256 constant _COMPLIANCE_ROLE = 1 << 0;
  uint256 constant _PAUSER_ROLE = 1 << 1;

  function setUp() public {
    owner = makeAddr("owner");
    compliance = makeAddr("compliance");
    pauser = makeAddr("pauser");
    token = makeAddr("token");
    alice = makeAddr("alice");
    bob = makeAddr("bob");
    facility = makeAddr("facility");

    allowlist = new MockAllowlist();
    uscc = new MockSuperstateToken("USCC", "USCC", address(allowlist), address(new MockERC20("USDC", "USDC", 6)));

    // Deploy guard via clone
    SuperstateRestrictedWhitelistedPartyTransferGuard impl =
      new SuperstateRestrictedWhitelistedPartyTransferGuard(address(uscc));
    guard = SuperstateRestrictedWhitelistedPartyTransferGuard(LibClone.clone(address(impl)));
    guard.initialize(owner);

    vm.startPrank(owner);
    guard.grantRoles(compliance, _COMPLIANCE_ROLE);
    guard.grantRoles(pauser, _PAUSER_ROLE);
    // Whitelist the facility in the guard
    guard.setWhitelisted(facility, true);
    vm.stopPrank();

    // Allow all addresses on Superstate allowlist by default
    allowlist.setAllowed(alice, "USCC", true);
    allowlist.setAllowed(bob, "USCC", true);
    allowlist.setAllowed(facility, "USCC", true);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INITIALIZATION TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_setsOwner() public view {
    assertEq(guard.owner(), owner);
  }

  function test_superstateToken() public view {
    assertEq(guard.SUPERSTATE_TOKEN(), address(uscc));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               COMBINED LOGIC: WHITELIST + SUPERSTATE       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_allowsFacilityToUserTransfer() public view {
    // Facility (whitelisted) → alice (Superstate-allowed)
    assertTrue(guard.canTransfer(token, facility, alice, 1000e18));
  }

  function test_allowsUserToFacilityTransfer() public view {
    // alice (Superstate-allowed) → Facility (whitelisted)
    assertTrue(guard.canTransfer(token, alice, facility, 1000e18));
  }

  function test_blocksUserToUserTransfer() public view {
    // Neither alice nor bob is on the guard whitelist (even though both are Superstate-allowed)
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocksFacilityToUserWhenUserNotSuperstateAllowed() public {
    // Facility (whitelisted) → bob (not Superstate-allowed)
    allowlist.setAllowed(bob, "USCC", false);
    assertFalse(guard.canTransfer(token, facility, bob, 1000e18));
  }

  function test_blocksUserToFacilityWhenUserNotSuperstateAllowed() public {
    // alice (not Superstate-allowed) → Facility (whitelisted)
    allowlist.setAllowed(alice, "USCC", false);
    assertFalse(guard.canTransfer(token, alice, facility, 1000e18));
  }

  function test_blocksFacilityToUserWhenFacilityNotSuperstateAllowed() public {
    // Facility (whitelisted but not Superstate-allowed) → alice
    allowlist.setAllowed(facility, "USCC", false);
    assertFalse(guard.canTransfer(token, facility, alice, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     MINT / BURN TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_mintAllowed_whenRecipientSuperstateAllowed() public view {
    // Mint to alice — passes guard B (mint always allowed), alice on Superstate
    assertTrue(guard.canTransfer(token, address(0), alice, 1000e18));
  }

  function test_mintBlocked_whenRecipientNotSuperstateAllowed() public {
    allowlist.setAllowed(alice, "USCC", false);
    // Mint passes guard B, but alice not on Superstate
    assertFalse(guard.canTransfer(token, address(0), alice, 1000e18));
  }

  function test_burnAllowed_whenSenderSuperstateAllowed() public view {
    // Burn from alice — passes guard B (burn always allowed), alice on Superstate
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_burnBlocked_whenSenderNotSuperstateAllowed() public {
    allowlist.setAllowed(alice, "USCC", false);
    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pauseBlocksEverything() public {
    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, facility, alice, 1000e18));
    assertFalse(guard.canTransfer(token, address(0), alice, 1000e18));
    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_unpauseRestoresTransfers() public {
    vm.prank(pauser);
    guard.pause(token);

    vm.prank(pauser);
    guard.unpause(token);

    assertTrue(guard.canTransfer(token, facility, alice, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_combinedChecks(
    uint256 amount,
    bool senderWhitelisted,
    bool receiverWhitelisted,
    bool senderSuperstateAllowed,
    bool receiverSuperstateAllowed
  ) public {
    if (senderWhitelisted) {
      vm.prank(owner);
      guard.setWhitelisted(alice, true);
    }
    if (receiverWhitelisted) {
      vm.prank(owner);
      guard.setWhitelisted(bob, true);
    }
    allowlist.setAllowed(alice, "USCC", senderSuperstateAllowed);
    allowlist.setAllowed(bob, "USCC", receiverSuperstateAllowed);

    // Layer 1: at least one party whitelisted in guard
    bool passesGuardB = senderWhitelisted || receiverWhitelisted;
    // Layer 2: both non-null parties on Superstate allowlist
    bool passesSuperstate = senderSuperstateAllowed && receiverSuperstateAllowed;

    bool expected = passesGuardB && passesSuperstate;
    assertEq(guard.canTransfer(token, alice, bob, amount), expected);
  }
}
