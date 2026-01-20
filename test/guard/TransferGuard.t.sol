// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransferGuard, AddressStatus, TokenConfig} from "src/guard/TransferGuard.sol";
import {ITransferGuard} from "src/interfaces/guard/ITransferGuard.sol";
import {LibPause} from "src/libs/common/LibPause.sol";
import {LibErrors} from "src/libs/common/LibErrors.sol";

/// @title TransferGuardTest
/// @notice Test suite for TransferGuard contract
contract TransferGuardTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  TransferGuard public guard;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public compliance;
  address public pauser;
  address public token;
  address public alice;
  address public bob;
  address public blockedUser;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant COMPLIANCE_ROLE = 1 << 0;
  uint256 constant PAUSER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  event AddressStatusSet(address indexed account, AddressStatus status);
  event TokenConfigSet(address indexed token, uint40 pausedUntil, bool whitelist);
  event TokenPausedSet(address indexed token, uint40 pausedUntil);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    owner = makeAddr("owner");
    compliance = makeAddr("compliance");
    pauser = makeAddr("pauser");
    token = makeAddr("token");
    alice = makeAddr("alice");
    bob = makeAddr("bob");
    blockedUser = makeAddr("blockedUser");

    // Deploy guard
    guard = new TransferGuard();
    guard.initialize(owner);

    // Grant roles
    vm.startPrank(owner);
    guard.grantRoles(compliance, COMPLIANCE_ROLE);
    guard.grantRoles(pauser, PAUSER_ROLE);
    vm.stopPrank();

    // Label contracts
    vm.label(address(guard), "TransferGuard");
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
  /*                    ADDRESS STATUS TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setAddressStatus_byOwner() public {
    vm.expectEmit(true, false, false, true);
    emit AddressStatusSet(alice, AddressStatus.WHITELIST);

    vm.prank(owner);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    assertEq(uint8(guard.addressStatus(alice)), uint8(AddressStatus.WHITELIST));
  }

  function test_setAddressStatus_byCompliance() public {
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertEq(uint8(guard.addressStatus(alice)), uint8(AddressStatus.BLOCKLIST));
  }

  function test_setAddressStatus_revertsUnauthorized() public {
    vm.prank(alice);
    vm.expectRevert();
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
  }

  function test_setAddressStatusBatch() public {
    address[] memory accounts = new address[](3);
    accounts[0] = alice;
    accounts[1] = bob;
    accounts[2] = blockedUser;

    vm.prank(compliance);
    guard.setAddressStatusBatch(accounts, AddressStatus.WHITELIST);

    assertEq(uint8(guard.addressStatus(alice)), uint8(AddressStatus.WHITELIST));
    assertEq(uint8(guard.addressStatus(bob)), uint8(AddressStatus.WHITELIST));
    assertEq(uint8(guard.addressStatus(blockedUser)), uint8(AddressStatus.WHITELIST));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    TOKEN CONFIG TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setTokenConfig() public {
    vm.expectEmit(true, false, false, true);
    emit TokenConfigSet(token, LibPause.NOT_PAUSED, true);

    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    (uint40 pausedUntil_, bool whitelist_) = guard.tokenConfig(token);
    assertEq(pausedUntil_, 0); // Not paused
    assertEq(whitelist_, true);
  }

  function test_setTokenConfig_withPause() public {
    vm.expectEmit(true, false, false, true);
    emit TokenConfigSet(token, LibPause.PERMANENT_PAUSE, false);

    vm.prank(owner);
    guard.setTokenConfig(token, true, false);

    (uint40 pausedUntil_, bool whitelist_) = guard.tokenConfig(token);
    assertEq(pausedUntil_, type(uint40).max); // Permanently paused
    assertEq(whitelist_, false);
  }

  function test_setTokenConfig_revertsNonOwner() public {
    vm.prank(compliance);
    vm.expectRevert();
    guard.setTokenConfig(token, false, true);
  }

  function test_isWhitelistMode() public {
    // Default is blocklist mode
    assertFalse(guard.isWhitelistMode(token));

    // Set to whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    assertTrue(guard.isWhitelistMode(token));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pause_byPauser() public {
    vm.expectEmit(true, false, false, true);
    emit TokenPausedSet(token, LibPause.PERMANENT_PAUSE);

    vm.prank(pauser);
    guard.pause(token);

    assertTrue(guard.paused(token));
    (uint40 pausedUntil_,) = guard.tokenConfig(token);
    assertEq(pausedUntil_, type(uint40).max);
  }

  function test_pause_byOwner() public {
    vm.prank(owner);
    guard.pause(token);

    assertTrue(guard.paused(token));
  }

  function test_unpause() public {
    vm.prank(pauser);
    guard.pause(token);
    assertTrue(guard.paused(token));

    vm.expectEmit(true, false, false, true);
    emit TokenPausedSet(token, LibPause.NOT_PAUSED);

    vm.prank(pauser);
    guard.unpause(token);
    assertFalse(guard.paused(token));
  }

  function test_pause_revertsUnauthorized() public {
    vm.prank(alice);
    vm.expectRevert();
    guard.pause(token);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    PAUSE_FOR TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pauseFor_byPauser() public {
    uint256 duration = 1 hours;
    uint40 expectedPauseUntil = uint40(block.timestamp + duration);

    vm.expectEmit(true, false, false, true);
    emit TokenPausedSet(token, expectedPauseUntil);

    vm.prank(pauser);
    guard.pauseFor(token, duration);

    assertTrue(guard.paused(token));
    (uint40 pausedUntil_,) = guard.tokenConfig(token);
    assertEq(pausedUntil_, expectedPauseUntil);
  }

  function test_pauseFor_byOwner() public {
    uint256 duration = 1 hours;

    vm.prank(owner);
    guard.pauseFor(token, duration);

    assertTrue(guard.paused(token));
  }

  function test_pauseFor_expiresAfterDuration() public {
    uint256 duration = 1 hours;

    vm.prank(pauser);
    guard.pauseFor(token, duration);

    // Should be paused now
    assertTrue(guard.paused(token));
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));

    // Still paused at exactly the pause time
    vm.warp(block.timestamp + duration);
    assertTrue(guard.paused(token));
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));

    // Not paused after duration expires
    vm.warp(block.timestamp + 1);
    assertFalse(guard.paused(token));
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_pauseFor_revertsOnZeroDuration() public {
    vm.prank(pauser);
    vm.expectRevert(LibErrors.AmountZero.selector);
    guard.pauseFor(token, 0);
  }

  function test_pauseFor_revertsUnauthorized() public {
    vm.prank(alice);
    vm.expectRevert();
    guard.pauseFor(token, 1 hours);
  }

  function test_pauseFor_capsAtMaxUint40() public {
    uint256 hugeValue = uint256(type(uint40).max) + 1;

    vm.prank(pauser);
    guard.pauseFor(token, hugeValue);

    (uint40 pausedUntil_,) = guard.tokenConfig(token);
    assertEq(pausedUntil_, type(uint40).max);
  }

  function testFuzz_pauseFor_expiresCorrectly(uint256 duration, uint256 timeElapsed) public {
    duration = bound(duration, 1, type(uint40).max / 2);
    timeElapsed = bound(timeElapsed, 0, duration * 2);

    vm.prank(pauser);
    guard.pauseFor(token, duration);

    vm.warp(block.timestamp + timeElapsed);

    if (timeElapsed <= duration) {
      assertTrue(guard.paused(token), "Should be paused within duration");
    } else {
      assertFalse(guard.paused(token), "Should not be paused after duration");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                BLOCKLIST MODE TESTS (default)              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_blocklist_allowsDefaultNoConfig() public view {
    // No config set - should allow (blocklist mode by default, NONE status allowed)
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_blocksWhenPaused() public {
    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_blocksBlocklistedSender() public {
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_blocksBlocklistedRecipient() public {
    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_allowsWhitelisted() public {
    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_allowsNoneStatus() public view {
    // NONE status is allowed in blocklist mode
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_allowsMint() public view {
    // Mints have from = address(0)
    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_blocklist_allowsBurn() public view {
    // Burns have to = address(0)
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_blocklist_blocksMintToBlocklisted() public {
    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_blocklist_blocksBurnFromBlocklisted() public {
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   WHITELIST MODE TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_whitelist_blocksNoneStatus() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // NONE status is blocked in whitelist mode
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_allowsWhitelisted() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // Whitelist both parties
    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_blocksBlocklisted() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_blocksWhenPaused() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // Whitelist both parties
    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    // Pause
    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_blocksIfSenderNotWhitelisted() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // Only whitelist recipient
    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_blocksIfRecipientNotWhitelisted() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // Only whitelist sender
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_allowsMintToWhitelisted() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // Whitelist recipient
    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);

    // Mints have from = address(0) which is skipped
    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_whitelist_allowsBurnFromWhitelisted() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // Whitelist sender
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    // Burns have to = address(0) which is skipped
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_whitelist_blocksMintToNone() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // bob has NONE status (not whitelisted)
    assertFalse(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_whitelist_blocksBurnFromNone() public {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    // alice has NONE status (not whitelisted)
    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_blocklist_whitelistedAlwaysAllowed(uint256 amount) public {
    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, alice, bob, amount));
  }

  function testFuzz_blocklist_blocklistAlwaysBlocked(uint256 amount, bool isSender) public {
    vm.prank(compliance);
    if (isSender) {
      guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);
      assertFalse(guard.canTransfer(token, alice, bob, amount));
    } else {
      guard.setAddressStatus(bob, AddressStatus.BLOCKLIST);
      assertFalse(guard.canTransfer(token, alice, bob, amount));
    }
  }

  function testFuzz_pausedAlwaysBlocked(uint256 amount, bool isWhitelistMode) public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, isWhitelistMode);

    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, amount));
  }

  function testFuzz_whitelist_onlyWhitelistedAllowed(uint256 amount, bool senderWhitelisted, bool recipientWhitelisted)
    public
  {
    // Set whitelist mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, true);

    vm.startPrank(compliance);
    if (senderWhitelisted) {
      guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    }
    if (recipientWhitelisted) {
      guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    }
    vm.stopPrank();

    bool expected = senderWhitelisted && recipientWhitelisted;
    assertEq(guard.canTransfer(token, alice, bob, amount), expected);
  }
}
