// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MorphoBalancesLib} from "src/libs/borrow/MorphoBalancesLib.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";

/// @title MorphoBalancesLibTest
/// @notice Fuzz and unit tests for MorphoBalancesLib.
/// @dev Validates that the library's view-based interest computation matches Morpho's actual
///      `accrueInterest` + `market()` result for all practical inputs.
contract MorphoBalancesLibTest is Test {
  using MarketParamsLib for MarketParams;
  using MorphoBalancesLib for IMorpho;
  using SharesMathLib for uint256;

  /*:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST CONTRACTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  IMorpho public morpho;
  MockERC20 public loanToken;
  MockERC20 public collateralToken;
  OracleMock public oracle;
  IrmMock public irm;

  /*:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST PARAMETERS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MarketParams public marketParams;
  Id public marketId;

  uint256 constant DEFAULT_LLTV = 0.8e18;
  uint256 constant ORACLE_PRICE_SCALE = 1e36;
  uint256 constant DEFAULT_ORACLE_PRICE = 1e36;
  uint256 constant MAX_SUPPLY = 1e28;
  uint256 constant MAX_BORROW = 1e28;
  uint256 constant MAX_TIME_ELAPSED = 365 days;

  address public owner;
  address public supplier;
  address public borrower;

  /*:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    owner = makeAddr("owner");
    supplier = makeAddr("supplier");
    borrower = makeAddr("borrower");

    // Deploy Morpho
    morpho = IMorpho(address(new Morpho(owner)));

    // Deploy mock tokens
    loanToken = new MockERC20("Loan Token", "LOAN", 18);
    collateralToken = new MockERC20("Collateral Token", "COLL", 18);

    // Deploy oracle and IRM mocks
    oracle = new OracleMock();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    irm = new IrmMock();

    // Configure Morpho
    vm.startPrank(owner);
    morpho.enableIrm(address(irm));
    morpho.enableLltv(DEFAULT_LLTV);
    vm.stopPrank();

    // Create market
    marketParams = MarketParams({
      loanToken: address(loanToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });

    vm.prank(owner);
    morpho.createMarket(marketParams);
    marketId = marketParams.id();

    // Label contracts
    vm.label(address(morpho), "Morpho");
    vm.label(address(loanToken), "LoanToken");
    vm.label(address(collateralToken), "CollateralToken");
    vm.label(address(oracle), "Oracle");
    vm.label(address(irm), "IRM");
  }

  /*:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Supply liquidity to the Morpho market
  function _supplyLiquidity(uint256 amount) internal {
    loanToken.setBalance(supplier, amount);
    vm.startPrank(supplier);
    loanToken.approve(address(morpho), amount);
    morpho.supply(marketParams, amount, 0, supplier, "");
    vm.stopPrank();
  }

  /// @dev Supply collateral and borrow from the Morpho market
  function _setupBorrowPosition(uint256 collateralAmount, uint256 borrowAmount) internal {
    collateralToken.setBalance(borrower, collateralAmount);
    vm.startPrank(borrower);
    collateralToken.approve(address(morpho), collateralAmount);
    morpho.supplyCollateral(marketParams, collateralAmount, borrower, "");
    if (borrowAmount > 0) {
      morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);
    }
    vm.stopPrank();
  }

  /*:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       UNIT TESTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_expectedMarketBalances_NoElapsedTime() public {
    // Supply and borrow
    uint256 supplyAmount = 10_000e18;
    uint256 collateralAmount = 10_000e18;
    uint256 borrowAmount = 5_000e18;

    _supplyLiquidity(supplyAmount);
    _setupBorrowPosition(collateralAmount, borrowAmount);

    // No time elapsed - expected should match cached
    Market memory cachedMarket = morpho.market(marketId);
    (uint256 expSupplyAssets, uint256 expSupplyShares, uint256 expBorrowAssets, uint256 expBorrowShares) =
      morpho.expectedMarketBalances(marketParams, marketId);

    assertEq(expSupplyAssets, cachedMarket.totalSupplyAssets, "Supply assets should match when no time elapsed");
    assertEq(expSupplyShares, cachedMarket.totalSupplyShares, "Supply shares should match when no time elapsed");
    assertEq(expBorrowAssets, cachedMarket.totalBorrowAssets, "Borrow assets should match when no time elapsed");
    assertEq(expBorrowShares, cachedMarket.totalBorrowShares, "Borrow shares should match when no time elapsed");
  }

  function test_expectedMarketBalances_NoBorrows() public {
    // Supply only, no borrows
    uint256 supplyAmount = 10_000e18;
    _supplyLiquidity(supplyAmount);

    // Advance time
    vm.warp(block.timestamp + 30 days);

    // With no borrows, no interest should accrue
    Market memory cachedMarket = morpho.market(marketId);
    (uint256 expSupplyAssets, uint256 expSupplyShares, uint256 expBorrowAssets, uint256 expBorrowShares) =
      morpho.expectedMarketBalances(marketParams, marketId);

    assertEq(expSupplyAssets, cachedMarket.totalSupplyAssets, "Supply assets should not change without borrows");
    assertEq(expSupplyShares, cachedMarket.totalSupplyShares, "Supply shares should not change without borrows");
    assertEq(expBorrowAssets, 0, "Borrow assets should be zero");
    assertEq(expBorrowShares, 0, "Borrow shares should be zero");
  }

  function test_expectedMarketBalances_AfterTimeElapsed() public {
    uint256 supplyAmount = 10_000e18;
    uint256 collateralAmount = 10_000e18;
    uint256 borrowAmount = 5_000e18;

    _supplyLiquidity(supplyAmount);
    _setupBorrowPosition(collateralAmount, borrowAmount);

    // Advance time to accumulate interest
    vm.warp(block.timestamp + 30 days);

    // Get expected balances (view - should include pending interest)
    (uint256 expSupplyAssets,, uint256 expBorrowAssets,) = morpho.expectedMarketBalances(marketParams, marketId);

    // Cached values should be stale (lower)
    Market memory cachedMarket = morpho.market(marketId);
    assertGt(expBorrowAssets, cachedMarket.totalBorrowAssets, "Expected borrow assets should exceed cached");
    assertGt(expSupplyAssets, cachedMarket.totalSupplyAssets, "Expected supply assets should exceed cached");

    // Now actually accrue interest and compare
    morpho.accrueInterest(marketParams);
    Market memory accrued = morpho.market(marketId);

    assertEq(expBorrowAssets, accrued.totalBorrowAssets, "Expected borrow assets should match post-accrual");
    assertEq(expSupplyAssets, accrued.totalSupplyAssets, "Expected supply assets should match post-accrual");
  }

  function test_expectedMarketBalances_MatchesAccrueInterest_WithFee() public {
    // Set a fee on the market
    vm.prank(owner);
    morpho.setFee(marketParams, 0.1e18); // 10% fee

    uint256 supplyAmount = 10_000e18;
    uint256 collateralAmount = 10_000e18;
    uint256 borrowAmount = 5_000e18;

    _supplyLiquidity(supplyAmount);
    _setupBorrowPosition(collateralAmount, borrowAmount);

    // Advance time
    vm.warp(block.timestamp + 90 days);

    // Get expected balances
    (uint256 expSupplyAssets, uint256 expSupplyShares, uint256 expBorrowAssets, uint256 expBorrowShares) =
      morpho.expectedMarketBalances(marketParams, marketId);

    // Actually accrue interest
    morpho.accrueInterest(marketParams);
    Market memory accrued = morpho.market(marketId);

    assertEq(expBorrowAssets, accrued.totalBorrowAssets, "Borrow assets should match with fee");
    assertEq(expBorrowShares, accrued.totalBorrowShares, "Borrow shares should match with fee");
    assertEq(expSupplyAssets, accrued.totalSupplyAssets, "Supply assets should match with fee");
    assertEq(expSupplyShares, accrued.totalSupplyShares, "Supply shares should match with fee");
  }

  function test_expectedTotalBorrowAssets_ConvenienceFunction() public {
    uint256 supplyAmount = 10_000e18;
    uint256 collateralAmount = 10_000e18;
    uint256 borrowAmount = 5_000e18;

    _supplyLiquidity(supplyAmount);
    _setupBorrowPosition(collateralAmount, borrowAmount);

    vm.warp(block.timestamp + 30 days);

    uint256 expectedBorrow = morpho.expectedTotalBorrowAssets(marketParams, marketId);
    (,, uint256 expBorrowFromFull,) = morpho.expectedMarketBalances(marketParams, marketId);

    assertEq(expectedBorrow, expBorrowFromFull, "Convenience function should match full function");
  }

  function test_expectedTotalSupplyAssets_ConvenienceFunction() public {
    uint256 supplyAmount = 10_000e18;
    uint256 collateralAmount = 10_000e18;
    uint256 borrowAmount = 5_000e18;

    _supplyLiquidity(supplyAmount);
    _setupBorrowPosition(collateralAmount, borrowAmount);

    vm.warp(block.timestamp + 30 days);

    uint256 expectedSupply = morpho.expectedTotalSupplyAssets(marketParams, marketId);
    (uint256 expSupplyFromFull,,,) = morpho.expectedMarketBalances(marketParams, marketId);

    assertEq(expectedSupply, expSupplyFromFull, "Convenience function should match full function");
  }

  function test_expectedMarketBalances_JustAccruedMarket() public {
    uint256 supplyAmount = 10_000e18;
    uint256 collateralAmount = 10_000e18;
    uint256 borrowAmount = 5_000e18;

    _supplyLiquidity(supplyAmount);
    _setupBorrowPosition(collateralAmount, borrowAmount);

    // Advance time and accrue
    vm.warp(block.timestamp + 30 days);
    morpho.accrueInterest(marketParams);

    // Immediately after accrual, expected should match cached
    Market memory accrued = morpho.market(marketId);
    (uint256 expSupplyAssets, uint256 expSupplyShares, uint256 expBorrowAssets, uint256 expBorrowShares) =
      morpho.expectedMarketBalances(marketParams, marketId);

    assertEq(expSupplyAssets, accrued.totalSupplyAssets, "Supply assets should match just-accrued market");
    assertEq(expSupplyShares, accrued.totalSupplyShares, "Supply shares should match just-accrued market");
    assertEq(expBorrowAssets, accrued.totalBorrowAssets, "Borrow assets should match just-accrued market");
    assertEq(expBorrowShares, accrued.totalBorrowShares, "Borrow shares should match just-accrued market");
  }

  /*:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Fuzz test: expectedMarketBalances matches accrueInterest + market() for arbitrary time gaps.
  function testFuzz_expectedMarketBalances_MatchesAccrueInterest(
    uint128 supplyAmount,
    uint128 borrowRatio,
    uint64 timeElapsed
  ) public {
    supplyAmount = uint128(bound(supplyAmount, 1e6, MAX_SUPPLY));
    borrowRatio = uint128(bound(borrowRatio, 1, 70)); // 1% to 70% utilization
    timeElapsed = uint64(bound(timeElapsed, 1, MAX_TIME_ELAPSED));

    // Setup market
    _supplyLiquidity(supplyAmount);

    uint256 borrowAmount = (uint256(supplyAmount) * borrowRatio) / 100;
    if (borrowAmount == 0) borrowAmount = 1;

    // Supply sufficient collateral for the borrow
    uint256 collateralNeeded = (borrowAmount * 2e18) / DEFAULT_LLTV; // 2x safety margin
    _setupBorrowPosition(collateralNeeded, borrowAmount);

    // Advance time
    vm.warp(block.timestamp + timeElapsed);

    // Get expected balances via library
    (uint256 expSupplyAssets, uint256 expSupplyShares, uint256 expBorrowAssets, uint256 expBorrowShares) =
      morpho.expectedMarketBalances(marketParams, marketId);

    // Actually accrue interest
    morpho.accrueInterest(marketParams);
    Market memory accrued = morpho.market(marketId);

    // Validate exact match
    assertEq(expBorrowAssets, accrued.totalBorrowAssets, "Borrow assets mismatch");
    assertEq(expBorrowShares, accrued.totalBorrowShares, "Borrow shares mismatch");
    assertEq(expSupplyAssets, accrued.totalSupplyAssets, "Supply assets mismatch");
    assertEq(expSupplyShares, accrued.totalSupplyShares, "Supply shares mismatch");
  }

  /// @notice Fuzz test: expected balances match with non-zero fee.
  function testFuzz_expectedMarketBalances_WithFee(
    uint128 supplyAmount,
    uint128 borrowRatio,
    uint64 timeElapsed,
    uint64 fee
  ) public {
    supplyAmount = uint128(bound(supplyAmount, 1e6, MAX_SUPPLY));
    borrowRatio = uint128(bound(borrowRatio, 1, 70));
    timeElapsed = uint64(bound(timeElapsed, 1, MAX_TIME_ELAPSED));
    fee = uint64(bound(fee, 1, 0.25e18)); // Up to 25% fee (Morpho max)

    // Set fee
    vm.prank(owner);
    morpho.setFee(marketParams, fee);

    // Setup market
    _supplyLiquidity(supplyAmount);

    uint256 borrowAmount = (uint256(supplyAmount) * borrowRatio) / 100;
    if (borrowAmount == 0) borrowAmount = 1;

    uint256 collateralNeeded = (borrowAmount * 2e18) / DEFAULT_LLTV;
    _setupBorrowPosition(collateralNeeded, borrowAmount);

    // Advance time
    vm.warp(block.timestamp + timeElapsed);

    // Get expected balances via library
    (uint256 expSupplyAssets, uint256 expSupplyShares, uint256 expBorrowAssets, uint256 expBorrowShares) =
      morpho.expectedMarketBalances(marketParams, marketId);

    // Actually accrue interest
    morpho.accrueInterest(marketParams);
    Market memory accrued = morpho.market(marketId);

    // Validate exact match
    assertEq(expBorrowAssets, accrued.totalBorrowAssets, "Borrow assets mismatch with fee");
    assertEq(expBorrowShares, accrued.totalBorrowShares, "Borrow shares mismatch with fee");
    assertEq(expSupplyAssets, accrued.totalSupplyAssets, "Supply assets mismatch with fee");
    assertEq(expSupplyShares, accrued.totalSupplyShares, "Supply shares mismatch with fee");
  }

  /// @notice Fuzz test: zero elapsed time always returns cached values.
  function testFuzz_expectedMarketBalances_ZeroElapsed(uint128 supplyAmount, uint128 borrowRatio) public {
    supplyAmount = uint128(bound(supplyAmount, 1e6, MAX_SUPPLY));
    borrowRatio = uint128(bound(borrowRatio, 0, 70));

    _supplyLiquidity(supplyAmount);

    if (borrowRatio > 0) {
      uint256 borrowAmount = (uint256(supplyAmount) * borrowRatio) / 100;
      if (borrowAmount == 0) borrowAmount = 1;
      uint256 collateralNeeded = (borrowAmount * 2e18) / DEFAULT_LLTV;
      _setupBorrowPosition(collateralNeeded, borrowAmount);
    }

    // No time warp - elapsed is 0
    Market memory cached = morpho.market(marketId);
    (uint256 expSupplyAssets, uint256 expSupplyShares, uint256 expBorrowAssets, uint256 expBorrowShares) =
      morpho.expectedMarketBalances(marketParams, marketId);

    assertEq(expSupplyAssets, cached.totalSupplyAssets, "Supply assets should match cached at t=0");
    assertEq(expSupplyShares, cached.totalSupplyShares, "Supply shares should match cached at t=0");
    assertEq(expBorrowAssets, cached.totalBorrowAssets, "Borrow assets should match cached at t=0");
    assertEq(expBorrowShares, cached.totalBorrowShares, "Borrow shares should match cached at t=0");
  }

  /// @notice Fuzz test: interest always increases borrow and supply assets (never decreases).
  function testFuzz_expectedMarketBalances_InterestOnlyIncreases(
    uint128 supplyAmount,
    uint128 borrowRatio,
    uint64 timeElapsed
  ) public {
    supplyAmount = uint128(bound(supplyAmount, 1e6, MAX_SUPPLY));
    borrowRatio = uint128(bound(borrowRatio, 1, 70));
    timeElapsed = uint64(bound(timeElapsed, 1, MAX_TIME_ELAPSED));

    _supplyLiquidity(supplyAmount);

    uint256 borrowAmount = (uint256(supplyAmount) * borrowRatio) / 100;
    if (borrowAmount == 0) borrowAmount = 1;
    uint256 collateralNeeded = (borrowAmount * 2e18) / DEFAULT_LLTV;
    _setupBorrowPosition(collateralNeeded, borrowAmount);

    Market memory before = morpho.market(marketId);

    vm.warp(block.timestamp + timeElapsed);

    (uint256 expSupplyAssets,, uint256 expBorrowAssets,) = morpho.expectedMarketBalances(marketParams, marketId);

    assertGe(expBorrowAssets, before.totalBorrowAssets, "Borrow assets should not decrease with interest");
    assertGe(expSupplyAssets, before.totalSupplyAssets, "Supply assets should not decrease with interest");
  }

  /// @notice Fuzz test: interest on borrow and supply is the same amount.
  function testFuzz_expectedMarketBalances_InterestSymmetry(
    uint128 supplyAmount,
    uint128 borrowRatio,
    uint64 timeElapsed
  ) public {
    supplyAmount = uint128(bound(supplyAmount, 1e6, MAX_SUPPLY));
    borrowRatio = uint128(bound(borrowRatio, 1, 70));
    timeElapsed = uint64(bound(timeElapsed, 1, MAX_TIME_ELAPSED));

    _supplyLiquidity(supplyAmount);

    uint256 borrowAmount = (uint256(supplyAmount) * borrowRatio) / 100;
    if (borrowAmount == 0) borrowAmount = 1;
    uint256 collateralNeeded = (borrowAmount * 2e18) / DEFAULT_LLTV;
    _setupBorrowPosition(collateralNeeded, borrowAmount);

    Market memory before = morpho.market(marketId);

    vm.warp(block.timestamp + timeElapsed);

    (uint256 expSupplyAssets,, uint256 expBorrowAssets,) = morpho.expectedMarketBalances(marketParams, marketId);

    // Interest added to borrow should equal interest added to supply
    uint256 borrowInterest = expBorrowAssets - before.totalBorrowAssets;
    uint256 supplyInterest = expSupplyAssets - before.totalSupplyAssets;
    assertEq(borrowInterest, supplyInterest, "Interest should be symmetric between borrow and supply");
  }

  /// @notice Fuzz test: borrow shares are never modified by interest accrual.
  function testFuzz_expectedMarketBalances_BorrowSharesUnchanged(
    uint128 supplyAmount,
    uint128 borrowRatio,
    uint64 timeElapsed
  ) public {
    supplyAmount = uint128(bound(supplyAmount, 1e6, MAX_SUPPLY));
    borrowRatio = uint128(bound(borrowRatio, 1, 70));
    timeElapsed = uint64(bound(timeElapsed, 0, MAX_TIME_ELAPSED));

    _supplyLiquidity(supplyAmount);

    uint256 borrowAmount = (uint256(supplyAmount) * borrowRatio) / 100;
    if (borrowAmount == 0) borrowAmount = 1;
    uint256 collateralNeeded = (borrowAmount * 2e18) / DEFAULT_LLTV;
    _setupBorrowPosition(collateralNeeded, borrowAmount);

    Market memory before = morpho.market(marketId);

    vm.warp(block.timestamp + timeElapsed);

    (,,, uint256 expBorrowShares) = morpho.expectedMarketBalances(marketParams, marketId);

    assertEq(expBorrowShares, before.totalBorrowShares, "Borrow shares should never change from interest");
  }

  /// @notice Fuzz test: multiple sequential time advances all produce matching results.
  function testFuzz_expectedMarketBalances_MultipleAdvances(
    uint128 supplyAmount,
    uint128 borrowRatio,
    uint32 time1,
    uint32 time2,
    uint32 time3
  ) public {
    supplyAmount = uint128(bound(supplyAmount, 1e6, MAX_SUPPLY));
    borrowRatio = uint128(bound(borrowRatio, 1, 70));
    time1 = uint32(bound(time1, 1, 30 days));
    time2 = uint32(bound(time2, 1, 30 days));
    time3 = uint32(bound(time3, 1, 30 days));

    _supplyLiquidity(supplyAmount);

    uint256 borrowAmount = (uint256(supplyAmount) * borrowRatio) / 100;
    if (borrowAmount == 0) borrowAmount = 1;
    uint256 collateralNeeded = (borrowAmount * 2e18) / DEFAULT_LLTV;
    _setupBorrowPosition(collateralNeeded, borrowAmount);

    // First advance
    vm.warp(block.timestamp + time1);
    (uint256 exp1Supply,, uint256 exp1Borrow,) = morpho.expectedMarketBalances(marketParams, marketId);
    morpho.accrueInterest(marketParams);
    Market memory accrued1 = morpho.market(marketId);
    assertEq(exp1Borrow, accrued1.totalBorrowAssets, "Mismatch after advance 1");
    assertEq(exp1Supply, accrued1.totalSupplyAssets, "Mismatch after advance 1 (supply)");

    // Second advance
    vm.warp(block.timestamp + time2);
    (uint256 exp2Supply,, uint256 exp2Borrow,) = morpho.expectedMarketBalances(marketParams, marketId);
    morpho.accrueInterest(marketParams);
    Market memory accrued2 = morpho.market(marketId);
    assertEq(exp2Borrow, accrued2.totalBorrowAssets, "Mismatch after advance 2");
    assertEq(exp2Supply, accrued2.totalSupplyAssets, "Mismatch after advance 2 (supply)");

    // Third advance
    vm.warp(block.timestamp + time3);
    (uint256 exp3Supply,, uint256 exp3Borrow,) = morpho.expectedMarketBalances(marketParams, marketId);
    morpho.accrueInterest(marketParams);
    Market memory accrued3 = morpho.market(marketId);
    assertEq(exp3Borrow, accrued3.totalBorrowAssets, "Mismatch after advance 3");
    assertEq(exp3Supply, accrued3.totalSupplyAssets, "Mismatch after advance 3 (supply)");
  }
}
