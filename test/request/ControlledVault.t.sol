// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockVaultController, ControlledVault, VaultController} from "../mock/request/MockVaults.sol";
import {ControlledToken} from "../../src/request/abstract/tokens/ControlledToken.sol";
import {TokenController} from "../../src/request/abstract/tokens/TokenController.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {IERC4626} from "../../src/interfaces/integrations/IERC4626.sol";
import {LibRequestErrors} from "../../src/libs/request/LibRequestErrors.sol";

contract ControlledVaultTest is Test {
  MockVaultController public vaultController;
  ControlledVault public ptVault;
  ControlledVault public ytVault;
  MockERC20 public asset;

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Approval(address indexed owner, address indexed spender, uint256 amount);
  event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(
    address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
  );

  function setUp() public {
    asset = new MockERC20("Test Asset", "ASSET", 18);
    vaultController = new MockVaultController(address(asset), "Vault", "VLT");
    ptVault = ControlledVault(vaultController.ptToken());
    ytVault = ControlledVault(vaultController.ytToken());

    // Lock withdrawals by default (deposit phase)
    vaultController.setCanWithdraw(false);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      METADATA TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_name() public view {
    assertEq(ptVault.name(), "PT-Vault");
    assertEq(ytVault.name(), "YT-Vault");
  }

  function test_symbol() public view {
    assertEq(ptVault.symbol(), "PT-VLT");
    assertEq(ytVault.symbol(), "YT-VLT");
  }

  function test_decimals() public view {
    assertEq(ptVault.decimals(), 18);
    assertEq(ytVault.decimals(), 18);
  }

  function test_asset() public view {
    assertEq(ptVault.asset(), address(asset));
    assertEq(ytVault.asset(), address(asset));
  }

  function test_totalSupply() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    assertEq(ptVault.totalSupply(), 1000 ether);
    assertEq(ytVault.totalSupply(), 100 ether);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      DEPOSIT TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    assertEq(ptVault.balanceOf(user), 1000 ether);
    assertEq(ytVault.balanceOf(user), 100 ether);
    assertEq(asset.balanceOf(address(vaultController)), 1000 ether);
  }

  function test_depositEmitsEvents() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);

    vm.expectEmit(true, true, true, true, address(ptVault));
    emit Deposit(user, user, 1000 ether, 1000 ether);
    vm.expectEmit(true, true, true, true, address(ytVault));
    emit Deposit(user, user, 0, 100 ether);

    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();
  }

  function test_maxDeposit() public view {
    assertEq(ptVault.maxDeposit(address(0x1)), 0);
    assertEq(ytVault.maxDeposit(address(0x1)), 0);
  }

  function test_depositReverts() public {
    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ptVault.deposit(100 ether, address(0x1));

    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ytVault.deposit(100 ether, address(0x1));
  }

  function test_maxMint() public view {
    assertEq(ptVault.maxMint(address(0x1)), 0);
    assertEq(ytVault.maxMint(address(0x1)), 0);
  }

  function test_mintReverts() public {
    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ptVault.mint(100 ether, address(0x1));

    vm.expectRevert(LibRequestErrors.CannotMintShares.selector);
    ytVault.mint(100 ether, address(0x1));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CONVERSION TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_convertToShares_beforeYield() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // PT: 1:1 ratio (1000 assets, 1000 shares)
    assertEq(ptVault.convertToShares(100 ether), 100 ether);
    // YT: 0 assets, 100 shares -> division by zero returns type(uint256).max
    assertEq(ytVault.convertToShares(100 ether), type(uint256).max);
  }

  function test_convertToShares_afterYield() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // Add 50 ether yield
    asset.mint(address(vaultController), 50 ether);

    // PT: 1000 assets, 1000 shares -> 1:1
    assertEq(ptVault.convertToShares(100 ether), 100 ether);
    // YT: 50 assets, 100 shares -> 100/50 = 2 shares per asset
    assertEq(ytVault.convertToShares(50 ether), 100 ether);
  }

  function test_convertToAssets_beforeYield() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // PT: 1:1 ratio
    assertEq(ptVault.convertToAssets(100 ether), 100 ether);
    // YT: 0 assets
    assertEq(ytVault.convertToAssets(100 ether), 0);
  }

  function test_convertToAssets_afterYield() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // Add 50 ether yield
    asset.mint(address(vaultController), 50 ether);

    // PT: 1000 assets, 1000 shares -> 1:1
    assertEq(ptVault.convertToAssets(100 ether), 100 ether);
    // YT: 50 assets, 100 shares -> 0.5 assets per share
    assertEq(ytVault.convertToAssets(100 ether), 50 ether);
  }

  function test_totalAssets() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // Before yield: PT gets all assets, YT gets 0
    assertEq(ptVault.totalAssets(), 1000 ether);
    assertEq(ytVault.totalAssets(), 0);

    // Add yield
    asset.mint(address(vaultController), 50 ether);

    // After yield: PT still capped at principal, YT gets the rest
    assertEq(ptVault.totalAssets(), 1000 ether);
    assertEq(ytVault.totalAssets(), 50 ether);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     WITHDRAW TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdrawRevertsWhenLocked() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);

    vm.expectRevert(LibRequestErrors.CannotWithdraw.selector);
    ptVault.withdraw(100 ether, user, user);
    vm.stopPrank();
  }

  function test_withdraw_fullPrincipal() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // Unlock withdrawals
    vaultController.setCanWithdraw(true);

    vm.expectEmit(true, true, true, true, address(ptVault));
    emit Withdraw(user, user, user, 100 ether, 100 ether);

    vm.prank(user);
    uint256 shares = ptVault.withdraw(100 ether, user, user);

    assertEq(shares, 100 ether);
    assertEq(ptVault.balanceOf(user), 900 ether);
    assertEq(asset.balanceOf(user), 100 ether);
  }

  function test_maxWithdraw() public view {
    assertEq(ptVault.maxWithdraw(address(0x1)), 0);
    assertEq(ytVault.maxWithdraw(address(0x1)), 0);
  }

  function test_maxWithdraw_whenUnlocked() public {
    vaultController.setCanWithdraw(true);
    assertEq(ptVault.maxWithdraw(address(0x1)), type(uint256).max);
    assertEq(ytVault.maxWithdraw(address(0x1)), type(uint256).max);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      REDEEM TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_redeem_fullPrincipal() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    vm.expectEmit(true, true, true, true, address(ptVault));
    emit Withdraw(user, user, user, 100 ether, 100 ether);

    vm.prank(user);
    uint256 assets = ptVault.redeem(100 ether, user, user);

    assertEq(assets, 100 ether);
    assertEq(ptVault.balanceOf(user), 900 ether);
    assertEq(asset.balanceOf(user), 100 ether);
  }

  function test_redeem_yieldToken_noYield() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    vm.expectEmit(true, true, true, true, address(ytVault));
    emit Withdraw(user, user, user, 0, 50 ether);

    vm.prank(user);
    uint256 assets = ytVault.redeem(50 ether, user, user);

    // No yield, so YT gets 0 assets
    assertEq(assets, 0);
    assertEq(ytVault.balanceOf(user), 50 ether);
    assertEq(asset.balanceOf(user), 0);
  }

  function test_redeem_yieldToken_withYield() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // Add 50 ether yield
    asset.mint(address(vaultController), 50 ether);
    vaultController.setCanWithdraw(true);

    vm.expectEmit(true, true, true, true, address(ytVault));
    emit Withdraw(user, user, user, 25 ether, 50 ether);

    vm.prank(user);
    uint256 assets = ytVault.redeem(50 ether, user, user);

    // 50 shares out of 100 total, with 50 ether yield = 25 ether
    assertEq(assets, 25 ether);
    assertEq(ytVault.balanceOf(user), 50 ether);
    assertEq(asset.balanceOf(user), 25 ether);
  }

  function test_maxRedeem() public view {
    assertEq(ptVault.maxRedeem(address(0x1)), 0);
    assertEq(ytVault.maxRedeem(address(0x1)), 0);
  }

  function test_maxRedeem_whenUnlocked() public {
    vaultController.setCanWithdraw(true);
    assertEq(ptVault.maxRedeem(address(0x1)), type(uint256).max);
    assertEq(ytVault.maxRedeem(address(0x1)), type(uint256).max);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   INTEGRATION TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // Example from README: 1M principal, 100k yield, 900k assets (loss scenario)
  function test_integration_lossScenario() public {
    address user = address(0x1);
    uint256 principal = 1_000_000 ether;
    uint256 expectedYield = 100_000 ether;

    asset.mint(user, principal);

    vm.startPrank(user);
    asset.approve(address(vaultController), principal);
    vaultController.deposit(user, principal, expectedYield);
    vm.stopPrank();

    // Simulate loss: only 900k returned
    // Principal already deposited 1M, we need to burn 100k
    asset.burn(address(vaultController), 100_000 ether);

    vaultController.setCanWithdraw(true);

    // Total assets = 900k
    // Principal assets = min(900k, 1M) = 900k
    // Yield assets = 900k - 900k = 0
    // PT price = 900k / 1M = 0.9
    // YT price = 0 / 100k = 0

    assertEq(ptVault.totalAssets(), 900_000 ether);
    assertEq(ytVault.totalAssets(), 0);

    // Redeem all PT
    vm.prank(user);
    uint256 ptAssets = ptVault.redeem(principal, user, user);
    assertEq(ptAssets, 900_000 ether);

    // Redeem all YT
    vm.prank(user);
    uint256 ytAssets = ytVault.redeem(expectedYield, user, user);
    assertEq(ytAssets, 0);
  }

  // Example from README: 1M principal, 100k yield, 1M assets (break-even scenario)
  function test_integration_breakEvenScenario() public {
    address user = address(0x1);
    uint256 principal = 1_000_000 ether;
    uint256 expectedYield = 100_000 ether;

    asset.mint(user, principal);

    vm.startPrank(user);
    asset.approve(address(vaultController), principal);
    vaultController.deposit(user, principal, expectedYield);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    // Total assets = 1M (no yield)
    // Principal assets = min(1M, 1M) = 1M
    // Yield assets = 1M - 1M = 0
    // PT price = 1M / 1M = 1.0
    // YT price = 0 / 100k = 0

    assertEq(ptVault.totalAssets(), principal);
    assertEq(ytVault.totalAssets(), 0);

    vm.prank(user);
    uint256 ptAssets = ptVault.redeem(principal, user, user);
    assertEq(ptAssets, principal);

    vm.prank(user);
    uint256 ytAssets = ytVault.redeem(expectedYield, user, user);
    assertEq(ytAssets, 0);
  }

  // Example from README: 1M principal, 100k yield, 1.05M assets (partial yield scenario)
  function test_integration_partialYieldScenario() public {
    address user = address(0x1);
    uint256 principal = 1_000_000 ether;
    uint256 expectedYield = 100_000 ether;

    asset.mint(user, principal);

    vm.startPrank(user);
    asset.approve(address(vaultController), principal);
    vaultController.deposit(user, principal, expectedYield);
    vm.stopPrank();

    // Add 50k yield (total = 1.05M)
    asset.mint(address(vaultController), 50_000 ether);
    vaultController.setCanWithdraw(true);

    // Total assets = 1.05M
    // Principal assets = min(1.05M, 1M) = 1M
    // Yield assets = 1.05M - 1M = 50k
    // PT price = 1M / 1M = 1.0
    // YT price = 50k / 100k = 0.5

    assertEq(ptVault.totalAssets(), principal);
    assertEq(ytVault.totalAssets(), 50_000 ether);

    vm.prank(user);
    uint256 ptAssets = ptVault.redeem(principal, user, user);
    assertEq(ptAssets, principal);

    vm.prank(user);
    uint256 ytAssets = ytVault.redeem(expectedYield, user, user);
    assertEq(ytAssets, 50_000 ether);
  }

  // Example from README: 1M principal, 100k yield, 1.2M assets (full yield scenario)
  function test_integration_fullYieldScenario() public {
    address user = address(0x1);
    uint256 principal = 1_000_000 ether;
    uint256 expectedYield = 100_000 ether;

    asset.mint(user, principal);

    vm.startPrank(user);
    asset.approve(address(vaultController), principal);
    vaultController.deposit(user, principal, expectedYield);
    vm.stopPrank();

    // Add 200k yield (total = 1.2M)
    asset.mint(address(vaultController), 200_000 ether);
    vaultController.setCanWithdraw(true);

    // Total assets = 1.2M
    // Principal assets = min(1.2M, 1M) = 1M
    // Yield assets = 1.2M - 1M = 200k
    // PT price = 1M / 1M = 1.0
    // YT price = 200k / 100k = 2.0

    assertEq(ptVault.totalAssets(), principal);
    assertEq(ytVault.totalAssets(), 200_000 ether);

    vm.prank(user);
    uint256 ptAssets = ptVault.redeem(principal, user, user);
    assertEq(ptAssets, principal);

    vm.prank(user);
    uint256 ytAssets = ytVault.redeem(expectedYield, user, user);
    assertEq(ytAssets, 200_000 ether);
  }

  // Multiple users with different deposit amounts
  function test_integration_multipleUsers() public {
    address user1 = address(0x1);
    address user2 = address(0x2);

    // User 1: 1M principal, 100k yield
    asset.mint(user1, 1_000_000 ether);
    vm.startPrank(user1);
    asset.approve(address(vaultController), 1_000_000 ether);
    vaultController.deposit(user1, 1_000_000 ether, 100_000 ether);
    vm.stopPrank();

    // User 2: 500k principal, 50k yield
    asset.mint(user2, 500_000 ether);
    vm.startPrank(user2);
    asset.approve(address(vaultController), 500_000 ether);
    vaultController.deposit(user2, 500_000 ether, 50_000 ether);
    vm.stopPrank();

    // Total: 1.5M principal, 150k yield
    assertEq(ptVault.totalSupply(), 1_500_000 ether);
    assertEq(ytVault.totalSupply(), 150_000 ether);

    // Add 300k yield (total = 1.8M)
    asset.mint(address(vaultController), 300_000 ether);
    vaultController.setCanWithdraw(true);

    // Total assets = 1.8M
    // Principal assets = min(1.8M, 1.5M) = 1.5M
    // Yield assets = 1.8M - 1.5M = 300k
    // PT price = 1.5M / 1.5M = 1.0
    // YT price = 300k / 150k = 2.0

    // User 1 redeems all
    vm.prank(user1);
    uint256 user1PtAssets = ptVault.redeem(1_000_000 ether, user1, user1);
    assertEq(user1PtAssets, 1_000_000 ether);

    vm.prank(user1);
    uint256 user1YtAssets = ytVault.redeem(100_000 ether, user1, user1);
    assertEq(user1YtAssets, 200_000 ether);

    // User 2 redeems all
    vm.prank(user2);
    uint256 user2PtAssets = ptVault.redeem(500_000 ether, user2, user2);
    assertEq(user2PtAssets, 500_000 ether);

    vm.prank(user2);
    uint256 user2YtAssets = ytVault.redeem(50_000 ether, user2, user2);
    assertEq(user2YtAssets, 100_000 ether);
  }

  // Test burnAll with yield
  function test_integration_burnAllWithYield() public {
    address owner = address(0x1);
    address receiver = address(0x2);
    uint256 principal = 1_000_000 ether;
    uint256 expectedYield = 100_000 ether;

    asset.mint(owner, principal);

    vm.startPrank(owner);
    asset.approve(address(vaultController), principal);
    vaultController.deposit(owner, principal, expectedYield);
    vm.stopPrank();

    // Add 50k yield
    asset.mint(address(vaultController), 50_000 ether);
    vaultController.setCanWithdraw(true);

    vm.prank(owner);
    (uint256 ptShares, uint256 ytShares, uint256 pAssets, uint256 yAssets) = vaultController.burnAll(owner, receiver);

    assertEq(ptShares, principal);
    assertEq(ytShares, expectedYield);
    assertEq(pAssets, principal);
    assertEq(yAssets, 50_000 ether);
    assertEq(asset.balanceOf(receiver), principal + 50_000 ether);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       FUZZ TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_principalRedemption(uint128 principal, uint128 yieldExpected, uint128 actualAssets) public {
    vm.assume(principal > 0);
    vm.assume(yieldExpected > 0);

    address user = address(0x1);
    asset.mint(user, principal);

    vm.startPrank(user);
    asset.approve(address(vaultController), principal);
    vaultController.deposit(user, principal, yieldExpected);
    vm.stopPrank();

    // Adjust assets to actualAssets
    uint256 currentAssets = asset.balanceOf(address(vaultController));
    if (actualAssets > currentAssets) {
      asset.mint(address(vaultController), actualAssets - currentAssets);
    } else if (actualAssets < currentAssets) {
      // Only burn if we have enough assets
      uint256 toBurn = currentAssets - actualAssets;
      if (toBurn <= currentAssets) {
        asset.burn(address(vaultController), toBurn);
      }
    }

    vaultController.setCanWithdraw(true);

    // Get actual assets after adjustment
    uint256 finalAssets = asset.balanceOf(address(vaultController));

    // Calculate expected values
    uint256 principalAssets = finalAssets < principal ? finalAssets : principal;
    uint256 yieldAssets = finalAssets > principal ? finalAssets - principal : 0;

    assertEq(ptVault.totalAssets(), principalAssets);
    assertEq(ytVault.totalAssets(), yieldAssets);

    // Test partial redemption
    uint128 redeemAmount = principal / 4;
    if (redeemAmount > 0 && principalAssets > 0) {
      vm.prank(user);
      uint256 ptAssets = ptVault.redeem(redeemAmount, user, user);
      uint256 expectedPtAssets = uint256(redeemAmount) * principalAssets / principal;
      assertApproxEqAbs(ptAssets, expectedPtAssets, 1);
    }
  }

  function testFuzz_yieldRedemption(uint128 principal, uint128 yieldExpected, uint128 yieldActual) public {
    vm.assume(principal > 0);
    vm.assume(yieldExpected > 0);
    vm.assume(yieldActual < type(uint128).max - principal);

    address user = address(0x1);
    asset.mint(user, principal);

    vm.startPrank(user);
    asset.approve(address(vaultController), principal);
    vaultController.deposit(user, principal, yieldExpected);
    vm.stopPrank();

    // Add yield
    asset.mint(address(vaultController), yieldActual);
    vaultController.setCanWithdraw(true);

    // Principal gets full amount, yield gets the rest
    assertEq(ptVault.totalAssets(), principal);
    assertEq(ytVault.totalAssets(), yieldActual);

    // Redeem some yield tokens
    uint128 redeemAmount = yieldExpected / 4;
    if (redeemAmount > 0) {
      vm.prank(user);
      uint256 ytAssets = ytVault.redeem(redeemAmount, user, user);
      uint256 expectedYtAssets = uint256(redeemAmount) * yieldActual / yieldExpected;
      assertApproxEqAbs(ytAssets, expectedYtAssets, 1);
    }
  }

  function testFuzz_multiUserScenario(
    uint128 principal1,
    uint128 yield1,
    uint128 principal2,
    uint128 yield2,
    uint128 totalYield
  ) public {
    vm.assume(principal1 > 0 && principal1 < type(uint128).max / 2);
    vm.assume(principal2 > 0 && principal2 < type(uint128).max / 2);
    vm.assume(yield1 > 0 && yield1 < type(uint128).max / 2);
    vm.assume(yield2 > 0 && yield2 < type(uint128).max / 2);
    vm.assume(totalYield < type(uint128).max);

    address user1 = address(0x1);
    address user2 = address(0x2);

    // User 1 deposits
    asset.mint(user1, principal1);
    vm.startPrank(user1);
    asset.approve(address(vaultController), principal1);
    vaultController.deposit(user1, principal1, yield1);
    vm.stopPrank();

    // User 2 deposits
    asset.mint(user2, principal2);
    vm.startPrank(user2);
    asset.approve(address(vaultController), principal2);
    vaultController.deposit(user2, principal2, yield2);
    vm.stopPrank();

    uint256 totalPrincipal = uint256(principal1) + principal2;
    uint256 totalYieldShares = uint256(yield1) + yield2;

    assertEq(ptVault.totalSupply(), totalPrincipal);
    assertEq(ytVault.totalSupply(), totalYieldShares);

    // Add yield
    asset.mint(address(vaultController), totalYield);
    vaultController.setCanWithdraw(true);

    // Verify total assets
    assertEq(ptVault.totalAssets(), totalPrincipal);
    assertEq(ytVault.totalAssets(), totalYield);

    // User 1 redeems proportional share
    if (principal1 > 0) {
      vm.prank(user1);
      uint256 user1Assets = ptVault.redeem(principal1, user1, user1);
      assertEq(user1Assets, principal1);
    }

    if (yield1 > 0 && totalYield > 0) {
      vm.prank(user1);
      uint256 user1Yield = ytVault.redeem(yield1, user1, user1);
      uint256 expectedYield = uint256(yield1) * totalYield / totalYieldShares;
      assertApproxEqAbs(user1Yield, expectedYield, 1);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   COVERAGE IMPROVEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_previewDeposit_alwaysReturnsZero() public {
    // Before any deposits
    assertEq(ptVault.previewDeposit(100 ether), 0);
    assertEq(ytVault.previewDeposit(100 ether), 0);

    // After deposits (should still return 0 since deposit() always reverts)
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    assertEq(ptVault.previewDeposit(100 ether), 0);
    assertEq(ytVault.previewDeposit(100 ether), 0);

    // After yield accrual (should still return 0)
    asset.mint(address(vaultController), 50 ether);
    assertEq(ptVault.previewDeposit(100 ether), 0);
    assertEq(ytVault.previewDeposit(50 ether), 0);
  }

  function test_previewMint_alwaysReturnsZero() public {
    // Before any deposits
    assertEq(ptVault.previewMint(100 ether), 0);
    assertEq(ytVault.previewMint(100 ether), 0);

    // After deposits (should still return 0 since mint() always reverts)
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    assertEq(ptVault.previewMint(100 ether), 0);
    assertEq(ytVault.previewMint(100 ether), 0);

    // After yield accrual (should still return 0)
    asset.mint(address(vaultController), 50 ether);
    assertEq(ptVault.previewMint(100 ether), 0);
    assertEq(ytVault.previewMint(100 ether), 0);
  }

  function test_previewWithdraw() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // PT: 1:1 ratio
    assertEq(ptVault.previewWithdraw(100 ether), 100 ether);
    // YT: 0 assets -> type(uint256).max shares needed
    assertEq(ytVault.previewWithdraw(100 ether), type(uint256).max);
  }

  function test_previewRedeem() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // PT: 1:1 ratio
    assertEq(ptVault.previewRedeem(100 ether), 100 ether);
    // YT: 0 assets backing shares
    assertEq(ytVault.previewRedeem(100 ether), 0);
  }

  function test_emitDeposit_unauthorized() public {
    address randomCaller = address(0x999);

    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.Unauthorized.selector);
    ptVault._emitDeposit(address(1), address(2), 100 ether, 100 ether);

    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.Unauthorized.selector);
    ytVault._emitDeposit(address(1), address(2), 100 ether, 100 ether);
  }

  function test_emitWithdraw_unauthorized() public {
    address randomCaller = address(0x999);

    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.Unauthorized.selector);
    ptVault._emitWithdraw(address(1), address(2), address(3), 100 ether, 100 ether);

    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.Unauthorized.selector);
    ytVault._emitWithdraw(address(1), address(2), address(3), 100 ether, 100 ether);
  }

  function test_withdraw_yieldToken() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // Add yield
    asset.mint(address(vaultController), 50 ether);
    vaultController.setCanWithdraw(true);

    // Withdraw 25 ether worth of yield (50 shares out of 100, with 50 ether yield = 25)
    vm.expectEmit(true, true, true, true, address(ytVault));
    emit Withdraw(user, user, user, 25 ether, 50 ether);

    vm.prank(user);
    uint256 shares = ytVault.withdraw(25 ether, user, user);

    assertEq(shares, 50 ether); // 25 assets / 0.5 = 50 shares
    assertEq(ytVault.balanceOf(user), 50 ether);
    assertEq(asset.balanceOf(user), 25 ether);
  }

  function test_redeemRevertsWhenLocked() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);

    vm.expectRevert(LibRequestErrors.CannotWithdraw.selector);
    ptVault.redeem(100 ether, user, user);
    vm.stopPrank();
  }

  function test_withdrawWithAllowance() public {
    address owner = address(0x1);
    address spender = address(0x2);
    address receiver = address(0x3);

    asset.mint(owner, 1000 ether);

    vm.startPrank(owner);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(owner, 1000 ether, 100 ether);
    vaultController.approveBatch(spender, 500 ether, 50 ether);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    vm.prank(spender);
    uint256 shares = ptVault.withdraw(200 ether, receiver, owner);

    assertEq(shares, 200 ether);
    assertEq(ptVault.balanceOf(owner), 800 ether);
    assertEq(asset.balanceOf(receiver), 200 ether);
  }

  function test_redeemWithAllowance() public {
    address owner = address(0x1);
    address spender = address(0x2);
    address receiver = address(0x3);

    asset.mint(owner, 1000 ether);

    vm.startPrank(owner);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(owner, 1000 ether, 100 ether);
    vaultController.approveBatch(spender, 500 ether, 50 ether);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    vm.prank(spender);
    uint256 assets = ptVault.redeem(200 ether, receiver, owner);

    assertEq(assets, 200 ether);
    assertEq(ptVault.balanceOf(owner), 800 ether);
    assertEq(asset.balanceOf(receiver), 200 ether);
  }

  function test_burnAllWithAllowance() public {
    address owner = address(0x1);
    address spender = address(0x2);
    address receiver = address(0x3);

    asset.mint(owner, 1000 ether);

    vm.startPrank(owner);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(owner, 1000 ether, 100 ether);
    // Approve max allowance for spender
    vaultController.approveBatch(spender, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    asset.mint(address(vaultController), 50 ether);
    vaultController.setCanWithdraw(true);

    vm.prank(spender);
    (uint256 ptShares, uint256 ytShares, uint256 pAssets, uint256 yAssets) = vaultController.burnAll(owner, receiver);

    assertEq(ptShares, 1000 ether);
    assertEq(ytShares, 100 ether);
    assertEq(pAssets, 1000 ether);
    assertEq(yAssets, 50 ether);
    assertEq(asset.balanceOf(receiver), 1050 ether);
    assertEq(ptVault.balanceOf(owner), 0);
    assertEq(ytVault.balanceOf(owner), 0);
  }

  function test_withdrawExternal_unauthorized() public {
    address randomCaller = address(0x999);
    address user = address(0x1);

    // Try to call _withdraw directly from a non-vault contract
    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.UnauthorizedTokenContract.selector);
    vaultController._withdraw(user, 100 ether, user, user, false);

    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.UnauthorizedTokenContract.selector);
    vaultController._withdraw(user, 100 ether, user, user, true);
  }

  function test_redeemExternal_unauthorized() public {
    address randomCaller = address(0x999);
    address user = address(0x1);

    // Try to call _redeem directly from a non-vault contract
    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.UnauthorizedTokenContract.selector);
    vaultController._redeem(user, 100 ether, user, user, false);

    vm.prank(randomCaller);
    vm.expectRevert(LibRequestErrors.UnauthorizedTokenContract.selector);
    vaultController._redeem(user, 100 ether, user, user, true);
  }

  function test_convertToShares_zeroState() public view {
    // Before any deposit, conversions should use initial values
    // PT: 1:1 conversion
    (uint256 ptShares, uint256 ytShares) = vaultController.convertToShares(100 ether, 0);
    assertEq(ptShares, 100 ether);
    assertEq(ytShares, 0);

    // YT with non-zero assets but no supply returns max
    (ptShares, ytShares) = vaultController.convertToShares(0, 100 ether);
    assertEq(ptShares, 0);
    assertEq(ytShares, type(uint256).max);
  }

  function test_convertToAssets_zeroState() public view {
    // Before any deposit, conversions should use initial values
    // PT: 1:1 conversion
    (uint256 pAssets, uint256 yAssets) = vaultController.convertToAssets(100 ether, 0);
    assertEq(pAssets, 100 ether);
    assertEq(yAssets, 0);

    // YT with shares but no assets returns 0
    (pAssets, yAssets) = vaultController.convertToAssets(0, 100 ether);
    assertEq(pAssets, 0);
    assertEq(yAssets, 0);
  }

  function test_totalAssetsController() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    (uint256 pAssets, uint256 yAssets) = vaultController.totalAssets();
    assertEq(pAssets, 1000 ether);
    assertEq(yAssets, 0);

    // Add yield
    asset.mint(address(vaultController), 50 ether);

    (pAssets, yAssets) = vaultController.totalAssets();
    assertEq(pAssets, 1000 ether);
    assertEq(yAssets, 50 ether);
  }

  function test_withdrawZeroAssets() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    // Withdraw 0 assets - should succeed
    vm.prank(user);
    uint256 shares = ptVault.withdraw(0, user, user);
    assertEq(shares, 0);
    assertEq(ptVault.balanceOf(user), 1000 ether);
  }

  function test_redeemZeroShares() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    // Redeem 0 shares - should succeed
    vm.prank(user);
    uint256 assets = ptVault.redeem(0, user, user);
    assertEq(assets, 0);
    assertEq(ptVault.balanceOf(user), 1000 ether);
  }

  function test_depositOnlyYT() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    // Deposit with 0 PT shares
    vaultController.deposit(user, 0, 100 ether);
    vm.stopPrank();

    assertEq(ptVault.balanceOf(user), 0);
    assertEq(ytVault.balanceOf(user), 100 ether);
  }

  function test_depositOnlyPT() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    // Deposit with 0 YT shares
    vaultController.deposit(user, 500 ether, 0);
    vm.stopPrank();

    assertEq(ptVault.balanceOf(user), 500 ether);
    assertEq(ytVault.balanceOf(user), 0);
  }

  function test_burnAllZeroBalance() public {
    address owner = address(0x1);
    address receiver = address(0x2);

    vaultController.setCanWithdraw(true);

    // burnAll with no balance
    vm.prank(owner);
    (uint256 ptShares, uint256 ytShares, uint256 pAssets, uint256 yAssets) = vaultController.burnAll(owner, receiver);

    assertEq(ptShares, 0);
    assertEq(ytShares, 0);
    assertEq(pAssets, 0);
    assertEq(yAssets, 0);
  }

  function test_withdrawalOperation_onlyPTShares() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    // Only deposit PT shares
    vaultController.deposit(user, 1000 ether, 0);
    vm.stopPrank();

    vaultController.setCanWithdraw(true);

    // Withdraw PT only (no YT)
    vm.expectEmit(true, true, true, true, address(ptVault));
    emit Withdraw(user, user, user, 500 ether, 500 ether);

    vm.prank(user);
    uint256 shares = ptVault.withdraw(500 ether, user, user);

    assertEq(shares, 500 ether);
    assertEq(ptVault.balanceOf(user), 500 ether);
    assertEq(asset.balanceOf(user), 500 ether);
  }

  function test_withdrawalOperation_onlyYTShares() public {
    address user = address(0x1);
    asset.mint(user, 1000 ether);

    vm.startPrank(user);
    asset.approve(address(vaultController), 1000 ether);
    // Deposit PT and YT
    vaultController.deposit(user, 1000 ether, 100 ether);
    vm.stopPrank();

    // Add yield
    asset.mint(address(vaultController), 100 ether);
    vaultController.setCanWithdraw(true);

    // Redeem YT only
    vm.expectEmit(true, true, true, true, address(ytVault));
    emit Withdraw(user, user, user, 100 ether, 100 ether);

    vm.prank(user);
    uint256 assets = ytVault.redeem(100 ether, user, user);

    assertEq(assets, 100 ether);
    assertEq(ytVault.balanceOf(user), 0);
    assertEq(asset.balanceOf(user), 100 ether);
  }

  function test_inheritance_ControlledToken() public {
    // ControlledVault inherits from ControlledToken
    // Test ERC20 functions via the vault

    address user1 = address(0x1);
    address user2 = address(0x2);
    asset.mint(user1, 1000 ether);

    vm.startPrank(user1);
    asset.approve(address(vaultController), 1000 ether);
    vaultController.deposit(user1, 1000 ether, 100 ether);

    // Test ERC20 transfer
    ptVault.transfer(user2, 100 ether);
    assertEq(ptVault.balanceOf(user1), 900 ether);
    assertEq(ptVault.balanceOf(user2), 100 ether);

    // Test ERC20 approve and transferFrom
    ptVault.approve(user2, 200 ether);
    vm.stopPrank();

    vm.prank(user2);
    ptVault.transferFrom(user1, user2, 150 ether);
    assertEq(ptVault.balanceOf(user1), 750 ether);
    assertEq(ptVault.balanceOf(user2), 250 ether);
  }
}
