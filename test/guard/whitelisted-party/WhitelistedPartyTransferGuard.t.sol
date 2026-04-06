// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WhitelistedPartyTransferGuard} from "src/guard/whitelisted-party/WhitelistedPartyTransferGuard.sol";
import {LibPause} from "src/libs/common/LibPause.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title WhitelistedPartyTransferGuardTest
/// @notice Tests for WhitelistedPartyTransferGuard — transfers allowed if at least one party is whitelisted.
contract WhitelistedPartyTransferGuardTest is Test {
  WhitelistedPartyTransferGuard public guard;

  address public owner;
  address public compliance;
  address public pauser;
  address public token;
  address public alice;
  address public bob;
  address public facility;

  uint256 constant _COMPLIANCE_ROLE = 1 << 0;
  uint256 constant _PAUSER_ROLE = 1 << 1;

  event WhitelistedSet(address indexed account, bool status);
  event TokenPausedSet(address indexed token, uint40 pausedUntil);

  function setUp() public {
    owner = makeAddr("owner");
    compliance = makeAddr("compliance");
    pauser = makeAddr("pauser");
    token = makeAddr("token");
    alice = makeAddr("alice");
    bob = makeAddr("bob");
    facility = makeAddr("facility");

    guard = WhitelistedPartyTransferGuard(LibClone.clone(address(new WhitelistedPartyTransferGuard())));
    guard.initialize(owner);

    vm.startPrank(owner);
    guard.grantRoles(compliance, _COMPLIANCE_ROLE);
    guard.grantRoles(pauser, _PAUSER_ROLE);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INITIALIZATION TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_setsOwner() public view {
    assertEq(guard.owner(), owner);
  }

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert();
    guard.initialize(alice);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    WHITELIST MANAGEMENT                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setWhitelisted_byOwner() public {
    vm.expectEmit(true, false, false, true);
    emit WhitelistedSet(facility, true);

    vm.prank(owner);
    guard.setWhitelisted(facility, true);

    assertTrue(guard.isWhitelisted(facility));
  }

  function test_setWhitelisted_byCompliance() public {
    vm.prank(compliance);
    guard.setWhitelisted(facility, true);

    assertTrue(guard.isWhitelisted(facility));
  }

  function test_setWhitelisted_remove() public {
    vm.prank(owner);
    guard.setWhitelisted(facility, true);
    assertTrue(guard.isWhitelisted(facility));

    vm.prank(owner);
    guard.setWhitelisted(facility, false);
    assertFalse(guard.isWhitelisted(facility));
  }

  function test_setWhitelisted_revertsUnauthorized() public {
    vm.prank(alice);
    vm.expectRevert();
    guard.setWhitelisted(facility, true);
  }

  function test_setWhitelistedBatch() public {
    address[] memory accounts = new address[](3);
    accounts[0] = alice;
    accounts[1] = bob;
    accounts[2] = facility;

    vm.prank(compliance);
    guard.setWhitelistedBatch(accounts, true);

    assertTrue(guard.isWhitelisted(alice));
    assertTrue(guard.isWhitelisted(bob));
    assertTrue(guard.isWhitelisted(facility));
  }

  function test_setWhitelistedBatch_revertsUnauthorized() public {
    address[] memory accounts = new address[](1);
    accounts[0] = facility;

    vm.prank(alice);
    vm.expectRevert();
    guard.setWhitelistedBatch(accounts, true);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    TRANSFER VALIDATION                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_canTransfer_blocksWhenNeitherWhitelisted() public view {
    // Neither alice nor bob is whitelisted
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_allowsWhenSenderWhitelisted() public {
    vm.prank(owner);
    guard.setWhitelisted(alice, true);

    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_allowsWhenReceiverWhitelisted() public {
    vm.prank(owner);
    guard.setWhitelisted(bob, true);

    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_allowsWhenBothWhitelisted() public {
    vm.startPrank(owner);
    guard.setWhitelisted(alice, true);
    guard.setWhitelisted(bob, true);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_allowsMintWhenReceiverWhitelisted() public {
    vm.prank(owner);
    guard.setWhitelisted(bob, true);

    // Mint: from == address(0)
    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_canTransfer_allowsBurnWhenSenderWhitelisted() public {
    vm.prank(owner);
    guard.setWhitelisted(alice, true);

    // Burn: to == address(0)
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_canTransfer_allowsMintToNonWhitelisted() public view {
    // Mints are always allowed (protocol operation, not peer-to-peer)
    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_canTransfer_allowsBurnFromNonWhitelisted() public view {
    // Burns are always allowed (protocol operation, not peer-to-peer)
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_canTransfer_allowsMintAndBurn() public view {
    // Both null — edge case: mint+burn (from=0, to=0) should pass
    assertTrue(guard.canTransfer(token, address(0), address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pause_blocksTransfer() public {
    vm.prank(owner);
    guard.setWhitelisted(alice, true);

    vm.prank(pauser);
    guard.pause(token);

    assertTrue(guard.paused(token));
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_unpause_allowsTransfer() public {
    vm.prank(owner);
    guard.setWhitelisted(alice, true);

    vm.prank(pauser);
    guard.pause(token);
    assertTrue(guard.paused(token));

    vm.prank(pauser);
    guard.unpause(token);
    assertFalse(guard.paused(token));

    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_pauseFor_expiresCorrectly() public {
    vm.prank(owner);
    guard.setWhitelisted(alice, true);

    vm.prank(pauser);
    guard.pauseFor(token, 1 hours);

    assertTrue(guard.paused(token));
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));

    vm.warp(block.timestamp + 1 hours);
    assertFalse(guard.paused(token));
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_pause_revertsUnauthorized() public {
    vm.prank(alice);
    vm.expectRevert();
    guard.pause(token);
  }

  function test_pauseFor_revertsUnauthorized() public {
    vm.prank(alice);
    vm.expectRevert();
    guard.pauseFor(token, 1 hours);
  }

  function test_unpause_revertsUnauthorized() public {
    vm.prank(alice);
    vm.expectRevert();
    guard.unpause(token);
  }

  function test_pause_emitsEvent() public {
    vm.expectEmit(true, false, false, true);
    emit TokenPausedSet(token, LibPause.PERMANENT_PAUSE);

    vm.prank(pauser);
    guard.pause(token);
  }

  function test_unpause_emitsEvent() public {
    vm.prank(pauser);
    guard.pause(token);

    vm.expectEmit(true, false, false, true);
    emit TokenPausedSet(token, LibPause.NOT_PAUSED);

    vm.prank(pauser);
    guard.unpause(token);
  }

  function test_pauseFor_emitsEvent() public {
    uint40 expectedPauseUntil = uint40(block.timestamp + 1 hours);

    vm.expectEmit(true, false, false, true);
    emit TokenPausedSet(token, expectedPauseUntil);

    vm.prank(pauser);
    guard.pauseFor(token, 1 hours);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_canTransfer_onlyAllowedWithWhitelistedParty(
    uint256 amount,
    bool senderWhitelisted,
    bool recipientWhitelisted
  ) public {
    if (senderWhitelisted) {
      vm.prank(owner);
      guard.setWhitelisted(alice, true);
    }
    if (recipientWhitelisted) {
      vm.prank(owner);
      guard.setWhitelisted(bob, true);
    }

    bool expected = senderWhitelisted || recipientWhitelisted;
    assertEq(guard.canTransfer(token, alice, bob, amount), expected);
  }

  function testFuzz_pausedAlwaysBlocked(uint256 amount) public {
    vm.prank(owner);
    guard.setWhitelisted(alice, true);

    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, amount));
  }
}
