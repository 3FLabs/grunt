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

/// @title PositionManagerTest
/// @notice Test suite for PositionManager contract with MorphoBorrowPosition
contract PositionManagerTest is Test {
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
  uint256 constant POSITION_MANAGER_LLTV = 0.7e18; // 70% LLTV for free collateral
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

  function setUp() public {
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INITIALIZATION TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialization() public view {
    assertEq(positionManager.name(), "Position Manager Shares");
    assertEq(positionManager.symbol(), "PMS");
    assertEq(positionManager.decimals(), 18);
    assertEq(positionManager.lltv(), POSITION_MANAGER_LLTV);
  }

  function test_supplyQueue() public view {
    SupplyQueueEntry[] memory queue = positionManager.supplyQueue();
    assertEq(queue.length, 2);
    assertEq(queue[0].position, address(borrowPosition1));
    assertEq(queue[1].position, address(borrowPosition2));
  }

  function test_withdrawalQueue() public view {
    address[] memory queue = positionManager.withdrawalQueue();
    assertEq(queue.length, 2);
    assertEq(queue[0], address(borrowPosition1));
    assertEq(queue[1], address(borrowPosition2));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       DEPOSIT TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_collateralOnly() public {
    _mintCollateral(minter, COLLATERAL_AMOUNT);

    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, 0);

    assertGt(shares, 0, "Should mint shares");
    assertEq(positionManager.balanceOf(minter), uint256(shares), "Minter should have shares");
    assertEq(positionManager.collateralAmount(), COLLATERAL_AMOUNT, "Collateral should be deposited");
    assertEq(positionManager.debtAmount(), 0, "No debt should be borrowed");
  }

  function test_deposit_collateralAndDebt() public {
    _mintCollateral(minter, COLLATERAL_AMOUNT);

    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    assertGt(shares, 0, "Should mint shares");
    assertEq(positionManager.collateralAmount(), COLLATERAL_AMOUNT, "Collateral should be deposited");
    assertEq(positionManager.debtAmount(), DEBT_AMOUNT, "Debt should be borrowed");
    assertEq(debtToken.balanceOf(minter), DEBT_AMOUNT, "Minter should receive borrowed debt");
  }

  function test_deposit_debtOnly() public {
    // First deposit some collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 sharesBefore = positionManager.balanceOf(minter);
    uint256 additionalDebt = 1000e18;

    // Now deposit with only debt (borrow more)
    vm.prank(minter);
    int256 sharesDelta = positionManager.deposit(0, additionalDebt);

    // Assets decreased (borrowed more), so shares should be burned
    assertLt(sharesDelta, 0, "Should burn shares when only borrowing");
    assertLt(positionManager.balanceOf(minter), sharesBefore, "Minter should have fewer shares");
    assertEq(positionManager.debtAmount(), additionalDebt, "Debt should increase");
  }

  function test_deposit_revertOnZeroAmount() public {
    vm.prank(minter);
    vm.expectRevert(IPositionManager.ZeroAmount.selector);
    positionManager.deposit(0, 0);
  }

  function test_deposit_revertOnUnauthorized() public {
    _mintCollateral(user, COLLATERAL_AMOUNT);

    vm.prank(user);
    collateralToken.approve(address(positionManager), COLLATERAL_AMOUNT);

    vm.prank(user);
    vm.expectRevert();
    positionManager.deposit(COLLATERAL_AMOUNT, 0);
  }

  function test_deposit_multipleDeposits() public {
    // First deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares1 = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Second deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares2 = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    assertGt(shares1, 0);
    assertGt(shares2, 0);
    assertEq(positionManager.collateralAmount(), COLLATERAL_AMOUNT * 2);
    assertEq(positionManager.debtAmount(), DEBT_AMOUNT * 2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WITHDRAW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdraw_repayDebtOnly() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 sharesBefore = positionManager.balanceOf(minter);
    uint256 repayAmount = 1000e18;
    _mintDebt(minter, repayAmount);

    vm.prank(minter);
    int256 sharesDelta = positionManager.withdraw(0, repayAmount);

    // Assets increased (debt repaid), so shares should be minted
    assertGt(sharesDelta, 0, "Should mint shares when repaying debt");
    assertGt(positionManager.balanceOf(minter), sharesBefore, "Minter should have more shares");
    assertEq(positionManager.debtAmount(), DEBT_AMOUNT - repayAmount, "Debt should decrease");
  }

  function test_withdraw_collateralOnly() public {
    // Setup: deposit collateral only (no debt)
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 sharesBefore = positionManager.balanceOf(minter);
    uint256 withdrawAmount = 1000e18;

    vm.prank(minter);
    int256 sharesDelta = positionManager.withdraw(withdrawAmount, 0);

    // Assets decreased (collateral withdrawn), so shares should be burned
    assertLt(sharesDelta, 0, "Should burn shares when withdrawing collateral");
    assertLt(positionManager.balanceOf(minter), sharesBefore, "Minter should have fewer shares");
    assertEq(collateralToken.balanceOf(minter), withdrawAmount, "Minter should receive collateral");
  }

  function test_withdraw_collateralAndRepay() public {
    // Setup: deposit and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 repayAmount = DEBT_AMOUNT; // Repay all debt
    uint256 withdrawAmount = 2000e18;
    _mintDebt(minter, repayAmount);

    vm.prank(minter);
    int256 sharesDelta = positionManager.withdraw(withdrawAmount, repayAmount);

    assertEq(positionManager.debtAmount(), 0, "All debt should be repaid");
    assertEq(collateralToken.balanceOf(minter), withdrawAmount, "Should receive collateral");
  }

  function test_withdraw_revertOnInsufficientFreeCollateral() public {
    // Setup: deposit and borrow at high LTV
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 6000e18); // 60% LTV

    // Try to withdraw collateral without repaying (would exceed LLTV)
    vm.prank(minter);
    vm.expectRevert(IPositionManager.InsufficientFreeCollateral.selector);
    positionManager.withdraw(5000e18, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        BURN TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_burn_proportional() public {
    // Setup: deposit and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 totalShares = positionManager.balanceOf(minter);
    uint256 sharesToBurn = totalShares / 2;

    // Mint debt to repay
    _mintDebt(minter, DEBT_AMOUNT);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Should receive approximately half
    assertApproxEqRel(collateralReceived, COLLATERAL_AMOUNT / 2, 0.01e18, "Should receive ~50% collateral");
    assertApproxEqRel(debtRepaid, DEBT_AMOUNT / 2, 0.01e18, "Should repay ~50% debt");
    assertEq(positionManager.balanceOf(minter), totalShares - sharesToBurn, "Shares should be burned");
  }

  function test_burn_all() public {
    // Setup: deposit and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 totalShares = positionManager.balanceOf(minter);

    // Mint debt to repay all
    _mintDebt(minter, DEBT_AMOUNT);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(totalShares);

    assertEq(collateralReceived, COLLATERAL_AMOUNT, "Should receive all collateral");
    assertEq(debtRepaid, DEBT_AMOUNT, "Should repay all debt");
    assertEq(positionManager.balanceOf(minter), 0, "All shares should be burned");
    assertEq(positionManager.totalSupply(), 0, "Total supply should be 0");
  }

  function test_burn_noDebt() public {
    // Setup: deposit collateral only
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 totalShares = positionManager.balanceOf(minter);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(totalShares);

    assertEq(collateralReceived, COLLATERAL_AMOUNT, "Should receive all collateral");
    assertEq(debtRepaid, 0, "No debt to repay");
  }

  function test_burn_revertOnZeroShares() public {
    vm.prank(minter);
    vm.expectRevert(IPositionManager.ZeroAmount.selector);
    positionManager.burn(0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     FEE ACCRUAL TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setFeeData() public {
    uint24 managementFee = 200; // 2% per year
    uint24 performanceFee = 2000; // 20%

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);

    (address recipient, uint24 mgmtFee, uint24 perfFee) = positionManager.feeData();
    assertEq(recipient, feeRecipient);
    assertEq(mgmtFee, managementFee);
    assertEq(perfFee, performanceFee);
  }

  function test_managementFeeAccrual() public {
    // Setup fees
    uint24 managementFee = 200; // 2% per year
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, 0);

    // Deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 totalSupplyBefore = positionManager.totalSupply();

    // Advance time by 1 year
    vm.warp(block.timestamp + 365 days);

    // Trigger fee accrual with another deposit
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 feeRecipientShares = positionManager.balanceOf(feeRecipient);
    assertGt(feeRecipientShares, 0, "Fee recipient should have shares");

    // Fee should be approximately 2% of total supply
    uint256 expectedFeeShares = totalSupplyBefore * 200 / 10000;
    assertApproxEqRel(feeRecipientShares, expectedFeeShares, 0.1e18, "Fee should be ~2%");
  }

  function test_performanceFeeAccrual() public {
    // Setup fees
    uint24 performanceFee = 2000; // 20%
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 0, performanceFee);

    // Deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 totalAssetsBefore = positionManager.totalAssets();

    // Simulate gains by increasing oracle price (collateral worth more)
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 120 / 100); // 20% price increase

    uint256 totalAssetsAfter = positionManager.totalAssets();
    uint256 gains = totalAssetsAfter - totalAssetsBefore;

    // Trigger fee accrual
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    uint256 feeRecipientShares = positionManager.balanceOf(feeRecipient);
    assertGt(feeRecipientShares, 0, "Fee recipient should have shares from performance fee");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     ADMIN FUNCTION TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setSupplyQueue_onlyCurator() public {
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: 1000e18});

    vm.prank(user);
    vm.expectRevert();
    positionManager.setSupplyQueue(queue);

    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    SupplyQueueEntry[] memory newQueue = positionManager.supplyQueue();
    assertEq(newQueue.length, 1);
    assertEq(newQueue[0].maxBorrow, 1000e18);
  }

  function test_setWithdrawalQueue_onlyCurator() public {
    address[] memory queue = new address[](1);
    queue[0] = address(borrowPosition2);

    vm.prank(user);
    vm.expectRevert();
    positionManager.setWithdrawalQueue(queue);

    vm.prank(curator);
    positionManager.setWithdrawalQueue(queue);

    address[] memory newQueue = positionManager.withdrawalQueue();
    assertEq(newQueue.length, 1);
    assertEq(newQueue[0], address(borrowPosition2));
  }

  function test_setLltv_onlyOwner() public {
    uint256 newLltv = 0.6e18;

    vm.prank(user);
    vm.expectRevert();
    positionManager.setLltv(newLltv);

    vm.prank(owner);
    positionManager.setLltv(newLltv);

    assertEq(positionManager.lltv(), newLltv);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  BORROW MODULE WHITELIST TESTS             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_addBorrowModule_onlyOwner() public {
    address newModule = makeAddr("newModule");

    vm.prank(user);
    vm.expectRevert();
    positionManager.addBorrowModule(newModule);

    vm.prank(owner);
    positionManager.addBorrowModule(newModule);

    assertTrue(positionManager.isBorrowModule(newModule));
  }

  function test_removeBorrowModule_onlyOwner() public {
    // borrowPosition1 is already whitelisted
    assertTrue(positionManager.isBorrowModule(address(borrowPosition1)));

    vm.prank(user);
    vm.expectRevert();
    positionManager.removeBorrowModule(address(borrowPosition1));

    vm.prank(owner);
    positionManager.removeBorrowModule(address(borrowPosition1));

    assertFalse(positionManager.isBorrowModule(address(borrowPosition1)));
  }

  function test_borrowModules_returnsWhitelistedModules() public view {
    address[] memory modules = positionManager.borrowModules();
    assertEq(modules.length, 2);
    // Note: Order may vary based on EnumerableSet implementation
    assertTrue(
      (modules[0] == address(borrowPosition1) && modules[1] == address(borrowPosition2))
        || (modules[0] == address(borrowPosition2) && modules[1] == address(borrowPosition1))
    );
  }

  function test_isBorrowModule_correctlyReports() public view {
    assertTrue(positionManager.isBorrowModule(address(borrowPosition1)));
    assertTrue(positionManager.isBorrowModule(address(borrowPosition2)));
    assertFalse(positionManager.isBorrowModule(address(0)));
    assertFalse(positionManager.isBorrowModule(user));
  }

  function test_setSupplyQueue_revertOnUnauthorizedPosition() public {
    address unauthorizedPosition = makeAddr("unauthorized");

    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: unauthorizedPosition, maxBorrow: uint96(type(uint96).max)});

    vm.prank(curator);
    vm.expectRevert(IPositionManager.UnauthorizedPosition.selector);
    positionManager.setSupplyQueue(queue);
  }

  function test_setWithdrawalQueue_revertOnUnauthorizedPosition() public {
    address unauthorizedPosition = makeAddr("unauthorized");

    address[] memory queue = new address[](1);
    queue[0] = unauthorizedPosition;

    vm.prank(curator);
    vm.expectRevert(IPositionManager.UnauthorizedPosition.selector);
    positionManager.setWithdrawalQueue(queue);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CURATOR ROLE TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setSupplyQueue_revertIfNotCurator() public {
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: 1000e18});

    // Owner cannot set supply queue (only curator)
    vm.prank(owner);
    vm.expectRevert();
    positionManager.setSupplyQueue(queue);

    // Rebalancer cannot set supply queue
    vm.prank(rebalancer);
    vm.expectRevert();
    positionManager.setSupplyQueue(queue);

    // Random user cannot set supply queue
    vm.prank(user);
    vm.expectRevert();
    positionManager.setSupplyQueue(queue);
  }

  function test_setWithdrawalQueue_revertIfNotCurator() public {
    address[] memory queue = new address[](1);
    queue[0] = address(borrowPosition1);

    // Owner cannot set withdrawal queue (only curator)
    vm.prank(owner);
    vm.expectRevert();
    positionManager.setWithdrawalQueue(queue);

    // Rebalancer cannot set withdrawal queue
    vm.prank(rebalancer);
    vm.expectRevert();
    positionManager.setWithdrawalQueue(queue);

    // Random user cannot set withdrawal queue
    vm.prank(user);
    vm.expectRevert();
    positionManager.setWithdrawalQueue(queue);
  }

  function test_curator_canBeGrantedToMultipleAddresses() public {
    address newCurator = makeAddr("newCurator");

    vm.prank(owner);
    positionManager.grantRoles(newCurator, _ROLE_CURATOR);

    // Both original curator and new curator can set queues
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: 1000e18});

    vm.prank(curator);
    positionManager.setSupplyQueue(queue);

    vm.prank(newCurator);
    positionManager.setSupplyQueue(queue);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   REBALANCER ROLE TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_revertIfNotRebalancer() public {
    RebalancingOperation[] memory ops = new RebalancingOperation[](0);
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // Owner cannot rebalance (only rebalancer)
    vm.prank(owner);
    vm.expectRevert();
    positionManager.rebalance(data);

    // Curator cannot rebalance
    vm.prank(curator);
    vm.expectRevert();
    positionManager.rebalance(data);

    // Random user cannot rebalance
    vm.prank(user);
    vm.expectRevert();
    positionManager.rebalance(data);
  }

  function test_rebalancer_canBeGrantedToMultipleAddresses() public {
    // Setup: deposit collateral first
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    address newRebalancer = makeAddr("newRebalancer");

    vm.prank(owner);
    positionManager.grantRoles(newRebalancer, _ROLE_REBALANCER);

    RebalancingOperation[] memory ops = new RebalancingOperation[](0);
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // Both original rebalancer and new rebalancer can rebalance
    vm.prank(rebalancer);
    positionManager.rebalance(data);

    vm.prank(newRebalancer);
    positionManager.rebalance(data);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REBALANCE TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_moveLiquidity() public {
    // Setup: deposit collateral and borrow in position 1
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Check initial state
    assertEq(borrowPosition1.totalCollateral(), COLLATERAL_AMOUNT);
    assertEq(borrowPosition1.totalBorrowed(), DEBT_AMOUNT);
    assertEq(borrowPosition2.totalCollateral(), 0);
    assertEq(borrowPosition2.totalBorrowed(), 0);

    // Rebalance: move half to position 2
    uint256 collateralToMove = COLLATERAL_AMOUNT / 2;
    uint256 debtToMove = DEBT_AMOUNT / 2;

    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: debtToMove
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToMove
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: collateralToMove
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: debtToMove
    });

    RebalancingData memory data = RebalancingData({
      collateral: 0,
      debt: debtToMove, // Need to provide debt for repayment
      operations: ops
    });

    // Mint debt for rebalancer to repay
    _mintDebt(rebalancer, debtToMove);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), debtToMove);
    (uint256 collateralExcess, uint256 debtExcess) = positionManager.rebalance(data);
    vm.stopPrank();

    // Check balances moved
    assertApproxEqRel(borrowPosition1.totalCollateral(), collateralToMove, 0.01e18);
    assertApproxEqRel(borrowPosition2.totalCollateral(), collateralToMove, 0.01e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        VIEW TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_totalAssets() public {
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 totalAssets = positionManager.totalAssets();
    // totalAssets = collateralQuoted - debt
    // With 1:1 price: 10000 - 5000 = 5000
    assertEq(totalAssets, COLLATERAL_AMOUNT - DEBT_AMOUNT);
  }

  function test_collateralAmount() public {
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    assertEq(positionManager.collateralAmount(), COLLATERAL_AMOUNT);
  }

  function test_debtAmount() public {
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    assertEq(positionManager.debtAmount(), DEBT_AMOUNT);
  }

  function test_collateralAmountQuoted() public {
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // With 1:1 price, quoted should equal raw
    assertEq(positionManager.collateralAmountQuoted(), COLLATERAL_AMOUNT);

    // Change price to 2:1
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);
    assertEq(positionManager.collateralAmountQuoted(), COLLATERAL_AMOUNT * 2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_deposit(uint256 collateral, uint256 debt) public {
    // Bound collateral to reasonable range
    collateral = bound(collateral, 1e18, 50_000e18);
    // Debt must be less than 70% of collateral to pass preLLTV checks (72%) with margin
    // Also cap at available liquidity
    uint256 maxDebt = (collateral * 70) / 100;
    if (maxDebt > 100_000e18) maxDebt = 100_000e18; // First pool has 100k liquidity
    debt = bound(debt, 0, maxDebt);

    _mintCollateral(minter, collateral);

    vm.prank(minter);
    int256 shares = positionManager.deposit(collateral, debt);

    assertGt(shares, 0, "Should mint positive shares");
    assertEq(positionManager.collateralAmount(), collateral);
    assertEq(positionManager.debtAmount(), debt);
  }

  function testFuzz_depositAndBurn(uint256 collateral, uint256 burnRatio) public {
    collateral = bound(collateral, 1e18, 1_000_000e18);
    burnRatio = bound(burnRatio, 1, 100); // 1-100%

    _mintCollateral(minter, collateral);
    vm.prank(minter);
    positionManager.deposit(collateral, 0);

    uint256 totalShares = positionManager.balanceOf(minter);
    uint256 sharesToBurn = totalShares * burnRatio / 100;

    if (sharesToBurn > 0) {
      vm.prank(minter);
      (uint256 collateralReceived,) = positionManager.burn(sharesToBurn);

      assertApproxEqRel(
        collateralReceived, collateral * burnRatio / 100, 0.01e18, "Collateral received should be proportional"
      );
    }
  }

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
  /*                    FEE VALIDATION TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setFeeData_revertOnExcessiveManagementFee() public {
    uint24 excessiveManagementFee = 5001; // > 50%
    uint24 validPerformanceFee = 2000;

    vm.prank(owner);
    vm.expectRevert(IPositionManager.FeeExceedsMax.selector);
    positionManager.setFeeData(feeRecipient, excessiveManagementFee, validPerformanceFee);
  }

  function test_setFeeData_revertOnExcessivePerformanceFee() public {
    uint24 validManagementFee = 200;
    uint24 excessivePerformanceFee = 5001; // > 50%

    vm.prank(owner);
    vm.expectRevert(IPositionManager.FeeExceedsMax.selector);
    positionManager.setFeeData(feeRecipient, validManagementFee, excessivePerformanceFee);
  }

  function test_setFeeData_maxFeesAllowed() public {
    uint24 maxManagementFee = 5000; // Exactly 50%
    uint24 maxPerformanceFee = 5000; // Exactly 50%

    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, maxManagementFee, maxPerformanceFee);

    (address recipient, uint24 mgmtFee, uint24 perfFee) = positionManager.feeData();
    assertEq(recipient, feeRecipient);
    assertEq(mgmtFee, maxManagementFee);
    assertEq(perfFee, maxPerformanceFee);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 ZERO SUPPLY FEE ACCRUAL TESTS               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_feeAccrual_zeroSupply() public {
    // Setup fees before any deposits
    uint24 managementFee = 200; // 2% per year
    uint24 performanceFee = 2000; // 20%
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, performanceFee);

    // Advance time
    vm.warp(block.timestamp + 365 days);

    // First deposit should not cause issues with fee calculation
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, 0);

    assertGt(shares, 0, "Should mint shares on first deposit");
    // Fee recipient should have 0 shares since there was no supply before
    assertEq(positionManager.balanceOf(feeRecipient), 0, "No fees should accrue with zero supply");
  }

  function test_feeAccrual_zeroTotalAssets() public {
    // This edge case shouldn't happen in practice but test the behavior
    // Setup fees
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, 200, 2000);

    // Deposit and borrow to create position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Advance time
    vm.warp(block.timestamp + 365 days);

    // Crash price to make totalAssets = 0 (underwater)
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 10 / 100); // 10% of original

    // Deposit should still work
    _mintCollateral(minter, 1e18);
    vm.prank(minter);
    positionManager.deposit(1e18, 0);

    // Should not revert, fees should be 0 since totalAssets is 0
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               MULTI-POSITION BURN ACCURACY TESTS            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_burn_multiPosition_proportional() public {
    // First deposit goes to position1
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Move half to position2 using rebalance
    uint256 collateralToMove = COLLATERAL_AMOUNT / 2;
    uint256 debtToMove = DEBT_AMOUNT / 2;

    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: debtToMove
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToMove
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: collateralToMove
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: debtToMove
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: debtToMove, operations: ops});

    _mintDebt(rebalancer, debtToMove);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), debtToMove);
    positionManager.rebalance(data);
    vm.stopPrank();

    // Verify both positions have collateral and debt
    assertApproxEqRel(borrowPosition1.totalCollateral(), collateralToMove, 0.01e18);
    assertApproxEqRel(borrowPosition2.totalCollateral(), collateralToMove, 0.01e18);

    // Now burn 50% of shares
    uint256 totalShares = positionManager.balanceOf(minter);
    uint256 sharesToBurn = totalShares / 2;

    _mintDebt(minter, DEBT_AMOUNT); // Provide debt for repayment
    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Should receive proportional amounts from both positions
    assertApproxEqRel(collateralReceived, COLLATERAL_AMOUNT / 2, 0.01e18, "Should receive ~50% of total collateral");
    assertApproxEqRel(debtRepaid, DEBT_AMOUNT / 2, 0.01e18, "Should repay ~50% of total debt");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  REBALANCE EXCESS TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_accruesFeesAndUpdatesSnapshot() public {
    // Setup fees
    uint24 managementFee = 200; // 2% per year
    vm.prank(owner);
    positionManager.setFeeData(feeRecipient, managementFee, 0);

    // Deposit to create position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    uint256 initialSnapshot = positionManager.lastTotalAssets();
    uint256 initialTimestamp = positionManager.lastFeeAccrualTimestamp();

    // Advance time
    vm.warp(block.timestamp + 365 days);

    // Rebalance (just supply more collateral)
    uint256 additionalCollateral = 1000e18;
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.SUPPLY, amount: additionalCollateral
    });

    RebalancingData memory data = RebalancingData({collateral: additionalCollateral, debt: 0, operations: ops});

    _mintCollateral(rebalancer, additionalCollateral);
    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), additionalCollateral);
    positionManager.rebalance(data);
    vm.stopPrank();

    // Verify fee recipient received management fees (accrued before rebalance)
    assertGt(positionManager.balanceOf(feeRecipient), 0, "Fee recipient should have received fees");

    // Verify timestamp was updated
    assertGt(positionManager.lastFeeAccrualTimestamp(), initialTimestamp, "Timestamp should be updated");

    // Verify snapshot was updated to post-rebalance value
    assertGt(positionManager.lastTotalAssets(), initialSnapshot, "Snapshot should reflect post-rebalance state");
    assertEq(
      positionManager.lastTotalAssets(),
      COLLATERAL_AMOUNT + additionalCollateral,
      "Snapshot should equal new total assets"
    );
  }

  function test_rebalance_returnsExcessCorrectly() public {
    // Setup: deposit collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Rebalance with more collateral than needed
    uint256 excessCollateral = 1000e18;
    uint256 excessDebt = 500e18;

    // Only supply half of what we provide
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.SUPPLY, amount: excessCollateral / 2
    });

    RebalancingData memory data = RebalancingData({collateral: excessCollateral, debt: excessDebt, operations: ops});

    _mintCollateral(rebalancer, excessCollateral);
    _mintDebt(rebalancer, excessDebt);

    uint256 rebalancerCollateralBefore = collateralToken.balanceOf(rebalancer);
    uint256 rebalancerDebtBefore = debtToken.balanceOf(rebalancer);

    vm.startPrank(rebalancer);
    collateralToken.approve(address(positionManager), excessCollateral);
    debtToken.approve(address(positionManager), excessDebt);
    (uint256 collateralExcess, uint256 debtExcess) = positionManager.rebalance(data);
    vm.stopPrank();

    // Should return the unused amounts
    assertEq(collateralExcess, excessCollateral / 2, "Should return unused collateral");
    assertEq(debtExcess, excessDebt, "Should return all unused debt");

    // Verify rebalancer received the excess back
    assertEq(
      collateralToken.balanceOf(rebalancer),
      rebalancerCollateralBefore - excessCollateral + collateralExcess,
      "Rebalancer should receive collateral excess"
    );
    assertEq(
      debtToken.balanceOf(rebalancer),
      rebalancerDebtBefore - excessDebt + debtExcess,
      "Rebalancer should receive debt excess"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   NEW VIEW FUNCTION TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_collateralAsset() public view {
    assertEq(positionManager.collateralAsset(), address(collateralToken));
  }

  function test_debtAsset() public view {
    assertEq(positionManager.debtAsset(), address(debtToken));
  }

  function test_lastTotalAssets() public {
    // Initially should be 0
    assertEq(positionManager.lastTotalAssets(), 0);

    // Deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // After deposit, lastTotalAssets should be updated
    assertEq(positionManager.lastTotalAssets(), COLLATERAL_AMOUNT);
  }

  function test_lastFeeAccrualTimestamp() public {
    uint256 initialTimestamp = positionManager.lastFeeAccrualTimestamp();
    assertEq(initialTimestamp, block.timestamp);

    // Advance time
    vm.warp(block.timestamp + 100);

    // Deposit triggers fee accrual
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    assertEq(positionManager.lastFeeAccrualTimestamp(), block.timestamp);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   EMPTY QUEUE BEHAVIOR TESTS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_deposit_emptySupplyQueue() public {
    // Clear supply queue
    SupplyQueueEntry[] memory emptyQueue = new SupplyQueueEntry[](0);
    vm.prank(curator);
    positionManager.setSupplyQueue(emptyQueue);

    _mintCollateral(minter, COLLATERAL_AMOUNT);

    // Deposit with no debt should still work (no positions to deposit to though)
    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Shares should be 0 since no collateral was actually deposited anywhere
    // Actually, looking at the code, if queue is empty and debt is 0, nothing happens
    // The collateral is pulled but not deposited, this might be a bug worth noting
    assertEq(shares, 0, "No shares minted with empty queue and no debt");
  }

  function test_deposit_emptySupplyQueue_withDebt_reverts() public {
    // Clear supply queue
    SupplyQueueEntry[] memory emptyQueue = new SupplyQueueEntry[](0);
    vm.prank(curator);
    positionManager.setSupplyQueue(emptyQueue);

    _mintCollateral(minter, COLLATERAL_AMOUNT);

    // Deposit with debt should revert due to insufficient borrow capacity
    vm.prank(minter);
    vm.expectRevert(IPositionManager.InsufficientBorrowCapacity.selector);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);
  }

  function test_withdraw_emptyWithdrawalQueue() public {
    // First deposit normally
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Clear withdrawal queue
    address[] memory emptyQueue = new address[](0);
    vm.prank(curator);
    positionManager.setWithdrawalQueue(emptyQueue);

    // Try to withdraw collateral - should revert
    vm.prank(minter);
    vm.expectRevert(IPositionManager.InsufficientFreeCollateral.selector);
    positionManager.withdraw(1000e18, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    LIQUIDATION TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_liquidation_singlePosition_partialLiquidation() public {
    // Setup: deposit collateral and borrow at high utilization
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 debtBefore = positionManager.debtAmount();
    uint256 totalAssetsBefore = positionManager.totalAssets();
    uint256 sharesBefore = positionManager.balanceOf(minter);

    // Crash oracle price to make position liquidatable
    // LLTV is 80%, so at 60% of original price, the position becomes liquidatable
    // debt = 5000, collateral = 10000 * 0.6 = 6000 quoted
    // maxBorrow = 6000 * 0.8 = 4800 < 5000 debt -> liquidatable
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    // Setup liquidator
    address liquidator = makeAddr("liquidator");
    uint256 seizedCollateral = 1000e18; // Seize 1000 collateral tokens

    // Give liquidator debt tokens to repay
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    // Execute liquidation on Morpho
    vm.prank(liquidator);
    (uint256 seizedAssets, uint256 repaidAssets) =
      morpho.liquidate(marketParams1, address(borrowPosition1), seizedCollateral, 0, "");

    // Verify position state after liquidation
    uint256 collateralAfter = positionManager.collateralAmount();
    uint256 debtAfter = positionManager.debtAmount();
    uint256 totalAssetsAfter = positionManager.totalAssets();

    // Collateral should have decreased by seized amount
    assertEq(collateralAfter, collateralBefore - seizedAssets, "Collateral should decrease by seized amount");

    // Debt should have decreased by repaid amount
    assertEq(debtAfter, debtBefore - repaidAssets, "Debt should decrease by repaid amount");

    // Total assets should have decreased (liquidation has a cost due to incentive)
    assertLt(totalAssetsAfter, totalAssetsBefore, "Total assets should decrease after liquidation");

    // Shares should remain the same (no burning occurred)
    assertEq(positionManager.balanceOf(minter), sharesBefore, "Shares should not change from liquidation");

    // Share value should have decreased
    uint256 shareValueBefore = totalAssetsBefore * WAD / sharesBefore;
    uint256 shareValueAfter = totalAssetsAfter * WAD / sharesBefore;
    assertLt(shareValueAfter, shareValueBefore, "Share value should decrease after liquidation");
  }

  function test_liquidation_singlePosition_fullLiquidation() public {
    // Setup: deposit collateral and borrow at high utilization (close to LLTV)
    uint256 highDebt = (COLLATERAL_AMOUNT * 70) / 100; // 70% LTV
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, highDebt);

    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 debtBefore = positionManager.debtAmount();

    // Crash oracle price significantly to allow full liquidation
    // At 50% price: collateral = 5000 quoted, maxBorrow = 4000, debt = 7000 -> very underwater
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 50 / 100);

    // Setup liquidator
    address liquidator = makeAddr("liquidator");

    // Give liquidator enough debt tokens
    debtToken.setBalance(liquidator, debtBefore * 2);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), debtBefore * 2);

    // Execute full liquidation - seize all collateral
    vm.prank(liquidator);
    (uint256 seizedAssets, uint256 repaidAssets) =
      morpho.liquidate(marketParams1, address(borrowPosition1), collateralBefore, 0, "");

    // Verify position state after full liquidation
    uint256 collateralAfter = positionManager.collateralAmount();
    uint256 debtAfter = positionManager.debtAmount();

    // All collateral should be seized
    assertEq(collateralAfter, 0, "All collateral should be seized");

    // Some debt may remain if collateral wasn't enough to cover all debt + incentive
    // This is a bad debt scenario
    if (debtAfter > 0) {
      // Position is now underwater with no collateral - this is bad debt
      assertEq(positionManager.totalAssets(), 0, "Total assets should be 0 when underwater");
    }

    // Shares still exist but are now worthless or near-worthless
    assertGt(positionManager.balanceOf(minter), 0, "Shares still exist");
  }

  function test_liquidation_multiPosition_oneLiquidated() public {
    // Setup: deposit to first position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Move half to second position via rebalance
    uint256 collateralToMove = COLLATERAL_AMOUNT / 2;
    uint256 debtToMove = DEBT_AMOUNT / 2;

    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: debtToMove
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: collateralToMove
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: collateralToMove
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: debtToMove
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: debtToMove, operations: ops});

    _mintDebt(rebalancer, debtToMove);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), debtToMove);
    positionManager.rebalance(data);
    vm.stopPrank();

    // Verify both positions have roughly equal amounts
    uint256 pos1Collateral = borrowPosition1.totalCollateral();
    uint256 pos2Collateral = borrowPosition2.totalCollateral();
    uint256 totalCollateralBefore = positionManager.collateralAmount();
    uint256 totalAssetsBefore = positionManager.totalAssets();

    // Crash oracle to make positions liquidatable
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    // Liquidate only position 1
    address liquidator = makeAddr("liquidator");
    uint256 seizeAmount = pos1Collateral / 2; // Partial liquidation of position 1

    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    vm.prank(liquidator);
    (uint256 seizedAssets,) = morpho.liquidate(marketParams1, address(borrowPosition1), seizeAmount, 0, "");

    // Position 2 should be unaffected
    assertEq(borrowPosition2.totalCollateral(), pos2Collateral, "Position 2 collateral unchanged");

    // Total collateral should decrease by seized amount
    assertEq(
      positionManager.collateralAmount(),
      totalCollateralBefore - seizedAssets,
      "Total collateral decreased by seized amount"
    );

    // Total assets should have decreased
    assertLt(positionManager.totalAssets(), totalAssetsBefore, "Total assets decreased");
  }

  function test_liquidation_burnAfterPartialLiquidation() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 sharesBefore = positionManager.balanceOf(minter);

    // Crash oracle and execute partial liquidation
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    address liquidator = makeAddr("liquidator");
    uint256 seizeAmount = 2000e18;

    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    vm.prank(liquidator);
    morpho.liquidate(marketParams1, address(borrowPosition1), seizeAmount, 0, "");

    // Reset oracle price for burn operation
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    // Now try to burn shares - should still work but with reduced value
    uint256 sharesToBurn = sharesBefore / 2;

    // Need to provide debt tokens for repayment during burn
    _mintDebt(minter, DEBT_AMOUNT);

    uint256 collateralBefore = positionManager.collateralAmount();
    uint256 debtBefore = positionManager.debtAmount();

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Should receive proportional amounts (but less than original due to liquidation loss)
    assertGt(collateralReceived, 0, "Should receive some collateral");
    assertGt(debtRepaid, 0, "Should repay some debt");

    // Proportions should be maintained
    assertApproxEqRel(
      collateralReceived, collateralBefore * sharesToBurn / sharesBefore, 0.01e18, "Collateral proportional to shares"
    );
  }

  function test_liquidation_depositAfterLiquidation() public {
    // Setup initial position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 sharesBefore = positionManager.balanceOf(minter);

    // Crash and liquidate
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 60 / 100);

    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, DEBT_AMOUNT);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), DEBT_AMOUNT);

    vm.prank(liquidator);
    morpho.liquidate(marketParams1, address(borrowPosition1), 2000e18, 0, "");

    // Reset oracle
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    // New user deposits after liquidation
    address newUser = makeAddr("newUser");
    vm.prank(owner);
    positionManager.grantRoles(newUser, _ROLE_MINTER);

    uint256 newDeposit = 5000e18;
    collateralToken.setBalance(newUser, newDeposit);
    vm.startPrank(newUser);
    collateralToken.approve(address(positionManager), newDeposit);
    int256 newShares = positionManager.deposit(newDeposit, 0);
    vm.stopPrank();

    // New user should receive shares at the current (diluted) price
    assertGt(newShares, 0, "New user should receive shares");

    // The share price should reflect the post-liquidation state
    // New user should get more shares per collateral than original user would have
    // because share value decreased
    uint256 totalSupply = positionManager.totalSupply();
    uint256 totalAssets = positionManager.totalAssets();

    // Verify the new shares are correctly valued
    assertEq(totalSupply, uint256(int256(sharesBefore) + newShares), "Total supply correct");
  }

  function test_liquidation_withdrawAfterFullLiquidation() public {
    // Setup: deposit at high LTV
    uint256 highDebt = (COLLATERAL_AMOUNT * 70) / 100;
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, highDebt);

    // Crash hard and fully liquidate
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 40 / 100);

    address liquidator = makeAddr("liquidator");
    debtToken.setBalance(liquidator, highDebt * 2);
    vm.prank(liquidator);
    debtToken.approve(address(morpho), highDebt * 2);

    // Seize all collateral
    vm.prank(liquidator);
    morpho.liquidate(marketParams1, address(borrowPosition1), COLLATERAL_AMOUNT, 0, "");

    // Position should now have 0 collateral
    assertEq(positionManager.collateralAmount(), 0, "No collateral left");

    // totalAssets should be 0 (underwater)
    assertEq(positionManager.totalAssets(), 0, "No assets left");

    // Trying to withdraw should fail (no free collateral)
    vm.prank(minter);
    vm.expectRevert(IPositionManager.InsufficientFreeCollateral.selector);
    positionManager.withdraw(1, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  COVERAGE GAP TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Test deposit skips positions with no available liquidity (toBorrow == 0 branch)
  function test_deposit_skipsPositionWithNoLiquidity() public {
    // Drain all liquidity from market1 by borrowing elsewhere
    // First create another borrow position that will borrow all liquidity
    address drainer = makeAddr("drainer");
    collateralToken.setBalance(drainer, 200_000e18);

    vm.prank(drainer);
    collateralToken.approve(address(morpho), 200_000e18);

    // Supply collateral and borrow all liquidity from market1
    vm.startPrank(drainer);
    morpho.supplyCollateral(marketParams1, 200_000e18, drainer, "");
    morpho.borrow(marketParams1, 100_000e18, 0, drainer, drainer); // Borrow all liquidity
    vm.stopPrank();

    // Now market1 has no liquidity, but market2 still has liquidity
    assertEq(morpho.market(marketId1).totalSupplyAssets - morpho.market(marketId1).totalBorrowAssets, 0);

    // Minter deposits - should skip position1 (no liquidity) and use position2
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Should succeed using position2
    assertGt(shares, 0, "Should mint shares");

    // All debt should be from position2 since position1 had no liquidity
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should have no debt");
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT, "Position2 should have all debt");
  }

  /// @notice Test deposit with maxBorrow == 0 skips position
  function test_deposit_skipsPositionWithZeroMaxBorrow() public {
    // Set position1's maxBorrow to 0
    SupplyQueueEntry[] memory newQueue = new SupplyQueueEntry[](2);
    newQueue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: 0});
    newQueue[1] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});

    vm.prank(curator);
    positionManager.setSupplyQueue(newQueue);

    // Deposit should skip position1 (maxBorrow == 0) and use position2
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    int256 shares = positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    assertGt(shares, 0, "Should mint shares");
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should have no debt");
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT, "Position2 should have all debt");
  }

  /// @notice Test withdrawal repay pass skips positions with no debt (positionDebt == 0 branch)
  function test_withdraw_skipsPositionWithNoDebt() public {
    // Setup: position1 has collateral only (no debt), position2 has debt
    // To achieve this, we need to modify the supply queue so debt goes only to position2

    // First deposit collateral only to position1 (via default supply queue)
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Verify position1 has collateral but no debt
    assertGt(borrowPosition1.totalCollateral(), 0, "Position1 should have collateral");
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should have no debt");

    // Now change supply queue to only have position2
    SupplyQueueEntry[] memory newSupplyQueue = new SupplyQueueEntry[](1);
    newSupplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(newSupplyQueue);

    // Deposit with debt - all debt goes to position2
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Verify setup: position1 has no debt, position2 has debt
    assertEq(borrowPosition1.totalBorrowed(), 0, "Position1 should still have no debt");
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT, "Position2 should have all debt");

    // Withdrawal queue is: [position1, position2]
    // When repaying debt, it should:
    // - Check position1, find positionDebt == 0, skip (hitting our target branch!)
    // - Check position2, find debt, repay there
    _mintDebt(minter, DEBT_AMOUNT / 2);

    vm.prank(minter);
    positionManager.withdraw(0, DEBT_AMOUNT / 2);

    // Debt should be repaid from position2
    assertEq(borrowPosition2.totalBorrowed(), DEBT_AMOUNT / 2, "Position2 should have half debt repaid");
  }

  /// @notice Test withdrawal where collateral pass skips positions with no free collateral
  function test_withdraw_skipsPositionWithNoFreeCollateral() public {
    // Setup: deposit to position1 at max LTV (no free collateral)
    // Position1: high LTV, no free collateral
    // Position2: lower LTV, has free collateral
    _mintCollateral(minter, COLLATERAL_AMOUNT * 2);

    // First supply queue entry - borrow at near max on position1
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, (COLLATERAL_AMOUNT * 69) / 100); // 69% LTV, very close to LLTV of 70%

    // Second deposit to position2 with lower LTV
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, COLLATERAL_AMOUNT / 2); // 50% LTV

    // Try to withdraw collateral - should skip position1 (no free collateral at 70% LLTV)
    // and withdraw from position2
    vm.prank(minter);
    positionManager.withdraw(1000e18, 0);

    // Should succeed by withdrawing from position2
    assertTrue(positionManager.collateralAmount() < COLLATERAL_AMOUNT * 2, "Some collateral should be withdrawn");
  }

  /// @notice Test burn with rounding that causes capping of toRepay
  function test_burn_capsRepayAmount() public {
    // Setup: create an imbalanced scenario where proportional calculation overshoots
    // We need: debtToRepay.mulDiv(positionDebt, _totalDebt) > remainingDebt

    // This can happen with rounding when burning shares from multiple positions
    // Setup two positions with different debt ratios
    _mintCollateral(minter, COLLATERAL_AMOUNT * 2);

    // Deposit to position1
    vm.prank(minter);
    int256 shares1 = positionManager.deposit(COLLATERAL_AMOUNT, 3000e18);

    // Deposit to position2
    vm.prank(minter);
    int256 shares2 = positionManager.deposit(COLLATERAL_AMOUNT, 2000e18);

    uint256 totalShares = uint256(shares1) + uint256(shares2);
    uint256 totalDebt = positionManager.debtAmount();

    // Burn most shares - the rounding in proportional calculations should trigger capping
    uint256 sharesToBurn = totalShares * 99 / 100;
    _mintDebt(minter, totalDebt); // Enough to repay

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    // Verify burn succeeded
    assertGt(collateralReceived, 0, "Should receive collateral");
    assertGt(debtRepaid, 0, "Should repay debt");
  }

  /// @notice Test burn with rounding that causes capping of toWithdraw
  function test_burn_capsWithdrawAmount() public {
    // Similar to above but for collateral capping
    _mintCollateral(minter, COLLATERAL_AMOUNT * 2);

    // Deposit different collateral amounts to each position
    vm.prank(minter);
    int256 shares1 = positionManager.deposit(COLLATERAL_AMOUNT * 6 / 10, 2000e18);

    vm.prank(minter);
    int256 shares2 = positionManager.deposit(COLLATERAL_AMOUNT * 14 / 10, 3000e18);

    uint256 totalShares = uint256(shares1) + uint256(shares2);
    uint256 totalDebt = positionManager.debtAmount();

    // Burn almost all shares
    uint256 sharesToBurn = totalShares * 99 / 100;
    _mintDebt(minter, totalDebt);

    vm.prank(minter);
    (uint256 collateralReceived, uint256 debtRepaid) = positionManager.burn(sharesToBurn);

    assertGt(collateralReceived, 0, "Should receive collateral");
    assertGt(debtRepaid, 0, "Should repay debt");
  }

  /// @notice Test that ZeroAmount is reverted for withdraw with both zero
  function test_withdraw_revertOnZeroAmount() public {
    vm.prank(minter);
    vm.expectRevert(IPositionManager.ZeroAmount.selector);
    positionManager.withdraw(0, 0);
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

    // Record state
    uint256 collateralBefore = collateralToken.balanceOf(minter);

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
  /*               COVERAGE GAP EDGE CASE TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Test burn proportional capping when toRepay exceeds remainingDebt
  /// @dev Covers line 583: if (toRepay > remainingDebt) toRepay = remainingDebt
  function test_burn_capsRepayProportionalExcess() public {
    // Create uneven debt distribution: position1 has almost all debt, position2 has minimal
    // This can cause proportional calculation for position1 to exceed remainingDebt

    // First deposit to position1 only (default queue starts with position1)
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Now rebalance to move a tiny bit of collateral and debt to position2
    // This creates uneven distribution
    uint256 tinyDebt = DEBT_AMOUNT / 1000; // 0.1%
    uint256 tinyCollateral = COLLATERAL_AMOUNT / 1000;

    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: tinyDebt
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: tinyCollateral
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: tinyCollateral
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: tinyDebt
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: tinyDebt, operations: ops});

    _mintDebt(rebalancer, tinyDebt);
    vm.startPrank(rebalancer);
    debtToken.approve(address(positionManager), tinyDebt);
    positionManager.rebalance(data);
    vm.stopPrank();

    // Verify uneven distribution
    uint256 pos1Debt = borrowPosition1.totalBorrowed();
    uint256 pos2Debt = borrowPosition2.totalBorrowed();
    assertGt(pos1Debt, pos2Debt * 100, "Position1 should have much more debt");

    // Now burn a portion that when calculated proportionally for position1
    // would exceed the actual debt we want to repay
    // Burn small shares which corresponds to small debt repayment
    uint256 sharesToBurn = positionManager.balanceOf(minter) / 100; // 1%

    _mintDebt(minter, DEBT_AMOUNT);
    vm.prank(minter);
    positionManager.burn(sharesToBurn);

    // Test passes if no revert - the capping logic handled the excess
  }

  /// @notice Test burn proportional capping when toWithdraw exceeds remainingCollateral
  /// @dev Covers line 593: if (toWithdraw > remainingCollateral) toWithdraw = remainingCollateral
  function test_burn_capsWithdrawProportionalExcess() public {
    // Create uneven collateral distribution similar to debt test
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Move tiny amount of collateral to position2
    uint256 tinyCollateral = COLLATERAL_AMOUNT / 1000;

    RebalancingOperation[] memory ops = new RebalancingOperation[](2);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: tinyCollateral
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: tinyCollateral
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    vm.prank(rebalancer);
    positionManager.rebalance(data);

    // Verify uneven distribution
    uint256 pos1Collateral = borrowPosition1.totalCollateral();
    uint256 pos2Collateral = borrowPosition2.totalCollateral();
    assertGt(pos1Collateral, pos2Collateral * 100, "Position1 should have much more collateral");

    // Burn small shares to trigger proportional capping
    uint256 sharesToBurn = positionManager.balanceOf(minter) / 100;

    vm.prank(minter);
    positionManager.burn(sharesToBurn);

    // Test passes if no revert - the capping logic handled the excess
  }

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
