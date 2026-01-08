// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransferGuard, AddressStatus, TokenConfig} from "src/guard/TransferGuard.sol";
import {ITransferGuard} from "src/interfaces/guard/ITransferGuard.sol";
import {ITransferGuardValidator} from "src/interfaces/guard/ITransferGuardValidator.sol";

/// @title MockValidator
/// @notice Mock validator for testing NONE status delegation
contract MockValidator is ITransferGuardValidator {
  mapping(address => bool) public authorized;

  function setAuthorized(address account, bool _authorized) external {
    authorized[account] = _authorized;
  }

  function isAuthorized(address account) external view returns (bool) {
    return authorized[account];
  }
}

/// @title TransferGuardTest
/// @notice Test suite for TransferGuard contract
contract TransferGuardTest is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  TransferGuard public guard;
  MockValidator public validator;

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
  uint88 constant LARGE_TRANSFER_THRESHOLD = 100_000e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  event AddressStatusSet(address indexed account, AddressStatus status);
  event TokenConfigSet(address indexed token, bool paused, uint88 threshold, address validator);

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

    // Deploy mock validator
    validator = new MockValidator();

    // Grant roles
    vm.startPrank(owner);
    guard.grantRoles(compliance, COMPLIANCE_ROLE);
    guard.grantRoles(pauser, PAUSER_ROLE);
    vm.stopPrank();

    // Label contracts
    vm.label(address(guard), "TransferGuard");
    vm.label(address(validator), "MockValidator");
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
    emit TokenConfigSet(token, false, LARGE_TRANSFER_THRESHOLD, address(validator));

    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(validator));

    (bool paused, uint88 threshold, address val) = guard.tokenConfig(token);
    assertEq(paused, false);
    assertEq(threshold, LARGE_TRANSFER_THRESHOLD);
    assertEq(val, address(validator));
  }

  function test_setTokenConfig_revertsNonOwner() public {
    vm.prank(compliance);
    vm.expectRevert();
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(validator));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pause_byPauser() public {
    vm.prank(pauser);
    guard.pause(token);

    assertTrue(guard.paused(token));
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
  /*                   CAN TRANSFER TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_canTransfer_allowsDefaultNoConfig() public view {
    // No config set, no threshold - should allow
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_blocksWhenPaused() public {
    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_blocksBlocklistedSender() public {
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_blocksBlocklistedRecipient() public {
    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_allowsWhitelistAllAmounts() public {
    // Set threshold
    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(0));

    // Whitelist both alice and bob for all amounts
    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST_ALL_AMOUNTS);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST_ALL_AMOUNTS);
    vm.stopPrank();

    // Large transfer should succeed
    assertTrue(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD + 1));
  }

  function test_canTransfer_whitelistBlocksLargeTransfer() public {
    // Set threshold
    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(0));

    // Whitelist alice (not for all amounts)
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    // Small transfer should succeed
    assertTrue(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD - 1));

    // Large transfer should fail (alice is sender, not WHITELIST_ALL_AMOUNTS)
    assertFalse(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD));
  }

  function test_canTransfer_noneStatusWithNoValidator() public {
    // Set threshold but no validator
    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(0));

    // alice has NONE status (default)
    // Small transfer should succeed
    assertTrue(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD - 1));

    // Large transfer should fail
    assertFalse(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD));
  }

  function test_canTransfer_noneStatusWithValidatorAuthorized() public {
    // Set threshold with validator
    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(validator));

    // Authorize alice in validator
    validator.setAuthorized(alice, true);
    validator.setAuthorized(bob, true);

    // Small transfer should succeed
    assertTrue(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD - 1));

    // Large transfer should still fail (validator gives WHITELIST equivalent, not WHITELIST_ALL_AMOUNTS)
    assertFalse(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD));
  }

  function test_canTransfer_noneStatusWithValidatorNotAuthorized() public {
    // Set threshold with validator
    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(validator));

    // alice is NOT authorized in validator (default false)
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_canTransfer_allowsMint() public {
    // Mints have from = address(0)
    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);

    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_canTransfer_allowsBurn() public {
    // Burns have to = address(0)
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_canTransfer_blocksMintToBlocklisted() public {
    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_canTransfer_blocksBurnFromBlocklisted() public {
    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   THRESHOLD EDGE CASES                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_canTransfer_thresholdZeroAllowsAll() public {
    // Set config with threshold = 0
    vm.prank(owner);
    guard.setTokenConfig(token, false, 0, address(0));

    // Any amount should work for NONE status
    assertTrue(guard.canTransfer(token, alice, bob, type(uint256).max));
  }

  function test_canTransfer_exactThresholdIsLargeTransfer() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(0));

    // Exactly at threshold is considered large
    assertFalse(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD));

    // One below threshold is not large
    assertTrue(guard.canTransfer(token, alice, bob, LARGE_TRANSFER_THRESHOLD - 1));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_canTransfer_whitelistAllAmountsAlwaysAllowed(uint256 amount) public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, LARGE_TRANSFER_THRESHOLD, address(0));

    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST_ALL_AMOUNTS);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST_ALL_AMOUNTS);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, alice, bob, amount));
  }

  function testFuzz_canTransfer_blocklistAlwaysBlocked(uint256 amount, bool isSender) public {
    vm.prank(compliance);
    if (isSender) {
      guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);
      assertFalse(guard.canTransfer(token, alice, bob, amount));
    } else {
      guard.setAddressStatus(bob, AddressStatus.BLOCKLIST);
      assertFalse(guard.canTransfer(token, alice, bob, amount));
    }
  }

  function testFuzz_canTransfer_pausedAlwaysBlocked(uint256 amount) public {
    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, amount));
  }
}
