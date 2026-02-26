// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IPositionManager, SupplyQueueEntry, WithdrawalStrategy} from "src/interfaces/manager/IPositionManager.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MathLib} from "lib/morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title PositionManagerBaseTest
/// @notice Base test contract with setup and helpers for PositionManager tests
contract PositionManagerBaseTest is Test {
  using MarketParamsLib for MarketParams;
  using MathLib for uint256;
  using SharesMathLib for uint256;
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManager public positionManager;
  MorphoBorrowPositionFactory public borrowPositionFactory;
  MorphoBorrowPosition public borrowPosition1;
  MorphoBorrowPosition public borrowPosition2;
  IMorpho public morpho;
  MockERC20 public debtToken;
  MockERC20 public collateralToken;
  OracleMock public oracle;
  IrmMock public irm;

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

  uint256 constant DEFAULT_LLTV = 0.8e18; // 80% LLTV (Morpho market)
  uint128 constant BP_SAFE_LTV = 0.72e18; // 72% safe LTV for borrow positions (must be >= PM LTV)
  uint128 constant BP_LIQUIDATION_LTV = 0.78e18; // 78% liquidation LTV for borrow positions
  uint256 constant POSITION_MANAGER_LTV = 0.7e18; // 70% LTV for available collateral
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
    debtToken = new MockERC20("Debt Token", "DEBT", 18);
    vm.label(address(debtToken), "DebtToken");

    collateralToken = new MockERC20("Collateral Token", "COLL", 18);
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

    // Deploy PositionManager
    positionManager = PositionManager(address(new PositionManager()).clone());
    positionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "Position Manager Shares",
        symbol: "PMS",
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );

    // Grant minter role
    vm.prank(owner);
    positionManager.grantRoles(minter, _ROLE_MINTER);

    // Deploy MorphoBorrowPositionFactory and create positions
    borrowPositionFactory = new MorphoBorrowPositionFactory(owner);

    address bp1 = borrowPositionFactory.createBorrowPosition(
      morpho, marketId1, address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
    borrowPosition1 = MorphoBorrowPosition(bp1);

    address bp2 = borrowPositionFactory.createBorrowPosition(
      morpho, marketId2, address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 CONSOLIDATED VIEW HELPERS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _ltv() internal view returns (uint256) {
    (uint256 ltv_,) = positionManager.config();
    return ltv_;
  }

  function _maxRebalanceLoss() internal view returns (uint16) {
    (uint16 maxRebalanceLoss_,,) = positionManager.rebalanceConfig();
    return maxRebalanceLoss_;
  }

  function _rebalanceCooldown() internal view returns (uint40) {
    (, uint40 rebalanceCooldown_,) = positionManager.rebalanceConfig();
    return rebalanceCooldown_;
  }

  function _lastRebalanceTimestamp() internal view returns (uint40) {
    (,, uint40 lastRebalanceTimestamp_) = positionManager.rebalanceConfig();
    return lastRebalanceTimestamp_;
  }

  function _lastTotalAssets() internal view returns (uint256) {
    (,,, uint256 lastTotalAssets_,) = positionManager.feeData();
    return lastTotalAssets_;
  }

  function _lastFeeAccrualTimestamp() internal view returns (uint256) {
    (,,,, uint256 lastFeeAccrualTimestamp_) = positionManager.feeData();
    return lastFeeAccrualTimestamp_;
  }

  function _collateralAsset() internal view returns (address) {
    (address collateralAsset_,) = positionManager.assets();
    return collateralAsset_;
  }

  function _debtAsset() internal view returns (address) {
    (, address debtAsset_) = positionManager.assets();
    return debtAsset_;
  }

  function test_empty() public pure {}
}
