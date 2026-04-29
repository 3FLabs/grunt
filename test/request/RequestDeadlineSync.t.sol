// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Request} from "../../src/request/Request.sol";
import {RequestFactory} from "../../src/request/RequestFactory.sol";
import {Vault} from "../../src/request/Vault.sol";
import {VaultController} from "../../src/request/abstract/vault/VaultController.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";

/// @notice Coverage for 3F-248: PT/YT ERC-4626 views must reflect effective state in real time
///         (i.e., once block.timestamp >= repaymentDeadline) without requiring a prior
///         syncRepaidStatus() call, and the first redeem/withdraw after the deadline must succeed.
contract RequestDeadlineSyncTest is Test {
  RequestFactory internal factory;
  Request internal request;
  Vault internal ptVault;
  Vault internal ytVault;
  MockERC20 internal asset;

  address internal owner;
  address internal puller;
  address internal consumer;
  address internal beaconOwner;
  address internal user;

  uint64 internal deadline;
  uint128 internal constant PT_AMOUNT = 1_000_000e6;
  uint128 internal constant YT_AMOUNT = 100_000e6;

  event Repaid(uint256 amount);

  function setUp() public {
    owner = makeAddr("owner");
    puller = makeAddr("puller");
    consumer = makeAddr("consumer");
    beaconOwner = makeAddr("beaconOwner");
    user = makeAddr("user");

    asset = new MockERC20("USDC", "USDC", 6);
    factory = new RequestFactory(beaconOwner);

    deadline = uint64(block.timestamp + 90 days);
    vm.prank(owner);
    (address reqAddr, address ptAddr, address ytAddr) =
      factory.createRequest(owner, puller, consumer, address(asset), "Test Request", "REQ", deadline, 0);

    request = Request(reqAddr);
    ptVault = Vault(ptAddr);
    ytVault = Vault(ytAddr);
  }

  /// @dev Authorizes and mints PT_AMOUNT PT + YT_AMOUNT YT to `user`, leaving PT_AMOUNT of asset
  ///      in the Request contract.
  function _fundAndMint() internal {
    vm.prank(owner);
    request.authorizeMinting(user, PT_AMOUNT, YT_AMOUNT);

    asset.mint(user, PT_AMOUNT);
    vm.startPrank(user);
    asset.approve(address(request), PT_AMOUNT);
    request.mint(type(uint128).max, 0);
    vm.stopPrank();
  }

  /// @dev Drains the entire balance of the Request contract via pullFunds (simulates a facility
  ///      pulling funds before the deadline and never repaying).
  function _drainBeforeDeadline() internal {
    uint256 balance = asset.balanceOf(address(request));
    vm.prank(puller);
    request.pullFunds(balance, "");
  }

  // -------------------------------------------------------------------------------------------
  // 1. Real-time canWithdraw / preserved isRepaid semantic
  // -------------------------------------------------------------------------------------------

  function test_canWithdraw_returnsTrue_afterDeadline_withoutSync() public {
    assertEq(request.canWithdraw(), false);

    vm.warp(deadline + 1);

    assertEq(request.canWithdraw(), true);
  }

  function test_isRepaid_returnsFalse_afterDeadline_withoutSync() public {
    vm.warp(deadline + 1);

    assertEq(request.isRepaid(), false);
    assertEq(request.canWithdraw(), true);
  }

  // -------------------------------------------------------------------------------------------
  // 2. convertToAssets / convertToShares produce pro-rata results post-deadline
  // -------------------------------------------------------------------------------------------

  function test_convertToAssets_proRata_afterDeadline_emptyVault() public {
    _fundAndMint();
    _drainBeforeDeadline();
    assertEq(asset.balanceOf(address(request)), 0);

    vm.warp(deadline + 1);

    (uint256 pAssets, uint256 yAssets) = request.convertToAssets(PT_AMOUNT, YT_AMOUNT);
    assertEq(pAssets, 0, "PT must convert to 0 assets when vault is empty post-deadline");
    assertEq(yAssets, 0, "YT must convert to 0 assets when vault is empty post-deadline");

    assertEq(ptVault.previewRedeem(PT_AMOUNT), 0);
    assertEq(ytVault.previewRedeem(YT_AMOUNT), 0);
  }

  // -------------------------------------------------------------------------------------------
  // 3. maxWithdraw / maxRedeem reflect effective state post-deadline (no sync required)
  // -------------------------------------------------------------------------------------------

  function test_maxWithdraw_nonZero_afterDeadline_withoutSync() public {
    _fundAndMint();
    vm.warp(deadline + 1);

    assertEq(request.isRepaid(), false, "stored flag must remain false");
    assertGt(ptVault.maxWithdraw(user), 0, "PT.maxWithdraw must be non-zero after deadline");
    assertEq(ytVault.maxWithdraw(user), 0, "YT.maxWithdraw is 0 here because no excess assets exist");
  }

  function test_maxRedeem_nonZero_afterDeadline_withoutSync() public {
    _fundAndMint();
    vm.warp(deadline + 1);

    assertEq(request.isRepaid(), false, "stored flag must remain false");
    assertEq(ptVault.maxRedeem(user), PT_AMOUNT, "PT.maxRedeem must equal user balance");
    assertEq(ytVault.maxRedeem(user), YT_AMOUNT, "YT.maxRedeem must equal user balance");
  }

  // -------------------------------------------------------------------------------------------
  // 4. First redeem/withdraw after deadline succeeds (the headline regression for issue 4)
  // -------------------------------------------------------------------------------------------

  function test_redeem_succeeds_firstCallAfterDeadline() public {
    _fundAndMint();
    vm.warp(deadline + 1);

    uint256 userBalanceBefore = asset.balanceOf(user);

    vm.prank(user);
    uint256 received = ptVault.redeem(PT_AMOUNT, user, user);

    assertEq(received, PT_AMOUNT, "First post-deadline redeem must return full pro-rata principal");
    assertEq(asset.balanceOf(user), userBalanceBefore + PT_AMOUNT);
    assertEq(ptVault.balanceOf(user), 0);
    assertEq(request.isRepaid(), true, "redeem must sync the stored flag");
  }

  function test_redeem_emitsRepaidEvent_onFirstCallAfterDeadline() public {
    _fundAndMint();
    vm.warp(deadline + 1);

    uint256 balanceAtDeadline = asset.balanceOf(address(request));

    vm.expectEmit(true, true, true, true, address(request));
    emit Repaid(balanceAtDeadline);

    vm.prank(user);
    ptVault.redeem(PT_AMOUNT, user, user);
  }

  function test_withdraw_succeeds_firstCallAfterDeadline() public {
    _fundAndMint();
    vm.warp(deadline + 1);

    uint256 userBalanceBefore = asset.balanceOf(user);

    vm.prank(user);
    uint256 sharesBurned = ptVault.withdraw(PT_AMOUNT, user, user);

    assertEq(sharesBurned, PT_AMOUNT);
    assertEq(asset.balanceOf(user), userBalanceBefore + PT_AMOUNT);
    assertEq(ptVault.balanceOf(user), 0);
    assertEq(request.isRepaid(), true, "withdraw must sync the stored flag");
  }

  function test_redeem_emptyVault_afterDeadline_returnsZeroNotRevert() public {
    _fundAndMint();
    _drainBeforeDeadline();
    vm.warp(deadline + 1);

    uint256 userBalanceBefore = asset.balanceOf(user);

    vm.prank(user);
    uint256 received = ptVault.redeem(PT_AMOUNT, user, user);

    assertEq(received, 0, "Empty vault post-deadline must redeem to 0 (not revert, not 1:1)");
    assertEq(asset.balanceOf(user), userBalanceBefore);
    assertEq(ptVault.balanceOf(user), 0);
    assertEq(request.isRepaid(), true);
  }

  // -------------------------------------------------------------------------------------------
  // 5. setRepaid still reverts post-deadline (gated by _syncWithdrawalStatus)
  // -------------------------------------------------------------------------------------------

  function test_setRepaid_revertsAfterDeadline_unchanged() public {
    vm.warp(deadline + 1);

    vm.prank(owner);
    vm.expectRevert(LibRequestErrors.AlreadyRepaid.selector);
    request.setRepaid(0, type(uint256).max);
  }
}
