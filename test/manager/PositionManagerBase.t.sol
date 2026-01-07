// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {
  IPositionManager,
  SupplyQueueEntry,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/IPositionManager.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {ERC20Mock} from "lib/morpho-blue/src/mocks/ERC20Mock.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MathLib} from "lib/morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {IPreLiquidation, PreLiquidationParams} from "lib/pre-liquidation/src/interfaces/IPreLiquidation.sol";
import {IPreLiquidationFactory} from "lib/pre-liquidation/src/interfaces/IPreLiquidationFactory.sol";
import {Id as PreLiquidationId} from "lib/pre-liquidation/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {PreLiquidationBytecode} from "../borrow/PreLiquidationBytecode.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";

/// @title PositionManagerBaseTest
/// @notice Base test contract with setup and helpers for PositionManager tests
abstract contract PositionManagerBaseTest is Test {
  using MarketParamsLib for MarketParams;
  using MathLib for uint256;
  using SharesMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManager public positionManager;
  MorphoBorrowPositionFactory public borrowPositionFactory;
  MorphoBorrowPosition public borrowPosition1;
  MorphoBorrowPosition public borrowPosition2;
  IMorpho public morpho;
  ERC20Mock public debtToken;
  ERC20Mock public collateralToken;
  OracleMock public oracle;
  IrmMock public irm;
  IPreLiquidationFactory public preLiquidationFactory;
  IPreLiquidation public preLiquidation1;
  IPreLiquidation public preLiquidation2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST PARAMETERS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MarketParams public marketParams1;
  MarketParams public marketParams2;
  Id public marketId1;
  Id public marketId2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public minter;
  address public curator;
  address public rebalancer;
  address public feeRecipient;
  address public user;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant DEFAULT_LLTV = 0.8e18; // 80% LLTV
  uint256 constant POSITION_MANAGER_LLTV = 0.7e18; // 70% LLTV for available collateral
  uint256 constant ORACLE_PRICE_SCALE = 1e36;
  uint256 constant DEFAULT_ORACLE_PRICE = 1e36; // 1:1 price
  uint256 constant COLLATERAL_AMOUNT = 10_000e18;
  uint256 constant DEBT_AMOUNT = 5_000e18;
  uint256 constant WAD = 1e18;
  uint256 constant _ROLE_MINTER = 1 << 0;
  uint256 constant _ROLE_CURATOR = 1 << 1;
  uint256 constant _ROLE_REBALANCER = 1 << 2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public virtual {
    // Create test addresses
    owner = makeAddr("owner");
    minter = makeAddr("minter");
    curator = makeAddr("curator");
    rebalancer = makeAddr("rebalancer");
    feeRecipient = makeAddr("feeRecipient");
    user = makeAddr("user");

    // Deploy Morpho
    morpho = IMorpho(address(new Morpho(owner)));

    // Deploy mock tokens
    debtToken = new ERC20Mock();
    vm.label(address(debtToken), "DebtToken");

    collateralToken = new ERC20Mock();
    vm.label(address(collateralToken), "CollateralToken");

    // Deploy oracle and IRM mocks
    oracle = new OracleMock();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    irm = new IrmMock();

    // Configure Morpho
    vm.startPrank(owner);
    morpho.enableIrm(address(irm));
    morpho.enableIrm(address(0));
    morpho.enableLltv(DEFAULT_LLTV);
    vm.stopPrank();

    // Create market 1
    marketParams1 = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });

    vm.prank(owner);
    morpho.createMarket(marketParams1);
    marketId1 = marketParams1.id();

    // Create market 2 (same tokens, different IRM for testing multiple positions)
    marketParams2 = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(0), // No interest for simplicity
      lltv: DEFAULT_LLTV
    });

    vm.prank(owner);
    morpho.createMarket(marketParams2);
    marketId2 = marketParams2.id();

    // Deploy PreLiquidationFactory
    preLiquidationFactory = PreLiquidationBytecode.deployFactory(address(morpho));

    // Create PreLiquidation contracts
    PreLiquidationParams memory preLiquidationParams = PreLiquidationParams({
      preLltv: (DEFAULT_LLTV * 90) / 100,
      preLCF1: 0.5e18,
      preLCF2: 1.0e18,
      preLIF1: 1.03e18,
      preLIF2: 1.1e18,
      preLiquidationOracle: address(oracle)
    });

    preLiquidation1 =
      preLiquidationFactory.createPreLiquidation(PreLiquidationId.wrap(Id.unwrap(marketId1)), preLiquidationParams);
    preLiquidation2 =
      preLiquidationFactory.createPreLiquidation(PreLiquidationId.wrap(Id.unwrap(marketId2)), preLiquidationParams);

    // Deploy PositionManager
    positionManager = new PositionManager();
    positionManager.initialize(
      owner, "Position Manager Shares", "PMS", 18, address(collateralToken), address(debtToken), POSITION_MANAGER_LLTV
    );

    // Grant minter role
    vm.prank(owner);
    positionManager.grantRoles(minter, _ROLE_MINTER);

    // Deploy MorphoBorrowPositionFactory and create positions
    borrowPositionFactory = new MorphoBorrowPositionFactory(owner, preLiquidationFactory);

    address bp1 =
      borrowPositionFactory.createBorrowPosition(morpho, marketId1, address(positionManager), preLiquidation1);
    borrowPosition1 = MorphoBorrowPosition(bp1);

    address bp2 =
      borrowPositionFactory.createBorrowPosition(morpho, marketId2, address(positionManager), preLiquidation2);
    borrowPosition2 = MorphoBorrowPosition(bp2);

    // Setup borrow modules whitelist and grant curator/rebalancer roles
    vm.startPrank(owner);
    positionManager.addBorrowModule(address(borrowPosition1));
    positionManager.addBorrowModule(address(borrowPosition2));
    positionManager.grantRoles(curator, _ROLE_CURATOR);
    positionManager.grantRoles(rebalancer, _ROLE_REBALANCER);
    vm.stopPrank();

    // Setup supply and withdrawal queues
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](2);
    supplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    supplyQueue[1] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});

    address[] memory withdrawalQueue = new address[](2);
    withdrawalQueue[0] = address(borrowPosition1);
    withdrawalQueue[1] = address(borrowPosition2);

    vm.startPrank(curator);
    positionManager.setSupplyQueue(supplyQueue);
    positionManager.setWithdrawalQueue(withdrawalQueue);
    vm.stopPrank();

    // Supply liquidity to Morpho markets
    _supplyLiquidity(marketParams1, 100_000e18);
    _supplyLiquidity(marketParams2, 100_000e18);

    // Setup approvals for minter
    vm.startPrank(minter);
    debtToken.approve(address(positionManager), type(uint256).max);
    collateralToken.approve(address(positionManager), type(uint256).max);
    vm.stopPrank();

    // Label contracts
    vm.label(address(positionManager), "PositionManager");
    vm.label(address(borrowPosition1), "BorrowPosition1");
    vm.label(address(borrowPosition2), "BorrowPosition2");
    vm.label(address(morpho), "Morpho");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _supplyLiquidity(MarketParams memory params, uint256 amount) internal {
    debtToken.setBalance(address(this), amount);
    debtToken.approve(address(morpho), amount);
    morpho.supply(params, amount, 0, address(this), "");
  }

  function _mintCollateral(address to, uint256 amount) internal {
    collateralToken.setBalance(to, amount);
  }

  function _mintDebt(address to, uint256 amount) internal {
    debtToken.setBalance(to, amount);
  }
}
