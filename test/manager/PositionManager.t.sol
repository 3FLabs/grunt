// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IPositionManager, SupplyQueueEntry, RebalancingData, RebalancingOperation, RebalancingOperationType} from "src/interfaces/manager/IPositionManager.sol";
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    // Create test addresses
    owner = makeAddr("owner");
    minter = makeAddr("minter");
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
      owner,
      "Position Manager Shares",
      "PMS",
      18,
      address(collateralToken),
      address(debtToken),
      POSITION_MANAGER_LLTV
    );

    // Grant minter role
    vm.prank(owner);
    positionManager.grantRoles(minter, _ROLE_MINTER);

    // Deploy MorphoBorrowPositionFactory and create positions
    borrowPositionFactory = new MorphoBorrowPositionFactory(owner, preLiquidationFactory);

    address bp1 = borrowPositionFactory.createBorrowPosition(morpho, marketId1, address(positionManager), preLiquidation1);
    borrowPosition1 = MorphoBorrowPosition(bp1);

    address bp2 = borrowPositionFactory.createBorrowPosition(morpho, marketId2, address(positionManager), preLiquidation2);
    borrowPosition2 = MorphoBorrowPosition(bp2);

    // Setup supply and withdrawal queues
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](2);
    supplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    supplyQueue[1] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});

    address[] memory withdrawalQueue = new address[](2);
    withdrawalQueue[0] = address(borrowPosition1);
    withdrawalQueue[1] = address(borrowPosition2);

    vm.startPrank(owner);
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

  function test_setSupplyQueue_onlyOwner() public {
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](1);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: 1000e18});

    vm.prank(user);
    vm.expectRevert();
    positionManager.setSupplyQueue(queue);

    vm.prank(owner);
    positionManager.setSupplyQueue(queue);

    SupplyQueueEntry[] memory newQueue = positionManager.supplyQueue();
    assertEq(newQueue.length, 1);
    assertEq(newQueue[0].maxBorrow, 1000e18);
  }

  function test_setWithdrawalQueue_onlyOwner() public {
    address[] memory queue = new address[](1);
    queue[0] = address(borrowPosition2);

    vm.prank(user);
    vm.expectRevert();
    positionManager.setWithdrawalQueue(queue);

    vm.prank(owner);
    positionManager.setWithdrawalQueue(queue);

    address[] memory newQueue = positionManager.withdrawalQueue();
    assertEq(newQueue.length, 1);
    assertEq(newQueue[0], address(borrowPosition2));
  }

  function test_setLLTV_onlyOwner() public {
    uint256 newLltv = 0.6e18;

    vm.prank(user);
    vm.expectRevert();
    positionManager.setLLTV(newLltv);

    vm.prank(owner);
    positionManager.setLLTV(newLltv);

    assertEq(positionManager.lltv(), newLltv);
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
      position: address(borrowPosition1),
      operationType: RebalancingOperationType.REPAY,
      amount: debtToMove
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1),
      operationType: RebalancingOperationType.WITHDRAW,
      amount: collateralToMove
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2),
      operationType: RebalancingOperationType.SUPPLY,
      amount: collateralToMove
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2),
      operationType: RebalancingOperationType.BORROW,
      amount: debtToMove
    });

    RebalancingData memory data = RebalancingData({
      collateral: 0,
      debt: debtToMove, // Need to provide debt for repayment
      operations: ops
    });

    // Mint debt for owner to repay
    _mintDebt(owner, debtToMove);
    vm.startPrank(owner);
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
        collateralReceived,
        collateral * burnRatio / 100,
        0.01e18,
        "Collateral received should be proportional"
      );
    }
  }
}
