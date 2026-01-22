// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibManagerStorageHarness} from "test/mock/libs/LibManagerStorageHarness.sol";
import {MockBorrowPosition} from "test/mock/borrow/MockBorrowPosition.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {VIRTUAL_SHARES, VIRTUAL_ASSETS} from "src/libs/manager/LibConstants.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibViewTest
/// @notice Unit tests for manager LibView library
contract LibViewTest is Test {
  using FixedPointMathLib for uint256;

  LibManagerStorageHarness harness;
  MockERC20 collateralToken;
  MockERC20 debtToken;

  function setUp() public {
    harness = new LibManagerStorageHarness();
    collateralToken = new MockERC20("Collateral", "COL", 18);
    debtToken = new MockERC20("Debt", "DEBT", 18);

    harness.setMetadata("Test PM", "TPM", 18, address(collateralToken), address(debtToken));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  collateralAmount TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_collateralAmount_empty() public view {
    assertEq(harness.collateralAmount(), 0);
  }

  function testFuzz_collateralAmount(uint128[] calldata amounts) public {
    vm.assume(amounts.length <= 10);

    uint256 expected = 0;

    for (uint256 i = 0; i < amounts.length; i++) {
      MockBorrowPosition module = new MockBorrowPosition(address(collateralToken), address(debtToken));
      module.setTotalCollateral(amounts[i]);
      harness.addBorrowModule(address(module));
      expected += amounts[i];
    }

    assertEq(harness.collateralAmount(), expected);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               collateralAmountQuoted TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_collateralAmountQuoted_empty() public view {
    assertEq(harness.collateralAmountQuoted(), 0);
  }

  function test_collateralAmountQuoted_multipleModules() public {
    MockBorrowPosition module1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    MockBorrowPosition module2 = new MockBorrowPosition(address(collateralToken), address(debtToken));

    module1.setTotalCollateralQuoted(150e18);
    module2.setTotalCollateralQuoted(250e18);

    harness.addBorrowModule(address(module1));
    harness.addBorrowModule(address(module2));

    assertEq(harness.collateralAmountQuoted(), 400e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     debtAmount TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_debtAmount_empty() public view {
    assertEq(harness.debtAmount(), 0);
  }

  function testFuzz_debtAmount(uint128[] calldata amounts) public {
    vm.assume(amounts.length <= 10);

    uint256 expected = 0;

    for (uint256 i = 0; i < amounts.length; i++) {
      MockBorrowPosition module = new MockBorrowPosition(address(collateralToken), address(debtToken));
      module.setTotalBorrowed(amounts[i]);
      harness.addBorrowModule(address(module));
      expected += amounts[i];
    }

    assertEq(harness.debtAmount(), expected);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     totalAssets TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_totalAssets_empty() public view {
    assertEq(harness.totalAssets(), 0);
  }

  function testFuzz_totalAssets(uint128 collateralQuoted, uint128 debt) public {
    MockBorrowPosition module = new MockBorrowPosition(address(collateralToken), address(debtToken));
    module.setTotalCollateralQuoted(collateralQuoted);
    module.setTotalBorrowed(debt);

    harness.addBorrowModule(address(module));

    uint256 expected = collateralQuoted > debt ? collateralQuoted - debt : 0;
    assertEq(harness.totalAssets(), expected);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   convertToShares TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_convertToShares(uint96 assets, uint96 totalSupply, uint96 totalAssets) public view {
    // Using uint96 to avoid mulDiv overflow when assets * (totalSupply + VIRTUAL_SHARES) exceeds uint256
    uint256 shares = harness.convertToShares(assets, totalSupply, totalAssets);

    // Verify the formula: shares = assets * (totalSupply + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)
    uint256 expected =
      uint256(assets).mulDiv(uint256(totalSupply) + VIRTUAL_SHARES, uint256(totalAssets) + VIRTUAL_ASSETS);
    assertEq(shares, expected);
  }

  function test_convertToShares_preventInflationAttack() public view {
    // Test that virtual shares/assets prevent inflation attack
    // Attacker deposits 1 wei, then donates large amount

    // First deposit: 1 wei with 0 supply
    uint256 attackerShares = harness.convertToShares(1, 0, 0);
    // attackerShares = 1 * VIRTUAL_SHARES / VIRTUAL_ASSETS = 1

    // Attacker donates 1e18 tokens, making totalAssets = 1 + 1e18
    // Victim deposits 1e18
    uint256 victimShares = harness.convertToShares(1e18, attackerShares, 1 + 1e18);

    // Without virtual offset, victim would get 0 shares
    // With virtual offset, victim still gets meaningful shares
    assertGt(victimShares, 0, "Victim should get shares");
  }
}
