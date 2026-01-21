// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {TransferGuard, AddressStatus, TokenConfig} from "src/guard/TransferGuard.sol";
import {TransferGuardFactory} from "src/guard/TransferGuardFactory.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {RebalancingData, RebalancingOperation} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {LibManagerErrors} from "../../src/libs/manager/LibManagerErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../src/libs/common/LibCommonErrors.sol";

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

    // Configure guard for position manager (whitelist mode)
    vm.startPrank(guardOwner);
    guard.setTokenConfig(address(positionManager), false, true);
    guard.setAddressStatus(blockedUser, AddressStatus.BLOCKLIST);
    guard.setAddressStatus(whitelistedUser, AddressStatus.WHITELIST);
    // Whitelist minter for deposits/withdrawals
    guard.setAddressStatus(minter, AddressStatus.WHITELIST);
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
    (,, address guard_) = positionManager.config();
    assertEq(guard_, address(guard));
  }

  function test_setTransferGuard_onlyOwner() public {
    vm.prank(minter);
    vm.expectRevert();
    positionManager.setTransferGuard(address(0));
  }

  function test_setTransferGuard_canDisable() public {
    vm.prank(owner);
    positionManager.setTransferGuard(address(0));

    (,, address guard_) = positionManager.config();
    assertEq(guard_, address(0));
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
    guard.setAddressStatus(blockedUser, AddressStatus.WHITELIST);

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
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
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
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
    positionManager.transfer(blockedUser, shares);
  }

  function test_transfer_blockedForNoneStatusInWhitelistMode() public {
    // Mint shares to minter
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);

    // Transfer to user (not whitelisted, NONE status) should fail in whitelist mode
    vm.prank(minter);
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
    positionManager.transfer(user, shares);
  }

  function test_transfer_allowedInBlocklistMode() public {
    // Switch to blocklist mode
    vm.prank(guardOwner);
    guard.setTokenConfig(address(positionManager), false, false);

    // Mint shares to minter
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 shares = positionManager.balanceOf(minter);

    // Transfer to user (NONE status) should succeed in blocklist mode
    vm.prank(minter);
    positionManager.transfer(user, shares);

    assertEq(positionManager.balanceOf(user), shares);
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
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
    vm.stopPrank();
  }

  function test_deposit_blockedForNoneStatusInWhitelistMode() public {
    // Grant minter role to user (not whitelisted)
    vm.prank(owner);
    positionManager.grantRoles(user, _ROLE_MINTER);

    _mintCollateral(user, COLLATERAL_AMOUNT);

    vm.startPrank(user);
    collateralToken.approve(address(positionManager), type(uint256).max);

    // Deposit should fail because user is not whitelisted
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
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
    guard.setAddressStatus(tempUser, AddressStatus.WHITELIST);

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

    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
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
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
    positionManager.transfer(whitelistedUser, shares);
  }

  function test_deposit_blockedWhenPaused() public {
    // Pause the token
    vm.prank(guardOwner);
    guard.pause(address(positionManager));

    _mintCollateral(minter, COLLATERAL_AMOUNT);

    // Deposit should fail (minting is blocked)
    vm.prank(minter);
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
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
    vm.expectRevert(CommonErrors.Paused.selector);
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

  function testFuzz_transfer_whitelisted(uint256 amount) public {
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
    vm.expectRevert(LibManagerErrors.TransferBlocked.selector);
    positionManager.transfer(blockedUser, amount);
  }
}
