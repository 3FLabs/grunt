// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";

/// @title PositionManagerEdgeCasesTest
/// @notice Tests for PositionManager edge cases, underwater positions, and inflation attack protection
contract PositionManagerEdgeCasesTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   UNDERWATER POSITION TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_totalAssets_underwaterPosition() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Verify initial state
    uint256 initialAssets = positionManager.totalAssets();
    assertGt(initialAssets, 0, "Initial assets should be positive");

    // Crash the oracle price to make position underwater
    // debt = 5000, collateral = 10000 at 1:1 price = 10000 quoted
    // At 0.4:1 price, collateral = 4000 quoted < 5000 debt
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);

    // totalAssets should return 0, not revert
    uint256 underwaterAssets = positionManager.totalAssets();
    assertEq(underwaterAssets, 0, "Underwater position should return 0 assets");
  }

  function test_totalAssets_exactlyAtWater() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Set price so collateral exactly equals debt
    // debt = 5000, collateral = 10000
    // At 0.5:1 price, collateral = 5000 quoted = 5000 debt
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 50 / 100);

    uint256 assets = positionManager.totalAssets();
    assertEq(assets, 0, "Position at water should return 0 assets");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              INFLATION ATTACK PROTECTION TESTS              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Test that classic inflation attack is mitigated by virtual offset
  /// @dev Attack scenario: Attacker deposits 1 wei, donates large amount, victim deposits, attacker profits
  function test_inflationAttack_mitigatedByVirtualOffset() public {
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    // Grant roles
    vm.startPrank(owner);
    positionManager.grantRoles(attacker, _ROLE_MINTER);
    positionManager.grantRoles(victim, _ROLE_MINTER);
    vm.stopPrank();

    // Setup approvals
    vm.startPrank(attacker);
    collateralToken.approve(address(positionManager), type(uint256).max);
    debtToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(victim);
    collateralToken.approve(address(positionManager), type(uint256).max);
    debtToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    // Step 1: Attacker makes tiny first deposit (1 wei collateral, no debt)
    uint256 attackerDeposit = 1;
    collateralToken.setBalance(attacker, attackerDeposit);
    vm.prank(attacker);
    int256 attackerShares = positionManager.deposit(attackerDeposit, 0);
    assertGt(attackerShares, 0, "Attacker should get shares");

    uint256 attackerSharesBefore = uint256(attackerShares);

    // Step 2: Attacker tries to inflate share price by donating directly to the position
    // In a vulnerable vault, this would inflate the share price
    uint256 donationAmount = 1000e18;
    collateralToken.setBalance(attacker, donationAmount);

    // Donate directly to the borrow position (bypassing the manager)
    vm.prank(attacker);
    collateralToken.transfer(address(borrowPosition1), donationAmount);

    // Note: The donation goes to the position but doesn't affect share calculation
    // because shares are based on what's tracked in Morpho, not raw balance

    // Step 3: Victim deposits a normal amount
    uint256 victimDeposit = 10_000e18;
    collateralToken.setBalance(victim, victimDeposit);
    vm.prank(victim);
    int256 victimShares = positionManager.deposit(victimDeposit, 0);

    // Victim should get fair shares (not rounded to 0 or tiny amount)
    assertGt(victimShares, 0, "Victim should get shares");

    // The victim's shares should be proportional to their deposit
    // With virtual offset, even if attack succeeded, victim still gets reasonable shares
    uint256 victimSharesUint = uint256(victimShares);

    // Victim deposited 10_000e18 vs attacker's 1 wei
    // Victim should have vastly more shares
    assertGt(victimSharesUint, attackerSharesBefore * 1000, "Victim should have proportionally more shares");

    // Step 4: Check that attacker can't steal victim's funds
    // Attacker burns all their shares
    _mintDebt(attacker, 1e18); // In case any debt was accrued
    vm.prank(attacker);
    (uint256 attackerCollateralBack,) = positionManager.burn(attackerSharesBefore);

    // Attacker should get back approximately what they deposited (1 wei), not the donation
    // Due to virtual offset, attacker's profit is bounded
    assertLt(attackerCollateralBack, donationAmount / 10, "Attacker shouldn't profit significantly from donation");
  }

  /// @notice Test that first depositor doesn't get unfair advantage
  function test_inflationAttack_firstDepositorFairness() public {
    address firstDepositor = makeAddr("firstDepositor");
    address secondDepositor = makeAddr("secondDepositor");

    vm.startPrank(owner);
    positionManager.grantRoles(firstDepositor, _ROLE_MINTER);
    positionManager.grantRoles(secondDepositor, _ROLE_MINTER);
    vm.stopPrank();

    vm.startPrank(firstDepositor);
    collateralToken.approve(address(positionManager), type(uint256).max);
    debtToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(secondDepositor);
    collateralToken.approve(address(positionManager), type(uint256).max);
    debtToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    // First depositor deposits 1000e18
    uint256 depositAmount = 1000e18;
    collateralToken.setBalance(firstDepositor, depositAmount);
    vm.prank(firstDepositor);
    int256 firstShares = positionManager.deposit(depositAmount, 0);

    // Second depositor deposits the same amount
    collateralToken.setBalance(secondDepositor, depositAmount);
    vm.prank(secondDepositor);
    int256 secondShares = positionManager.deposit(depositAmount, 0);

    // Both should get similar shares (not exactly equal due to virtual offset effect on first deposit)
    uint256 firstSharesUint = uint256(firstShares);
    uint256 secondSharesUint = uint256(secondShares);

    // Second depositor should get very close to what first depositor got
    // Allow 1% tolerance for virtual offset effect
    assertApproxEqRel(secondSharesUint, firstSharesUint, 0.01e18, "Second depositor should get similar shares");
  }

  /// @notice Test round-trip: deposit and immediately burn shouldn't lose significant value
  function test_inflationAttack_roundTripValuePreservation() public {
    uint256 depositCollateral = 10_000e18;
    uint256 depositDebt = 5_000e18;

    _mintCollateral(minter, depositCollateral);

    // Deposit
    vm.prank(minter);
    int256 shares = positionManager.deposit(depositCollateral, depositDebt);
    uint256 sharesUint = uint256(shares);

    // Immediately burn all shares
    _mintDebt(minter, depositDebt * 2); // Extra for any rounding
    vm.prank(minter);
    (uint256 collateralBack, uint256 debtToPay) = positionManager.burn(sharesUint);

    // Should get back almost all collateral (minus tiny rounding)
    // Allow 0.01% loss for rounding
    assertApproxEqRel(collateralBack, depositCollateral, 0.0001e18, "Should get back ~100% of collateral");

    // Should repay approximately the same debt
    assertApproxEqRel(debtToPay, depositDebt, 0.0001e18, "Should repay ~100% of debt");
  }

  /// @notice Test that very small deposits still get shares (virtual offset prevents 0 shares)
  function test_inflationAttack_smallDepositGetsShares() public {
    // First, make a large deposit to establish a high share price
    _mintCollateral(minter, 1_000_000e18);
    vm.prank(minter);
    positionManager.deposit(1_000_000e18, 0);

    // Now a small depositor tries to deposit
    address smallDepositor = makeAddr("smallDepositor");
    vm.prank(owner);
    positionManager.grantRoles(smallDepositor, _ROLE_MINTER);

    vm.startPrank(smallDepositor);
    collateralToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    // Deposit a small amount (1e6 wei = 0.000001 tokens if 18 decimals)
    uint256 smallDeposit = 1e6;
    collateralToken.setBalance(smallDepositor, smallDeposit);

    vm.prank(smallDepositor);
    int256 smallShares = positionManager.deposit(smallDeposit, 0);

    // Should still get some shares due to virtual offset protection
    assertGt(smallShares, 0, "Small deposit should still get shares");
  }

  /// @notice Test that multiple small deposits accumulate fairly
  function test_inflationAttack_multipleSmallDeposits() public {
    address[] memory depositors = new address[](5);
    uint256 depositAmount = 100e18;

    // Create 5 depositors
    for (uint256 i = 0; i < 5; i++) {
      depositors[i] = makeAddr(string(abi.encodePacked("depositor", i)));
      vm.prank(owner);
      positionManager.grantRoles(depositors[i], _ROLE_MINTER);

      vm.startPrank(depositors[i]);
      collateralToken.approve(address(positionManager), type(uint256).max);
      debtToken.approve(address(positionManager), type(uint256).max);
      vm.stopPrank();
    }

    uint256[] memory shares = new uint256[](5);

    // Each depositor deposits the same amount
    for (uint256 i = 0; i < 5; i++) {
      collateralToken.setBalance(depositors[i], depositAmount);
      vm.prank(depositors[i]);
      int256 s = positionManager.deposit(depositAmount, 0);
      shares[i] = uint256(s);
    }

    // All should have similar shares (later depositors might have slightly fewer due to virtual offset dilution)
    for (uint256 i = 1; i < 5; i++) {
      // Allow 5% variance
      assertApproxEqRel(shares[i], shares[0], 0.05e18, "All depositors should get similar shares");
    }

    // Now each burns their shares - should get back fair amounts
    for (uint256 i = 0; i < 5; i++) {
      vm.prank(depositors[i]);
      (uint256 collateralBack,) = positionManager.burn(shares[i]);

      // Should get back close to what they deposited
      assertApproxEqRel(collateralBack, depositAmount, 0.05e18, "Should get back ~100% of deposit");
    }
  }

  /// @notice Fuzz test: deposit and burn should preserve value within acceptable bounds
  function testFuzz_inflationAttack_valuePreservation(uint256 depositAmount) public {
    // Bound to reasonable amounts
    depositAmount = bound(depositAmount, 1e6, 1_000_000e18);

    _mintCollateral(minter, depositAmount);

    vm.prank(minter);
    int256 shares = positionManager.deposit(depositAmount, 0);

    if (shares <= 0) return; // Skip if no shares minted

    uint256 sharesUint = uint256(shares);

    vm.prank(minter);
    (uint256 collateralBack,) = positionManager.burn(sharesUint);

    // Should get back at least 99.99% of deposit (0.01% max loss to rounding)
    assertGe(collateralBack, depositAmount * 9999 / 10000, "Should preserve at least 99.99% of value");

    // Should not get more than deposited (no free money)
    assertLe(collateralBack, depositAmount, "Should not gain value from round trip");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ZERO SHARES TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Test ZeroShares revert when minting results in 0 shares due to donation attack
  /// @dev Covers line 325: if (sharesToMint == 0) revert ZeroShares()
  /// By donating assets directly to inflate totalAssets without minting shares,
  /// a tiny deposit can result in 0 shares due to rounding.
  function test_deposit_revertOnZeroSharesAfterDonation() public {
    // Step 1: Initial small deposit to establish some shares
    uint256 initialDeposit = 1e6; // Small deposit
    _mintCollateral(minter, initialDeposit);
    vm.prank(minter);
    positionManager.deposit(initialDeposit, 0);

    uint256 totalSupplyBefore = positionManager.totalSupply();
    uint256 totalAssetsBefore = positionManager.totalAssets();

    // Step 2: Donate massive amount directly to borrow position (bypassing PositionManager)
    // This inflates totalAssets without minting shares
    uint256 donationAmount = 1e30; // Massive donation

    // Give PositionManager the tokens and have it supply directly
    collateralToken.setBalance(address(positionManager), donationAmount);
    vm.startPrank(address(positionManager));
    collateralToken.approve(address(borrowPosition1), donationAmount);
    borrowPosition1.supplyCollateral(donationAmount);
    vm.stopPrank();

    // Verify totalAssets increased but totalSupply unchanged
    assertEq(positionManager.totalSupply(), totalSupplyBefore, "Total supply should be unchanged");
    assertGt(
      positionManager.totalAssets(), totalAssetsBefore + donationAmount / 2, "Total assets should have increased"
    );

    // Step 3: Try to deposit just 1 wei - should result in 0 shares and revert
    // shares = 1 * (totalSupply + 1e6) / (totalAssets + 1)
    // With totalAssets ≈ 1e30 and totalSupply ≈ 1e6, shares ≈ 0
    _mintCollateral(minter, 1);

    vm.prank(minter);
    vm.expectRevert(IPositionManager.ZeroShares.selector);
    positionManager.deposit(1, 0);
  }

  /// @notice Test ZeroShares revert when burning results in 0 shares due to donation attack
  /// @dev Covers line 334: if (sharesToBurn == 0) revert ZeroShares()
  function test_withdraw_revertOnZeroSharesAfterDonation() public {
    // Step 1: Initial deposit with debt
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Step 2: Donate massive amount to inflate totalAssets
    uint256 donationAmount = 1e30;

    // Give PositionManager the tokens and have it supply directly
    collateralToken.setBalance(address(positionManager), donationAmount);
    vm.startPrank(address(positionManager));
    collateralToken.approve(address(borrowPosition1), donationAmount);
    borrowPosition1.supplyCollateral(donationAmount);
    vm.stopPrank();

    // Step 3: Try to withdraw just 1 wei of collateral
    // The asset change is tiny relative to totalAssets, so shares calculation rounds to 0
    vm.prank(minter);
    vm.expectRevert(IPositionManager.ZeroShares.selector);
    positionManager.withdraw(1, 0);
  }
}
