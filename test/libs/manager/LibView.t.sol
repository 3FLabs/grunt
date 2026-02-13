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

  function test_totalAssets_badDebtPositionTreatedAsZero() public {
    // Position 1: bad debt (debt > collateral)
    MockBorrowPosition badModule = new MockBorrowPosition(address(collateralToken), address(debtToken));
    badModule.setTotalCollateralQuoted(100e18);
    badModule.setTotalBorrowed(200e18);

    // Position 2: healthy (collateral > debt)
    MockBorrowPosition healthyModule = new MockBorrowPosition(address(collateralToken), address(debtToken));
    healthyModule.setTotalCollateralQuoted(500e18);
    healthyModule.setTotalBorrowed(100e18);

    harness.addBorrowModule(address(badModule));
    harness.addBorrowModule(address(healthyModule));

    // Bad debt position contributes 0 (not -100), healthy contributes 400
    // Total = 0 + 400 = 400 (not 600 - 300 = 300)
    assertEq(harness.totalAssets(), 400e18);
  }

  function test_totalAssets_allPositionsBadDebt() public {
    MockBorrowPosition module1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    module1.setTotalCollateralQuoted(50e18);
    module1.setTotalBorrowed(100e18);

    MockBorrowPosition module2 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    module2.setTotalCollateralQuoted(30e18);
    module2.setTotalBorrowed(80e18);

    harness.addBorrowModule(address(module1));
    harness.addBorrowModule(address(module2));

    // Both positions have bad debt, total should be 0
    assertEq(harness.totalAssets(), 0);
  }

  function test_totalAssets_mixedPositionsWithZeroDebt() public {
    // Position with no debt
    MockBorrowPosition noDebtModule = new MockBorrowPosition(address(collateralToken), address(debtToken));
    noDebtModule.setTotalCollateralQuoted(300e18);
    noDebtModule.setTotalBorrowed(0);

    // Position with bad debt
    MockBorrowPosition badModule = new MockBorrowPosition(address(collateralToken), address(debtToken));
    badModule.setTotalCollateralQuoted(10e18);
    badModule.setTotalBorrowed(50e18);

    // Position with equal collateral and debt
    MockBorrowPosition evenModule = new MockBorrowPosition(address(collateralToken), address(debtToken));
    evenModule.setTotalCollateralQuoted(100e18);
    evenModule.setTotalBorrowed(100e18);

    harness.addBorrowModule(address(noDebtModule));
    harness.addBorrowModule(address(badModule));
    harness.addBorrowModule(address(evenModule));

    // 300 + 0 + 0 = 300
    assertEq(harness.totalAssets(), 300e18);
  }

  function testFuzz_totalAssets_multiplePositions(uint128 col1, uint128 debt1, uint128 col2, uint128 debt2) public {
    MockBorrowPosition module1 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    module1.setTotalCollateralQuoted(col1);
    module1.setTotalBorrowed(debt1);

    MockBorrowPosition module2 = new MockBorrowPosition(address(collateralToken), address(debtToken));
    module2.setTotalCollateralQuoted(col2);
    module2.setTotalBorrowed(debt2);

    harness.addBorrowModule(address(module1));
    harness.addBorrowModule(address(module2));

    // Per-position floor: each position's NAV is max(collateral - debt, 0)
    uint256 nav1 = col1 > debt1 ? uint256(col1) - uint256(debt1) : 0;
    uint256 nav2 = col2 > debt2 ? uint256(col2) - uint256(debt2) : 0;
    assertEq(harness.totalAssets(), nav1 + nav2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   convertToShares TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_convertToShares_roundDown(uint96 assets, uint96 totalSupply, uint96 totalAssets) public view {
    // Using uint96 to avoid mulDiv overflow when assets * (totalSupply + VIRTUAL_SHARES) exceeds uint256
    uint256 shares = harness.convertToShares(assets, totalSupply, totalAssets, false);

    // Verify the formula: shares = assets * (totalSupply + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)
    uint256 expected =
      uint256(assets).mulDiv(uint256(totalSupply) + VIRTUAL_SHARES, uint256(totalAssets) + VIRTUAL_ASSETS);
    assertEq(shares, expected);
  }

  function testFuzz_convertToShares_roundUp(uint96 assets, uint96 totalSupply, uint96 totalAssets) public view {
    // Using uint96 to avoid mulDiv overflow when assets * (totalSupply + VIRTUAL_SHARES) exceeds uint256
    uint256 sharesUp = harness.convertToShares(assets, totalSupply, totalAssets, true);

    // Verify the formula uses mulDivUp: shares = ceil(assets * (totalSupply + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS))
    uint256 expected =
      uint256(assets).mulDivUp(uint256(totalSupply) + VIRTUAL_SHARES, uint256(totalAssets) + VIRTUAL_ASSETS);
    assertEq(sharesUp, expected);
  }

  function testFuzz_convertToShares_roundUpGteRoundDown(uint96 assets, uint96 totalSupply, uint96 totalAssets)
    public
    view
  {
    uint256 sharesDown = harness.convertToShares(assets, totalSupply, totalAssets, false);
    uint256 sharesUp = harness.convertToShares(assets, totalSupply, totalAssets, true);
    assertGe(sharesUp, sharesDown, "roundUp result must be >= roundDown result");
  }

  function test_convertToShares_roundUpDifference() public view {
    // Choose values where rounding matters: 7 * (100 + 1e6) / (3 + 1) = 7_000_700 / 4 = 1_750_175
    // 7 * 1_000_100 = 7_000_700; 7_000_700 / 4 = 1_750_175 exactly, no rounding difference
    // Use values that do not divide evenly: assets=3, totalSupply=0, totalAssets=2
    // 3 * (0 + 1e6) / (2 + 1) = 3_000_000 / 3 = 1_000_000 exactly
    // Try: assets=1, totalSupply=1, totalAssets=2 => 1 * (1 + 1e6) / (2 + 1) = 1_000_001 / 3 = 333_333 (down), 333_334 (up)
    uint256 sharesDown = harness.convertToShares(1, 1, 2, false);
    uint256 sharesUp = harness.convertToShares(1, 1, 2, true);
    assertEq(sharesDown, 333_333, "roundDown should truncate");
    assertEq(sharesUp, 333_334, "roundUp should ceil");
    assertEq(sharesUp - sharesDown, 1, "difference should be exactly 1 for non-exact division");
  }

  function test_convertToShares_preventInflationAttack() public view {
    // Test that virtual shares/assets prevent inflation attack
    // Attacker deposits 1 wei, then donates large amount

    // First deposit: 1 wei with 0 supply
    uint256 attackerShares = harness.convertToShares(1, 0, 0, false);
    // attackerShares = 1 * VIRTUAL_SHARES / VIRTUAL_ASSETS = 1

    // Attacker donates 1e18 tokens, making totalAssets = 1 + 1e18
    // Victim deposits 1e18
    uint256 victimShares = harness.convertToShares(1e18, attackerShares, 1 + 1e18, false);

    // Without virtual offset, victim would get 0 shares
    // With virtual offset, victim still gets meaningful shares
    assertGt(victimShares, 0, "Victim should get shares");
  }
}
