// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockVaultController, ControlledVault} from "../mock/request/MockVaults.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @title BurnAllDepletedAssetsTest
/// @notice Tests for CS-GRUNT-014: Burning all shares reverts with depleted principal assets.
/// @dev Verifies that burnAll succeeds (returning 0 assets) when the vault has no principal
///      assets but users still hold shares, after the request has been repaid.
contract BurnAllDepletedAssetsTest is Test {
  MockVaultController public vaultController;
  ControlledVault public ptVault;
  ControlledVault public ytVault;
  MockERC20 public asset;

  address public user = makeAddr("user");
  address public receiver = makeAddr("receiver");

  function setUp() public {
    asset = new MockERC20("Test Asset", "ASSET", 18);
    vaultController = new MockVaultController(address(asset), "Vault", "VLT");
    ptVault = ControlledVault(vaultController.ptToken());
    ytVault = ControlledVault(vaultController.ytToken());
    vaultController.setCanWithdraw(false);
  }

  /// @notice Helper: deposit ptShares and ytShares for a user.
  function _deposit(address to, uint256 ptShares, uint256 ytShares) internal {
    asset.mint(to, ptShares);
    vm.startPrank(to);
    asset.approve(address(vaultController), ptShares);
    vaultController.deposit(to, ptShares, ytShares);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              CS-GRUNT-014: DEPLETED PRINCIPAL ASSETS            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice When repaid with zero assets remaining, burnAll should succeed and return 0 assets.
  function test_burnAll_depletedPrincipalAssets_repaid() public {
    uint256 ptAmount = 1_000 ether;
    uint256 ytAmount = 100 ether;
    _deposit(user, ptAmount, ytAmount);

    // Simulate all assets being pulled/lost — vault balance goes to 0
    asset.burn(address(vaultController), ptAmount);
    assertEq(asset.balanceOf(address(vaultController)), 0);

    // Mark as repaid
    vaultController.setCanWithdraw(true);

    // convertToAssets should return 0 for both PT and YT when assets are depleted
    (uint256 pAssets, uint256 yAssets) = vaultController.convertToAssets(ptAmount, ytAmount);
    assertEq(pAssets, 0, "pAssets should be 0 when vault is depleted and repaid");
    assertEq(yAssets, 0, "yAssets should be 0 when vault is depleted and repaid");

    // burnAll should succeed (not revert) and return 0 assets
    vm.prank(user);
    (uint256 ptShares, uint256 ytShares, uint256 pAssetsOut, uint256 yAssetsOut) =
      vaultController.burnAll(user, receiver);

    assertEq(ptShares, ptAmount);
    assertEq(ytShares, ytAmount);
    assertEq(pAssetsOut, 0, "should receive 0 principal assets");
    assertEq(yAssetsOut, 0, "should receive 0 yield assets");
    assertEq(asset.balanceOf(receiver), 0);
    assertEq(ptVault.balanceOf(user), 0, "all PT shares should be burned");
    assertEq(ytVault.balanceOf(user), 0, "all YT shares should be burned");
  }

  /// @notice When repaid with partial assets remaining, burnAll returns correct pro-rata amounts.
  function test_burnAll_partialPrincipalAssets_repaid() public {
    uint256 ptAmount = 1_000 ether;
    uint256 ytAmount = 100 ether;
    _deposit(user, ptAmount, ytAmount);

    // Remove half the assets — simulates partial repayment
    asset.burn(address(vaultController), 500 ether);
    assertEq(asset.balanceOf(address(vaultController)), 500 ether);

    vaultController.setCanWithdraw(true);

    // pAssets = min(500, 1000) = 500, yAssets = 500 - 500 = 0
    (uint256 pAssets, uint256 yAssets) = vaultController.convertToAssets(ptAmount, ytAmount);
    // ptShares * totalPAssets / totalPtSupply = 1000 * 500 / 1000 = 500
    assertEq(pAssets, 500 ether);
    assertEq(yAssets, 0);

    vm.prank(user);
    (,, uint256 pAssetsOut, uint256 yAssetsOut) = vaultController.burnAll(user, receiver);
    assertEq(pAssetsOut, 500 ether);
    assertEq(yAssetsOut, 0);
    assertEq(asset.balanceOf(receiver), 500 ether);
  }

  /// @notice Before repayment, convertToAssets uses initial 1:1 conversion for PT (pre-repayment view).
  function test_convertToAssets_depletedPrincipal_notRepaid() public {
    uint256 ptAmount = 1_000 ether;
    uint256 ytAmount = 100 ether;
    _deposit(user, ptAmount, ytAmount);

    // Drain assets
    asset.burn(address(vaultController), ptAmount);

    // Not repaid — uses initial conversion: PT 1:1, YT 0
    (uint256 pAssets, uint256 yAssets) = vaultController.convertToAssets(ptAmount, ytAmount);
    assertEq(pAssets, ptAmount, "pre-repayment uses initial 1:1 for PT");
    assertEq(yAssets, 0, "pre-repayment initial YT conversion is 0");
  }

  /// @notice Fuzz: burnAll never reverts when repaid, regardless of depleted asset levels.
  function testFuzz_burnAll_depletedAssets_repaid(uint128 ptAmount, uint128 ytAmount, uint128 remainingAssets) public {
    vm.assume(ptAmount > 0);

    _deposit(user, ptAmount, ytAmount);

    // Set vault balance to a random amount (possibly 0, possibly less than ptAmount)
    uint256 currentBalance = asset.balanceOf(address(vaultController));
    if (remainingAssets < currentBalance) {
      asset.burn(address(vaultController), currentBalance - remainingAssets);
    } else if (remainingAssets > currentBalance) {
      asset.mint(address(vaultController), remainingAssets - currentBalance);
    }

    vaultController.setCanWithdraw(true);

    // Should never revert
    vm.prank(user);
    (uint256 ptShares, uint256 ytShares, uint256 pAssetsOut, uint256 yAssetsOut) =
      vaultController.burnAll(user, receiver);

    assertEq(ptShares, ptAmount);
    assertEq(ytShares, ytAmount);
    // Assets received should never exceed vault balance
    assertLe(pAssetsOut + yAssetsOut, remainingAssets);
    assertEq(asset.balanceOf(receiver), pAssetsOut + yAssetsOut);
  }

  /// @notice Redeem via PT vault with 0 assets should return 0, not revert.
  function test_redeemPt_depletedAssets_repaid() public {
    uint256 ptAmount = 1_000 ether;
    _deposit(user, ptAmount, 0);

    asset.burn(address(vaultController), ptAmount);
    vaultController.setCanWithdraw(true);

    vm.prank(user);
    uint256 assetsOut = ptVault.redeem(ptAmount, receiver, user);
    assertEq(assetsOut, 0, "should receive 0 assets from depleted vault");
    assertEq(ptVault.balanceOf(user), 0, "shares should be burned");
  }

  /// @notice Two users burn all from a depleted vault — both should succeed.
  function test_burnAll_depletedAssets_multipleUsers() public {
    address user2 = makeAddr("user2");
    uint256 ptAmount = 500 ether;
    uint256 ytAmount = 50 ether;

    _deposit(user, ptAmount, ytAmount);
    _deposit(user2, ptAmount, ytAmount);

    // Drain all assets
    asset.burn(address(vaultController), 2 * ptAmount);
    vaultController.setCanWithdraw(true);

    vm.prank(user);
    (,, uint256 pAssets1, uint256 yAssets1) = vaultController.burnAll(user, user);
    assertEq(pAssets1 + yAssets1, 0);

    vm.prank(user2);
    (,, uint256 pAssets2, uint256 yAssets2) = vaultController.burnAll(user2, user2);
    assertEq(pAssets2 + yAssets2, 0);
  }

  /// @notice Normal case: burnAll with full assets works as before (regression test).
  function test_burnAll_fullAssets_repaid() public {
    uint256 ptAmount = 1_000 ether;
    uint256 ytAmount = 100 ether;
    _deposit(user, ptAmount, ytAmount);

    // Add yield
    asset.mint(address(vaultController), 200 ether);
    vaultController.setCanWithdraw(true);

    vm.prank(user);
    (uint256 ptShares, uint256 ytShares, uint256 pAssetsOut, uint256 yAssetsOut) =
      vaultController.burnAll(user, receiver);

    assertEq(ptShares, ptAmount);
    assertEq(ytShares, ytAmount);
    assertEq(pAssetsOut, ptAmount);
    assertEq(yAssetsOut, 200 ether);
    assertEq(asset.balanceOf(receiver), ptAmount + 200 ether);
  }
}
