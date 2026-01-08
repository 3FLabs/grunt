// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {TransferGuard, AddressStatus, TokenConfig} from "src/guard/TransferGuard.sol";
import {TransferGuardFactory} from "src/guard/TransferGuardFactory.sol";
import {IPositionManager, RebalancingData, RebalancingOperation} from "src/interfaces/manager/IPositionManager.sol";

/// @title PositionManagerTransferGuardTest
/// @notice Test suite for PositionManager integration with TransferGuard
contract PositionManagerTransferGuardTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  TransferGuard public guard;
  TransferGuardFactory public guardFactory;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public guardOwner;
  address public blockedUser;
  address public whitelistedUser;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint88 constant LARGE_TRANSFER_THRESHOLD = 1_000e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public override {
    super.setUp();

    guardOwner = makeAddr("guardOwner");
    blockedUser = makeAddr("blockedUser");
    whitelistedUser = makeAddr("whitelistedUser");

    // Deploy guard via factory
    guardFactory = new TransferGuardFactory(guardOwner);
    address guardAddr = guardFactory.createTransferGuard(guardOwner);
    guard = TransferGuard(guardAddr);

    // Configure guard for position manager
    vm.startPrank(guardOwner);
    guard.setTokenConfig(address(positionManager), false, LARGE_TRANSFER_THRESHOLD, address(0));
    guard.setAddressStatus(blockedUser, AddressStatus.BLOCKLIST);
    guard.setAddressStatus(whitelistedUser, AddressStatus.WHITELIST_ALL_AMOUNTS);
    // Whitelist minter for deposits/withdrawals
    guard.setAddressStatus(minter, AddressStatus.WHITELIST_ALL_AMOUNTS);
    vm.stopPrank();

    // Set transfer guard on position manager
    vm.prank(owner);
    positionManager.setTransferGuard(address(guard));

    // Setup approvals for users
    vm.startPrank(whitelistedUser);
    debtToken.approve(address(positionManager), type(uint256).max);
    collateralToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    // Label contracts
    vm.label(address(guard), "TransferGuard");
    vm.label(address(guardFactory), "TransferGuardFactory");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONFIGURATION TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setTransferGuard() public view {
    assertEq(positionManager.transferGuard(), address(guard));
  }

  function test_setTransferGuard_onlyOwner() public {
    vm.prank(minter);
    vm.expectRevert();
    positionManager.setTransferGuard(address(0));
  }

  function test_setTransferGuard_canDisable() public {
    vm.prank(owner);
    positionManager.setTransferGuard(address(0));

    assertEq(positionManager.transferGuard(), address(0));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      TRANSFER TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_transfer_allowedForWhitelisted() public {
    // Mint shares to whitelisted user
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);
    assertTrue(shares > 0, "Should have shares");

    // Transfer to whitelisted user
    vm.prank(minter);
    positionManager.transfer(whitelistedUser, shares);

    assertEq(positionManager.balanceOf(whitelistedUser), shares);
    assertEq(positionManager.balanceOf(minter), 0);
  }

  function test_transfer_blockedForBlocklistedSender() public {
    // First whitelist blockedUser temporarily to receive shares
    vm.prank(guardOwner);
    guard.setAddressStatus(blockedUser, AddressStatus.WHITELIST_ALL_AMOUNTS);

    // Mint shares to blocked user
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);
    vm.prank(minter);
    positionManager.transfer(blockedUser, shares);

    // Now blocklist the user
    vm.prank(guardOwner);
    guard.setAddressStatus(blockedUser, AddressStatus.BLOCKLIST);

    // Transfer from blocked user should fail
    vm.prank(blockedUser);
    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.transfer(whitelistedUser, shares);
  }

  function test_transfer_blockedForBlocklistedRecipient() public {
    // Mint shares
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);

    // Transfer to blocked user should fail
    vm.prank(minter);
    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.transfer(blockedUser, shares);
  }

  function test_transfer_largeTransferBlockedWithoutWhitelistAll() public {
    // Set user to WHITELIST (not WHITELIST_ALL_AMOUNTS)
    vm.prank(guardOwner);
    guard.setAddressStatus(user, AddressStatus.WHITELIST);

    // Mint shares to minter
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);
    assertTrue(shares >= LARGE_TRANSFER_THRESHOLD, "Should have enough shares for large transfer");

    // Large transfer to user should fail (user only has WHITELIST, not WHITELIST_ALL_AMOUNTS)
    vm.prank(minter);
    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.transfer(user, LARGE_TRANSFER_THRESHOLD);
  }

  function test_transfer_smallTransferAllowedWithWhitelist() public {
    // Set user to WHITELIST (not WHITELIST_ALL_AMOUNTS)
    vm.prank(guardOwner);
    guard.setAddressStatus(user, AddressStatus.WHITELIST);

    // Mint shares to minter
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Small transfer should succeed
    uint256 smallAmount = LARGE_TRANSFER_THRESHOLD - 1;
    vm.prank(minter);
    positionManager.transfer(user, smallAmount);

    assertEq(positionManager.balanceOf(user), smallAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MINT/BURN TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_blockedForBlocklistedMinter() public {
    // Grant minter role to blocked user
    vm.prank(owner);
    positionManager.grantRoles(blockedUser, _ROLE_MINTER);

    _mintCollateral(blockedUser, COLLATERAL_AMOUNT);

    vm.startPrank(blockedUser);
    collateralToken.approve(address(positionManager), type(uint256).max);

    // Deposit should fail because blockedUser can't receive minted shares
    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    vm.stopPrank();
  }

  function test_burn_blockedForBlocklistedBurner() public {
    // First deposit as minter
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);

    // Transfer shares to a user who will be blocklisted
    address tempUser = makeAddr("tempUser");
    vm.prank(guardOwner);
    guard.setAddressStatus(tempUser, AddressStatus.WHITELIST_ALL_AMOUNTS);

    vm.prank(minter);
    positionManager.transfer(tempUser, shares);

    // Grant minter role to tempUser
    vm.prank(owner);
    positionManager.grantRoles(tempUser, _ROLE_MINTER);

    // Now blocklist tempUser
    vm.prank(guardOwner);
    guard.setAddressStatus(tempUser, AddressStatus.BLOCKLIST);

    // Burn should fail because tempUser is blocklisted
    _mintDebt(tempUser, DEBT_AMOUNT);
    vm.startPrank(tempUser);
    debtToken.approve(address(positionManager), type(uint256).max);

    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.burn(shares);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       PAUSE TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_transfer_blockedWhenPaused() public {
    // Mint shares
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);

    // Pause the token
    vm.prank(guardOwner);
    guard.pause(address(positionManager));

    // Transfer should fail
    vm.prank(minter);
    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.transfer(whitelistedUser, shares);
  }

  function test_deposit_blockedWhenPaused() public {
    // Pause the token
    vm.prank(guardOwner);
    guard.pause(address(positionManager));

    _mintCollateral(minter, COLLATERAL_AMOUNT);

    // Deposit should fail (minting is blocked)
    vm.prank(minter);
    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
  }

  function test_rebalance_blockedWhenPaused() public {
    // First deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Pause the token
    vm.prank(guardOwner);
    guard.pause(address(positionManager));

    // Rebalance should fail
    vm.prank(rebalancer);
    vm.expectRevert(IPositionManager.Paused.selector);
    positionManager.rebalance(
      RebalancingData({collateral: 0, debt: 0, operations: new RebalancingOperation[](0)}), rebalancer
    );
  }

  function test_rebalance_allowedWhenNotPaused() public {
    // First deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Rebalance should work (empty operation)
    vm.prank(rebalancer);
    positionManager.rebalance(
      RebalancingData({collateral: 0, debt: 0, operations: new RebalancingOperation[](0)}), rebalancer
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  NO GUARD TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_transfer_allowedWithNoGuard() public {
    // Disable guard
    vm.prank(owner);
    positionManager.setTransferGuard(address(0));

    // Mint shares
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);

    // Transfer to blocked user should succeed (no guard)
    vm.prank(minter);
    positionManager.transfer(blockedUser, shares);

    assertEq(positionManager.balanceOf(blockedUser), shares);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_transfer_whitelistedAllAmounts(uint256 amount) public {
    amount = bound(amount, 1, COLLATERAL_AMOUNT);

    // Mint shares
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);
    amount = bound(amount, 1, shares);

    // Transfer any amount to whitelisted user should succeed
    vm.prank(minter);
    positionManager.transfer(whitelistedUser, amount);

    assertEq(positionManager.balanceOf(whitelistedUser), amount);
  }

  function testFuzz_transfer_blocklistedAlwaysFails(uint256 amount) public {
    amount = bound(amount, 1, COLLATERAL_AMOUNT);

    // Mint shares
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);
    amount = bound(amount, 1, shares);

    // Transfer to blocked user should always fail
    vm.prank(minter);
    vm.expectRevert(IPositionManager.TransferBlocked.selector);
    positionManager.transfer(blockedUser, amount);
  }
}
