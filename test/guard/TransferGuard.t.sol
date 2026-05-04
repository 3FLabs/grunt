// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransferGuard, TokenConfig} from "src/guard/TransferGuard.sol";
import {ITransferGuard, AddressStatus, TokenMode} from "src/interfaces/guard/ITransferGuard.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {IWrappedAsset} from "src/interfaces/funds/IWrappedAsset.sol";
import {LibPause} from "src/libs/common/LibPause.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @dev Mock PositionManager that returns configurable collateral asset via assets().
contract MockPositionManagerForGuard {
  address public collateral;

  constructor(address collateral_) {
    collateral = collateral_;
  }

  function assets() external view returns (address, address) {
    return (collateral, address(0));
  }
}

/// @dev Mock WrappedAsset with configurable isAllowed response.
contract MockWrappedAssetForGuard {
  mapping(address => bool) public allowed;

  function setAllowed(address account, bool status) external {
    allowed[account] = status;
  }

  function isAllowed(address account, uint256) external view returns (bool) {
    return allowed[account];
  }
}

/// @title TransferGuardTest
/// @notice Test suite for TransferGuard contract
contract TransferGuardTest is Test {
  using LibClone for address;
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
  address public facility; // NATIVE role address

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant _COMPLIANCE_ROLE = 1 << 0;
  uint256 constant _PAUSER_ROLE = 1 << 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  event AddressStatusSet(address indexed account, AddressStatus status);
  event TokenConfigSet(address indexed token, uint40 pausedUntil, TokenMode mode, bool checkCollateralAllowed);
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
    facility = makeAddr("facility");

    // Deploy guard
    guard = TransferGuard(address(new TransferGuard()).clone());
    guard.initialize(owner);

    // Grant roles
    vm.startPrank(owner);
    guard.grantRoles(compliance, _COMPLIANCE_ROLE);
    guard.grantRoles(pauser, _PAUSER_ROLE);
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

  function test_setAddressStatus_native() public {
    vm.prank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);

    assertEq(uint8(guard.addressStatus(facility)), uint8(AddressStatus.NATIVE));
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
    emit TokenConfigSet(token, LibPause.NOT_PAUSED, TokenMode.WHITELIST, false);

    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

    (uint40 pausedUntil_, TokenMode mode_, bool checkCollateral_) = guard.tokenConfig(token);
    assertEq(pausedUntil_, 0);
    assertEq(uint8(mode_), uint8(TokenMode.WHITELIST));
    assertFalse(checkCollateral_);
  }

  function test_setTokenConfig_withPause() public {
    vm.expectEmit(true, false, false, true);
    emit TokenConfigSet(token, LibPause.PERMANENT_PAUSE, TokenMode.BLOCKLIST, false);

    vm.prank(owner);
    guard.setTokenConfig(token, true, TokenMode.BLOCKLIST, false);

    (uint40 pausedUntil_, TokenMode mode_,) = guard.tokenConfig(token);
    assertEq(pausedUntil_, type(uint40).max);
    assertEq(uint8(mode_), uint8(TokenMode.BLOCKLIST));
  }

  function test_setTokenConfig_withCollateralCheck() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, true);

    (,, bool checkCollateral_) = guard.tokenConfig(token);
    assertTrue(checkCollateral_);
  }

  function test_setTokenConfig_revertsNonOwner() public {
    vm.prank(compliance);
    vm.expectRevert();
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);
  }

  function test_tokenMode() public {
    // Default is BLOCKLIST mode
    assertEq(uint8(guard.tokenMode(token)), uint8(TokenMode.BLOCKLIST));

    // Set to NATIVE_ONLY mode
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    assertEq(uint8(guard.tokenMode(token)), uint8(TokenMode.NATIVE_ONLY));
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
    (uint40 pausedUntil_,,) = guard.tokenConfig(token);
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
    (uint40 pausedUntil_,,) = guard.tokenConfig(token);
    assertEq(pausedUntil_, expectedPauseUntil);
  }

  function test_pauseFor_byOwner() public {
    uint256 duration = 1 hours;

    vm.prank(owner);
    guard.pauseFor(token, duration);

    assertTrue(guard.paused(token));
  }

  function test_pauseFor_zeroDurationUnpauses() public {
    vm.prank(pauser);
    guard.pause(token);
    assertTrue(guard.paused(token));

    vm.prank(pauser);
    guard.pauseFor(token, 0);
    assertFalse(guard.paused(token));
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

    (uint40 pausedUntil_,,) = guard.tokenConfig(token);
    assertEq(pausedUntil_, type(uint40).max);
  }

  function testFuzz_pauseFor_expiresCorrectly(uint256 duration, uint256 timeElapsed) public {
    duration = bound(duration, 1, type(uint40).max / 2);
    timeElapsed = bound(timeElapsed, 0, duration * 2);

    vm.prank(pauser);
    guard.pauseFor(token, duration);

    vm.warp(block.timestamp + timeElapsed);

    if (timeElapsed < duration) {
      assertTrue(guard.paused(token), "Should be paused within duration");
    } else {
      assertFalse(guard.paused(token), "Should not be paused after duration");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                BLOCKLIST MODE TESTS (default)              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_blocklist_allowsDefaultNoConfig() public view {
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_allowsNoneStatus() public view {
    assertTrue(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_blocklist_allowsMint() public view {
    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_blocklist_allowsBurn() public view {
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

  function test_blocklist_allowsNative() public {
    vm.prank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);

    assertTrue(guard.canTransfer(token, facility, alice, 1000e18));
    assertTrue(guard.canTransfer(token, alice, facility, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   WHITELIST MODE TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_whitelist_blocksBlocklisted() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_whitelist_allowsMintToWhitelisted() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

    vm.prank(compliance);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);

    assertTrue(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_whitelist_allowsBurnFromWhitelisted() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_whitelist_blocksMintToNone() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

    assertFalse(guard.canTransfer(token, address(0), bob, 1000e18));
  }

  function test_whitelist_blocksBurnFromNone() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_whitelist_allowsNative() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

    vm.prank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);

    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    assertTrue(guard.canTransfer(token, facility, alice, 1000e18));
    assertTrue(guard.canTransfer(token, alice, facility, 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  NATIVE_ONLY MODE TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_nativeOnly_allowsWithNativeParty() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    vm.prank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);

    // facility (NATIVE) -> alice (NONE): allowed
    assertTrue(guard.canTransfer(token, facility, alice, 1000e18));
    // alice (NONE) -> facility (NATIVE): allowed
    assertTrue(guard.canTransfer(token, alice, facility, 1000e18));
  }

  function test_nativeOnly_blocksWithoutNativeParty() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    // alice (NONE) -> bob (NONE): blocked (no NATIVE party)
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_nativeOnly_blocksBlocklisted() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    vm.startPrank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);
    vm.stopPrank();

    // facility (NATIVE) -> alice (BLOCKLIST): blocked
    assertFalse(guard.canTransfer(token, facility, alice, 1000e18));
    // alice (BLOCKLIST) -> facility (NATIVE): blocked
    assertFalse(guard.canTransfer(token, alice, facility, 1000e18));
  }

  function test_nativeOnly_allowsWhitelistedWithNative() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    vm.startPrank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, facility, alice, 1000e18));
  }

  function test_nativeOnly_blocksWhitelistedPairWithoutNative() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    // Two whitelisted but no NATIVE: blocked in NATIVE_ONLY
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_nativeOnly_mintBypassesNativeRequirement() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    // Mint to NONE address: allowed (bypass NATIVE requirement)
    assertTrue(guard.canTransfer(token, address(0), alice, 1000e18));
  }

  function test_nativeOnly_burnBypassesNativeRequirement() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    // Burn from NONE address: allowed (bypass NATIVE requirement)
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  function test_nativeOnly_mintBlocksBlocklisted() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);

    // Mint to blocklisted: blocked
    assertFalse(guard.canTransfer(token, address(0), alice, 1000e18));
    // Burn from blocklisted: blocked
    assertFalse(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               NATIVE_WHITELIST MODE TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_nativeWhitelist_allowsNativeToWhitelisted() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    vm.startPrank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, facility, alice, 1000e18));
    assertTrue(guard.canTransfer(token, alice, facility, 1000e18));
  }

  function test_nativeWhitelist_allowsNativeToNative() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    vm.startPrank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);
    guard.setAddressStatus(bob, AddressStatus.NATIVE);
    vm.stopPrank();

    assertTrue(guard.canTransfer(token, facility, bob, 1000e18));
  }

  function test_nativeWhitelist_blocksWhitelistedPairWithoutNative() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    vm.startPrank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);
    guard.setAddressStatus(bob, AddressStatus.WHITELIST);
    vm.stopPrank();

    // Both WHITELIST but no NATIVE: blocked
    assertFalse(guard.canTransfer(token, alice, bob, 1000e18));
  }

  function test_nativeWhitelist_blocksNoneAddress() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    vm.prank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);

    // facility (NATIVE) -> alice (NONE): blocked (NONE not allowed)
    assertFalse(guard.canTransfer(token, facility, alice, 1000e18));
  }

  function test_nativeWhitelist_blocksBlocklisted() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    vm.startPrank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);
    guard.setAddressStatus(alice, AddressStatus.BLOCKLIST);
    vm.stopPrank();

    assertFalse(guard.canTransfer(token, facility, alice, 1000e18));
  }

  function test_nativeWhitelist_mintBypassesNativeRequirement() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    // Mint to WHITELIST: allowed (bypass NATIVE requirement for null party)
    assertTrue(guard.canTransfer(token, address(0), alice, 1000e18));
  }

  function test_nativeWhitelist_mintBlocksNone() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    // Mint to NONE: blocked (NONE not WHITELIST/NATIVE)
    assertFalse(guard.canTransfer(token, address(0), alice, 1000e18));
  }

  function test_nativeWhitelist_burnBypassesNativeRequirement() public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_WHITELIST, false);

    vm.prank(compliance);
    guard.setAddressStatus(alice, AddressStatus.WHITELIST);

    // Burn from WHITELIST: allowed
    assertTrue(guard.canTransfer(token, alice, address(0), 1000e18));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              CHECK COLLATERAL ALLOWED TESTS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_checkCollateralAllowed_blocksNonAllowed() public {
    // Setup mock collateral
    MockWrappedAssetForGuard mockCollateral = new MockWrappedAssetForGuard();
    MockPositionManagerForGuard mockPM = new MockPositionManagerForGuard(address(mockCollateral));
    address pmAddr = address(mockPM);

    // Configure guard with collateral check
    vm.prank(owner);
    guard.setTokenConfig(pmAddr, false, TokenMode.BLOCKLIST, true);

    // alice not allowed on collateral
    mockCollateral.setAllowed(alice, false);
    mockCollateral.setAllowed(bob, true);

    // alice -> bob: blocked (alice not allowed on collateral)
    assertFalse(guard.canTransfer(pmAddr, alice, bob, 1000e18));

    // bob -> alice: blocked (alice not allowed on collateral)
    assertFalse(guard.canTransfer(pmAddr, bob, alice, 1000e18));
  }

  function test_checkCollateralAllowed_allowsBothAllowed() public {
    MockWrappedAssetForGuard mockCollateral = new MockWrappedAssetForGuard();
    MockPositionManagerForGuard mockPM = new MockPositionManagerForGuard(address(mockCollateral));
    address pmAddr = address(mockPM);

    vm.prank(owner);
    guard.setTokenConfig(pmAddr, false, TokenMode.BLOCKLIST, true);

    mockCollateral.setAllowed(alice, true);
    mockCollateral.setAllowed(bob, true);

    assertTrue(guard.canTransfer(pmAddr, alice, bob, 1000e18));
  }

  function test_checkCollateralAllowed_mintSkipsFromCheck() public {
    MockWrappedAssetForGuard mockCollateral = new MockWrappedAssetForGuard();
    MockPositionManagerForGuard mockPM = new MockPositionManagerForGuard(address(mockCollateral));
    address pmAddr = address(mockPM);

    vm.prank(owner);
    guard.setTokenConfig(pmAddr, false, TokenMode.BLOCKLIST, true);

    mockCollateral.setAllowed(bob, true);

    // Mint: from=address(0), only checks to
    assertTrue(guard.canTransfer(pmAddr, address(0), bob, 1000e18));
  }

  function test_checkCollateralAllowed_burnSkipsToCheck() public {
    MockWrappedAssetForGuard mockCollateral = new MockWrappedAssetForGuard();
    MockPositionManagerForGuard mockPM = new MockPositionManagerForGuard(address(mockCollateral));
    address pmAddr = address(mockPM);

    vm.prank(owner);
    guard.setTokenConfig(pmAddr, false, TokenMode.BLOCKLIST, true);

    mockCollateral.setAllowed(alice, true);

    // Burn: to=address(0), only checks from
    assertTrue(guard.canTransfer(pmAddr, alice, address(0), 1000e18));
  }

  function test_checkCollateralAllowed_combinesWithMode() public {
    MockWrappedAssetForGuard mockCollateral = new MockWrappedAssetForGuard();
    MockPositionManagerForGuard mockPM = new MockPositionManagerForGuard(address(mockCollateral));
    address pmAddr = address(mockPM);

    // NATIVE_ONLY mode + collateral check
    vm.prank(owner);
    guard.setTokenConfig(pmAddr, false, TokenMode.NATIVE_ONLY, true);

    vm.prank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);

    // Both allowed on collateral
    mockCollateral.setAllowed(facility, true);
    mockCollateral.setAllowed(alice, true);

    // facility (NATIVE) -> alice (NONE): passes mode + collateral
    assertTrue(guard.canTransfer(pmAddr, facility, alice, 1000e18));

    // Remove alice from collateral allowlist
    mockCollateral.setAllowed(alice, false);

    // facility (NATIVE) -> alice (NONE): passes mode but fails collateral
    assertFalse(guard.canTransfer(pmAddr, facility, alice, 1000e18));
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

  function testFuzz_pausedAlwaysBlocked(uint256 amount, uint8 modeSeed) public {
    TokenMode mode = TokenMode(modeSeed % 4);
    vm.prank(owner);
    guard.setTokenConfig(token, false, mode, false);

    vm.prank(pauser);
    guard.pause(token);

    assertFalse(guard.canTransfer(token, alice, bob, amount));
  }

  function testFuzz_whitelist_onlyWhitelistedOrNativeAllowed(
    uint256 amount,
    bool senderWhitelisted,
    bool recipientWhitelisted
  ) public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.WHITELIST, false);

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

  function testFuzz_nativeOnly_requiresNativeParty(uint256 amount) public {
    vm.prank(owner);
    guard.setTokenConfig(token, false, TokenMode.NATIVE_ONLY, false);

    vm.prank(compliance);
    guard.setAddressStatus(facility, AddressStatus.NATIVE);

    // With NATIVE party: allowed
    assertTrue(guard.canTransfer(token, facility, alice, amount));

    // Without NATIVE party: blocked
    assertFalse(guard.canTransfer(token, alice, bob, amount));
  }
}
