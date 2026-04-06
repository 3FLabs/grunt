// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SuperstateRestrictedTransferGuard} from "src/guard/superstate/SuperstateRestrictedTransferGuard.sol";
import {AddressStatus} from "src/interfaces/guard/ITransferGuard.sol";
import {LibPause} from "src/libs/common/LibPause.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {MockSuperstateToken} from "test/mock/funds/MockSuperstateToken.sol";
import {MockAllowlist} from "test/mock/funds/MockAllowlist.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title SuperstateRestrictedTransferGuardTest
/// @notice Tests that the guard enforces both base TransferGuard logic AND Superstate allowlist.
contract SuperstateRestrictedTransferGuardTest is Test {
  SuperstateRestrictedTransferGuard public guard;

  MockAllowlist public allowlist;
  MockSuperstateToken public uscc;
  MockERC20 public usdc;

  address public owner;
  address public compliance;
  address public pauser;
  address public token;
  address public alice;
  address public bob;

  uint256 constant _COMPLIANCE_ROLE = 1 << 0;
  uint256 constant _PAUSER_ROLE = 1 << 1;

  function setUp() public {
    owner = makeAddr("owner");
    compliance = makeAddr("compliance");
    pauser = makeAddr("pauser");
    token = makeAddr("token");
    alice = makeAddr("alice");
    bob = makeAddr("bob");

    usdc = new MockERC20("USDC", "USDC", 6);
    allowlist = new MockAllowlist();
    uscc = new MockSuperstateToken("USCC", "USCC", address(allowlist), address(usdc));

    // Deploy guard via clone (simulating beacon proxy)
    SuperstateRestrictedTransferGuard impl = new SuperstateRestrictedTransferGuard(address(uscc));
    guard = SuperstateRestrictedTransferGuard(LibClone.clone(address(impl)));
    guard.initialize(owner);

    vm.startPrank(owner);
    guard.grantRoles(compliance, _COMPLIANCE_ROLE);
    guard.grantRoles(pauser, _PAUSER_ROLE);
    vm.stopPrank();

    // Allow all addresses on Superstate allowlist by default
    allowlist.setAllowed(alice, "USCC", true);
    allowlist.setAllowed(bob, "USCC", true);
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
  /*                  BLOCKLIST MODE + SUPERSTATE               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_blocklist_allowsWhenBothSuperstateAllowed() public view {
    // Default blocklist mode, both on Superstate allowlist
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_blocksWhenSenderNotSuperstateAllowed() public {
    allowlist.setAllowed(alice, "USCC", false);
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_blocksWhenReceiverNotSuperstateAllowed() public {
    allowlist.setAllowed(bob, "USCC", false);
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_blocksWhenBlocklisted_evenIfSuperstateAllowed() public {
    // Alice is on Superstate allowlist but blocklisted in the guard
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  WHITELIST MODE + SUPERSTATE               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_whitelist_blocksNoneStatus_evenIfSuperstateAllowed() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // Both on Superstate allowlist but have NONE status in whitelist mode → blocked by base
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_allowsWhenWhitelisted_andSuperstateAllowed() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_blocksWhenWhitelisted_butNotSuperstateAllowed() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    // Remove alice from Superstate allowlist
    allowlist.setAllowed(alice, "USCC", false);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     MINT / BURN TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_mint_allowedWhenRecipientSuperstateAllowed() public view {
    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_mint_blockedWhenRecipientNotSuperstateAllowed() public {
    allowlist.setAllowed(bob, "USCC", false);
    assertFalse(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_burn_allowedWhenSenderSuperstateAllowed() public view {
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_burn_blockedWhenSenderNotSuperstateAllowed() public {
    allowlist.setAllowed(alice, "USCC", false);
    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pause_blocksEvenIfSuperstateAllowed() public {
    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_superstateCheck_bothMustBeAllowed(
    uint256 amount,
    bool senderAllowed,
    bool receiverAllowed
  ) public {
    allowlist.setAllowed(alice, "USCC", senderAllowed);
    allowlist.setAllowed(bob, "USCC", receiverAllowed);

    bool expected = senderAllowed && receiverAllowed;
    assertEq(guard.canTransfer(token, alice, bob, amount), expected);
  }
}
