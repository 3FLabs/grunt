// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Request} from "../../src/request/Request.sol";
import {RequestFactory} from "../../src/request/RequestFactory.sol";
import {Vault} from "../../src/request/Vault.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";

/// @title RequestERC4626CompliancePoCTest
/// @notice Proof of Concept demonstrating ERC-4626 compliance for preview/max deposit/mint functions.
/// @dev Reference: CS-I-6 — previewMint/previewDeposit return amounts despite mint/deposit reverting.
///
///      The ERC-4626 spec requires that preview functions reflect the actual outcome of the corresponding
///      operation. Since deposit() and mint() always revert in the ControlledVault (shares are only
///      minted through the Request contract's authorizeMinting/consume flow), previewDeposit() and
///      previewMint() must return 0. Similarly, maxDeposit() and maxMint() must return 0.
///
///      This test verifies the full ERC-4626 deposit/mint compliance surface:
///        - maxDeposit() returns 0 → no deposits possible
///        - maxMint() returns 0 → no mints possible
///        - previewDeposit() returns 0 → consistent with deposit() reverting
///        - previewMint() returns 0 → consistent with mint() reverting
///        - deposit() reverts → shares only minted via Request
///        - mint() reverts → shares only minted via Request
contract RequestERC4626CompliancePoCTest is Test {
  RequestFactory public factory;
  Request public request;
  Vault public ptVault;
  Vault public ytVault;
  MockERC20 public asset;

  address public owner;
  address public puller;
  address public consumer;

  function setUp() public {
    owner = makeAddr("owner");
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");

    asset = new MockERC20("USDC", "USDC", 6);
    factory = new RequestFactory(makeAddr("beaconOwner"));

    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) =
      factory.createRequest(owner, puller, consumer, address(asset), "Test Request", "REQ", uint64(type(uint64).max));

    request = Request(reqAddr);
    ptVault = Vault(ptAddr);
    ytVault = Vault(ytAddr);
  }

  /// @notice Demonstrates the full ERC-4626 compliance for the deposit/mint surface.
  /// @dev Before the fix, previewDeposit() and previewMint() would return non-zero amounts
  ///      even though deposit() and mint() always revert. This violates the ERC-4626 spec
  ///      which states preview functions "MUST return as close to and no more than the exact
  ///      amount" of the corresponding operation.
  function test_poc_erc4626DepositMintComplianceSurface() public {
    address user = makeAddr("user");

    // --- maxDeposit/maxMint must return 0 (no deposits/mints allowed) ---
    assertEq(ptVault.maxDeposit(user), 0, "PT maxDeposit should be 0");
    assertEq(ytVault.maxDeposit(user), 0, "YT maxDeposit should be 0");
    assertEq(ptVault.maxMint(user), 0, "PT maxMint should be 0");
    assertEq(ytVault.maxMint(user), 0, "YT maxMint should be 0");

    // --- previewDeposit/previewMint must return 0 (consistent with reverting operations) ---
    assertEq(ptVault.previewDeposit(1_000_000e6), 0, "PT previewDeposit should be 0");
    assertEq(ytVault.previewDeposit(1_000_000e6), 0, "YT previewDeposit should be 0");
    assertEq(ptVault.previewMint(1_000_000e6), 0, "PT previewMint should be 0");
    assertEq(ytVault.previewMint(1_000_000e6), 0, "YT previewMint should be 0");

    // --- deposit/mint must revert ---
    asset.mint(user, 1_000_000e6);
    vm.startPrank(user);
    asset.approve(address(ptVault), 1_000_000e6);
    asset.approve(address(ytVault), 1_000_000e6);

    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ptVault.deposit(1_000_000e6, user);

    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ytVault.deposit(1_000_000e6, user);

    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ptVault.mint(1_000_000e6, user);

    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ytVault.mint(1_000_000e6, user);
    vm.stopPrank();
  }

  /// @notice Verifies compliance holds after shares are minted via the Request flow.
  /// @dev Even after PT/YT shares exist, the vault's direct deposit/mint path remains disabled
  ///      and preview functions must still return 0.
  function test_poc_complianceHoldsAfterMinting() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 100_000e6;

    // Mint shares via the Request contract (the only valid path)
    vm.prank(owner);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    asset.mint(primeBroker, ptAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), ptAmount);
    request.mint();
    vm.stopPrank();

    // Shares now exist
    assertGt(ptVault.totalSupply(), 0, "PT should have shares");
    assertGt(ytVault.totalSupply(), 0, "YT should have shares");

    // But deposit/mint surface is still fully disabled and compliant
    assertEq(ptVault.maxDeposit(primeBroker), 0, "PT maxDeposit still 0 after minting");
    assertEq(ytVault.maxDeposit(primeBroker), 0, "YT maxDeposit still 0 after minting");
    assertEq(ptVault.maxMint(primeBroker), 0, "PT maxMint still 0 after minting");
    assertEq(ytVault.maxMint(primeBroker), 0, "YT maxMint still 0 after minting");
    assertEq(ptVault.previewDeposit(1_000_000e6), 0, "PT previewDeposit still 0 after minting");
    assertEq(ytVault.previewDeposit(1_000_000e6), 0, "YT previewDeposit still 0 after minting");
    assertEq(ptVault.previewMint(1_000_000e6), 0, "PT previewMint still 0 after minting");
    assertEq(ytVault.previewMint(1_000_000e6), 0, "YT previewMint still 0 after minting");
  }

  /// @notice Verifies compliance holds even after yield accrual.
  /// @dev Yield accrual changes the conversion rates, but preview functions must still return 0
  ///      since the vault's direct deposit/mint path is always disabled.
  function test_poc_complianceHoldsAfterYieldAccrual() public {
    address primeBroker = makeAddr("primeBroker");
    uint128 ptAmount = 1_000_000e6;
    uint128 ytAmount = 100_000e6;

    // Mint shares
    vm.prank(owner);
    request.authorizeMinting(primeBroker, ptAmount, ytAmount);

    asset.mint(primeBroker, ptAmount);
    vm.startPrank(primeBroker);
    asset.approve(address(request), ptAmount);
    request.mint();
    vm.stopPrank();

    // Simulate yield by transferring extra assets to the request
    asset.mint(address(request), 500_000e6);

    // convertToShares/convertToAssets return meaningful values (for withdraw/redeem)
    assertGt(ptVault.convertToShares(100e6), 0, "convertToShares should work");
    assertGt(ptVault.convertToAssets(100e6), 0, "convertToAssets should work");

    // But preview deposit/mint still return 0
    assertEq(ptVault.previewDeposit(100e6), 0, "PT previewDeposit 0 after yield");
    assertEq(ytVault.previewDeposit(100e6), 0, "YT previewDeposit 0 after yield");
    assertEq(ptVault.previewMint(100e6), 0, "PT previewMint 0 after yield");
    assertEq(ytVault.previewMint(100e6), 0, "YT previewMint 0 after yield");
  }
}
