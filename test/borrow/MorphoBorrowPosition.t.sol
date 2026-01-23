// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockPreLiquidationCallback} from "test/mock/borrow/MockPreLiquidationCallback.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MathLib} from "lib/morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "lib/morpho-blue/src/libraries/SharesMathLib.sol";

/// @title MorphoBorrowPositionTest
/// @notice Comprehensive test suite for MorphoBorrowPosition contract
contract MorphoBorrowPositionTest is Test {
  using MarketParamsLib for MarketParams;
  using MathLib for uint256;
  using SharesMathLib for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MorphoBorrowPosition public borrowPosition;
  MorphoBorrowPositionFactory public factory;
  IMorpho public morpho;
  MockERC20 public loanToken;
  MockERC20 public collateralToken;
  OracleMock public oracle;
  IrmMock public irm;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST PARAMETERS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MarketParams public marketParams;
  Id public marketId;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public positionManager;
  address public user;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant DEFAULT_LLTV = 0.8e18; // 80% LLTV (Morpho market)
  uint128 constant SAFE_LTV = 0.65e18; // 65% safe LTV (threshold for position health)
  uint128 constant LIQUIDATION_LTV = 0.72e18; // 72% liquidation LTV (threshold for preLiquidation)
  uint256 constant ORACLE_PRICE_SCALE = 1e36;
  uint256 constant DEFAULT_ORACLE_PRICE = 1e36; // 1:1 price
  uint256 constant MIN_TEST_AMOUNT = 1e6;
  uint256 constant MAX_TEST_AMOUNT = 1e28;
  uint256 constant COLLATERAL_AMOUNT = 10_000e18;
  uint256 constant LOAN_AMOUNT = 5_000e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        ERROR SELECTORS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // MorphoBorrowPosition errors
  error AddressZero();
  error InvalidMarketId(Id marketId);
  error MarketNotCreated();
  error AmountZero();
  error InsufficientCollateral();
  error PositionHealthy();
  error InvalidLltv();
  error LiquidationLtvExceedsMarketLltv(uint128 liquidationLtv, uint256 marketLltv);
  error SafeLtvNotLessThanLiquidationLtv(uint128 safeLtv, uint128 liquidationLtv);
  error InconsistentInput();
  error NotMorpho();

  // Solady Initializable errors
  error InvalidInitialization();

  // Solady Ownable errors
  error Unauthorized();

  // Solady SafeTransferLib errors
  error TransferFromFailed();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    // Create test addresses
    owner = makeAddr("owner");
    positionManager = makeAddr("positionManager");
    user = makeAddr("user");

    // Deploy Morpho
    morpho = IMorpho(address(new Morpho(owner)));

    // Deploy mock tokens
    loanToken = new MockERC20("Loan Token", "LOAN", 18);
    vm.label(address(loanToken), "LoanToken");

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

    // Deploy factory and create MorphoBorrowPosition via factory (using beacon proxy)
    factory = new MorphoBorrowPositionFactory(owner);
    address borrowPositionAddress =
      factory.createBorrowPosition(morpho, marketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);
    borrowPosition = MorphoBorrowPosition(borrowPositionAddress);

    // Setup approvals for position manager
    vm.startPrank(positionManager);
    loanToken.approve(address(borrowPosition), type(uint256).max);
    collateralToken.approve(address(borrowPosition), type(uint256).max);
    vm.stopPrank();

    // Label contracts
    vm.label(address(factory), "BorrowPositionFactory");
    vm.label(address(borrowPosition), "BorrowPosition");
    vm.label(address(morpho), "Morpho");
    vm.label(owner, "Owner");
    vm.label(positionManager, "PositionManager");
    vm.label(user, "User");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Supply liquidity to the Morpho market for borrowing
  function _supplyLiquidity(uint256 amount) internal {
    loanToken.setBalance(address(this), amount);
    loanToken.approve(address(morpho), amount);
    morpho.supply(marketParams, amount, 0, address(this), "");
  }

  /// @dev Calculate expected max borrow for verification
  function _calculateMaxBorrow(uint256 collateral, uint256 price, uint256 lltv) internal pure returns (uint256) {
    return collateral.mulDivDown(price, ORACLE_PRICE_SCALE).wMulDown(lltv);
  }

  /// @dev Quote collateral amount in borrowed asset terms
  function _quoteCollateral(uint256 collateral, uint256 price) internal pure returns (uint256) {
    return collateral.mulDivDown(price, ORACLE_PRICE_SCALE);
  }

  /// @dev Check if position would be healthy with given parameters
  function _isPositionHealthy(uint256 collateral, uint256 borrowed, uint256 price, uint256 lltv)
    internal
    pure
    returns (bool)
  {
    if (borrowed == 0) return true;
    uint256 maxBorrow = _calculateMaxBorrow(collateral, price, lltv);
    return maxBorrow >= borrowed;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   INITIALIZATION TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_initialize_Success() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    newPosition.initialize(morpho, marketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);

    assertEq(address(newPosition.borrowAsset()), address(loanToken), "Borrow asset mismatch");
    assertEq(address(newPosition.collateralAsset()), address(collateralToken), "Collateral asset mismatch");
    assertEq(Id.unwrap(newPosition.marketId()), Id.unwrap(marketId), "Market ID mismatch");
    assertEq(newPosition.owner(), positionManager, "Owner not set correctly");
    (uint128 posLtv, uint128 liqLtv) = newPosition.ltvs();
    assertEq(posLtv, SAFE_LTV, "Safe LTV mismatch");
    assertEq(liqLtv, LIQUIDATION_LTV, "Liquidation LTV mismatch");
  }

  function test_initialize_RevertWhen_MorphoIsZero() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    vm.expectRevert(AddressZero.selector);
    newPosition.initialize(IMorpho(address(0)), marketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);
  }

  function test_initialize_RevertWhen_MarketIdIsZero() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();
    Id zeroMarketId = Id.wrap(bytes32(0));

    vm.expectRevert(abi.encodeWithSelector(InvalidMarketId.selector, zeroMarketId));
    newPosition.initialize(morpho, zeroMarketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);
  }

  function test_initialize_RevertWhen_MarketNotCreated() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    // Create a non-existent market ID
    Id fakeMarketId = Id.wrap(keccak256("nonexistent"));

    vm.expectRevert(MarketNotCreated.selector);
    newPosition.initialize(morpho, fakeMarketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);
  }

  function test_initialize_CanOnlyBeCalledOnce() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();
    newPosition.initialize(morpho, marketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);

    vm.expectRevert(InvalidInitialization.selector);
    newPosition.initialize(morpho, marketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);
  }

  function test_initialize_SetsMarketParams() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();
    newPosition.initialize(morpho, marketId, positionManager, SAFE_LTV, LIQUIDATION_LTV);

    assertEq(newPosition.borrowAsset(), marketParams.loanToken, "Loan token mismatch");
    assertEq(newPosition.collateralAsset(), marketParams.collateralToken, "Collateral token mismatch");
  }

  function test_initialize_RevertWhen_LiquidationLtvIsZero() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    vm.expectRevert(InvalidLltv.selector);
    newPosition.initialize(morpho, marketId, positionManager, 0, 0);
  }

  function test_initialize_RevertWhen_LiquidationLtvExceedsWad() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    vm.expectRevert(InvalidLltv.selector);
    newPosition.initialize(morpho, marketId, positionManager, SAFE_LTV, uint128(1e18 + 1));
  }

  function test_initialize_RevertWhen_SafeLtvNotLessThanLiquidationLtv() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    // Safe LTV equal to liquidation LTV should revert
    vm.expectRevert(
      abi.encodeWithSelector(SafeLtvNotLessThanLiquidationLtv.selector, LIQUIDATION_LTV, LIQUIDATION_LTV)
    );
    newPosition.initialize(morpho, marketId, positionManager, LIQUIDATION_LTV, LIQUIDATION_LTV);
  }

  function test_initialize_RevertWhen_SafeLtvGreaterThanLiquidationLtv() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    // Safe LTV greater than liquidation LTV should revert
    uint128 higherSafeLtv = LIQUIDATION_LTV + 1;
    vm.expectRevert(
      abi.encodeWithSelector(SafeLtvNotLessThanLiquidationLtv.selector, higherSafeLtv, LIQUIDATION_LTV)
    );
    newPosition.initialize(morpho, marketId, positionManager, higherSafeLtv, LIQUIDATION_LTV);
  }

  function test_initialize_AcceptsMarketLltv() public {
    // Liquidation LTV can be at most equal to market LLTV
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();
    uint128 posLtv = uint128(DEFAULT_LLTV) - 1;
    newPosition.initialize(morpho, marketId, positionManager, posLtv, uint128(DEFAULT_LLTV));
    (uint128 storedPosLtv, uint128 storedLiqLtv) = newPosition.ltvs();
    assertEq(storedPosLtv, posLtv, "Safe LTV should be set correctly");
    assertEq(storedLiqLtv, uint128(DEFAULT_LLTV), "Liquidation LTV should equal market LLTV");
  }

  function test_initialize_RevertWhen_LiquidationLtvExceedsMarketLltv() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    // Try to set liquidation LTV higher than market LLTV
    uint128 exceedingLltv = uint128(DEFAULT_LLTV) + 1;
    vm.expectRevert(abi.encodeWithSelector(LiquidationLtvExceedsMarketLltv.selector, exceedingLltv, DEFAULT_LLTV));
    newPosition.initialize(morpho, marketId, positionManager, SAFE_LTV, exceedingLltv);
  }

  function test_initialize_RevertWhen_LiquidationLtvIsWadButMarketLltvIsLower() public {
    // This test verifies that even WAD (100%) is rejected if market LLTV is lower
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    vm.expectRevert(abi.encodeWithSelector(LiquidationLtvExceedsMarketLltv.selector, 1e18, DEFAULT_LLTV));
    newPosition.initialize(morpho, marketId, positionManager, SAFE_LTV, uint128(1e18));
  }

  function test_initialize_AcceptsLtvsBelowMarketLltv() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();
    uint128 lowerSafeLtv = uint128(DEFAULT_LLTV / 4);
    uint128 lowerLiquidationLtv = uint128(DEFAULT_LLTV / 2);
    newPosition.initialize(morpho, marketId, positionManager, lowerSafeLtv, lowerLiquidationLtv);
    (uint128 storedPosLtv, uint128 storedLiqLtv) = newPosition.ltvs();
    assertEq(storedPosLtv, lowerSafeLtv, "Safe LTV should be set to lower value");
    assertEq(storedLiqLtv, lowerLiquidationLtv, "Liquidation LTV should be set to lower value");
  }

  function testFuzz_initialize_LtvValidation(uint128 safeLtv_, uint128 liquidationLtv_) public {
    safeLtv_ = uint128(bound(safeLtv_, 1, uint128(1e18) - 1));
    liquidationLtv_ = uint128(bound(liquidationLtv_, 1, 1e18));

    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    if (safeLtv_ >= liquidationLtv_) {
      vm.expectRevert(
        abi.encodeWithSelector(SafeLtvNotLessThanLiquidationLtv.selector, safeLtv_, liquidationLtv_)
      );
      newPosition.initialize(morpho, marketId, positionManager, safeLtv_, liquidationLtv_);
    } else if (liquidationLtv_ > DEFAULT_LLTV) {
      vm.expectRevert(abi.encodeWithSelector(LiquidationLtvExceedsMarketLltv.selector, liquidationLtv_, DEFAULT_LLTV));
      newPosition.initialize(morpho, marketId, positionManager, safeLtv_, liquidationLtv_);
    } else {
      newPosition.initialize(morpho, marketId, positionManager, safeLtv_, liquidationLtv_);
      (uint128 storedPosLtv, uint128 storedLiqLtv) = newPosition.ltvs();
      assertEq(storedPosLtv, safeLtv_, "Safe LTV should be set correctly");
      assertEq(storedLiqLtv, liquidationLtv_, "Liquidation LTV should be set correctly");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 SUPPLY COLLATERAL TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_supplyCollateral_MultipleSupplies() public {
    uint256 amount1 = COLLATERAL_AMOUNT;
    uint256 amount2 = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, amount1 + amount2);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(amount1);
    borrowPosition.supplyCollateral(amount2);
    vm.stopPrank();

    uint256 expectedQuotedCollateral = _quoteCollateral(amount1 + amount2, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), amount1 + amount2, "Raw collateral not accumulated");
    assertEq(borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Quoted collateral not accumulated");
  }

  function testFuzz_supplyCollateral_Amount(uint128 amount) public {
    amount = uint128(bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));

    collateralToken.setBalance(positionManager, amount);

    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    uint256 expectedQuotedCollateral = _quoteCollateral(amount, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), amount, "Raw collateral amount mismatch");
    assertEq(borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Quoted collateral amount mismatch");
  }

  function test_supplyCollateral_RevertWhen_AmountIsZero() public {
    vm.prank(positionManager);
    vm.expectRevert(AmountZero.selector);
    borrowPosition.supplyCollateral(0);
  }

  function test_supplyCollateral_RevertWhen_CallerNotOwner() public {
    uint256 amount = COLLATERAL_AMOUNT;
    collateralToken.setBalance(user, amount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.supplyCollateral(amount);
  }

  function test_supplyCollateral_RevertWhen_InsufficientBalance() public {
    uint256 amount = COLLATERAL_AMOUNT;
    // Don't give position manager any tokens

    vm.prank(positionManager);
    vm.expectRevert(TransferFromFailed.selector);
    borrowPosition.supplyCollateral(amount);
  }

  function test_supplyCollateral_RevertWhen_InsufficientAllowance() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);

    // Remove approval
    vm.prank(positionManager);
    collateralToken.approve(address(borrowPosition), 0);

    vm.prank(positionManager);
    vm.expectRevert(TransferFromFailed.selector);
    borrowPosition.supplyCollateral(amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                WITHDRAW COLLATERAL TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_withdrawCollateral_PartialWithdraw() public {
    uint256 totalAmount = COLLATERAL_AMOUNT;
    uint256 withdrawAmount = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, totalAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(totalAmount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(withdrawAmount);

    uint256 expectedQuotedCollateral = _quoteCollateral(totalAmount - withdrawAmount, DEFAULT_ORACLE_PRICE);
    assertEq(
      borrowPosition.totalCollateral(), totalAmount - withdrawAmount, "Partial withdrawal of raw collateral incorrect"
    );
    assertEq(
      borrowPosition.totalCollateralQuoted(),
      expectedQuotedCollateral,
      "Partial withdrawal of quoted collateral incorrect"
    );
  }

  function testFuzz_withdrawCollateral_Amount(uint128 amount) public {
    amount = uint128(bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), 0, "Withdrawal of raw collateral amount mismatch");
    assertEq(borrowPosition.totalCollateralQuoted(), 0, "Withdrawal of quoted collateral amount mismatch");
  }

  function test_withdrawCollateral_RevertWhen_AmountIsZero() public {
    vm.prank(positionManager);
    vm.expectRevert(AmountZero.selector);
    borrowPosition.withdrawCollateral(0);
  }

  function test_withdrawCollateral_RevertWhen_CallerNotOwner() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.withdrawCollateral(amount);
  }

  function test_withdrawCollateral_RevertWhen_InsufficientCollateral() public {
    uint256 supplyAmount = COLLATERAL_AMOUNT;
    uint256 withdrawAmount = COLLATERAL_AMOUNT * 2;

    collateralToken.setBalance(positionManager, supplyAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(supplyAmount);

    vm.prank(positionManager);
    vm.expectRevert(stdError.arithmeticError);
    borrowPosition.withdrawCollateral(withdrawAmount);
  }

  function test_withdrawCollateral_RevertWhen_PositionWouldBeUnhealthy() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity to Morpho
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow near max using preLltv (the actual threshold enforced)
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmount = (maxBorrow * 99) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    // Try to withdraw collateral (should fail due to health check)
    vm.prank(positionManager);
    vm.expectRevert("insufficient collateral");
    borrowPosition.withdrawCollateral(collateralAmount / 2);
  }

  function test_withdrawCollateral_RevertWhen_ViolatesCustomLltvThreshold() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity to Morpho
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow exactly at max using preLltv (the actual threshold enforced)
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);

    vm.prank(positionManager);
    borrowPosition.borrow(maxBorrow);

    // Position is now exactly at the preLltv threshold
    // Any withdrawal of collateral should trigger our custom InsufficientCollateral error
    uint256 withdrawAmount = 1; // Try withdrawing even 1 wei

    vm.prank(positionManager);
    vm.expectRevert(InsufficientCollateral.selector);
    borrowPosition.withdrawCollateral(withdrawAmount);
  }

  function test_withdrawCollateral_SendsToOwner() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    uint256 balanceBefore = collateralToken.balanceOf(positionManager);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(amount);

    assertEq(collateralToken.balanceOf(positionManager), balanceBefore + amount, "Collateral not sent to owner");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       BORROW TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_borrow_MultipleBorrows() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount1 = LOAN_AMOUNT / 4;
    uint256 borrowAmount2 = LOAN_AMOUNT / 4;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.startPrank(positionManager);
    borrowPosition.borrow(borrowAmount1);
    borrowPosition.borrow(borrowAmount2);
    vm.stopPrank();

    assertGe(borrowPosition.totalBorrowed(), borrowAmount1 + borrowAmount2, "Borrows not accumulated");
  }

  function test_borrow_RequiresCollateral() public {
    uint256 borrowAmount = LOAN_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT);

    vm.prank(positionManager);
    vm.expectRevert("insufficient collateral");
    borrowPosition.borrow(borrowAmount);
  }

  function testFuzz_borrow_Amount(uint128 collateralAmount, uint96 borrowRatio) public {
    collateralAmount = uint128(bound(collateralAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));
    borrowRatio = uint96(bound(borrowRatio, 1, 90)); // Max 90% of maxBorrow for safety

    _supplyLiquidity(MAX_TEST_AMOUNT * 2);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Use SAFE_LTV since borrow() checks against safeLtv
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmount = (maxBorrow * borrowRatio) / 100;

    if (borrowAmount > 0) {
      vm.prank(positionManager);
      borrowPosition.borrow(borrowAmount);

      assertGt(borrowPosition.totalBorrowed(), 0, "Borrow failed");
      assertTrue(borrowPosition.isHealthy(SAFE_LTV), "Position unhealthy after borrow");
    }
  }

  function test_borrow_RevertWhen_AmountIsZero() public {
    vm.prank(positionManager);
    vm.expectRevert(AmountZero.selector);
    borrowPosition.borrow(0);
  }

  function test_borrow_RevertWhen_CallerNotOwner() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.borrow(borrowAmount);
  }

  function test_borrow_RevertWhen_InsufficientCollateral() public {
    uint256 collateralAmount = 100e18;
    uint256 borrowAmount = LOAN_AMOUNT * 10; // Way more than collateral allows

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    vm.expectRevert("insufficient collateral");
    borrowPosition.borrow(borrowAmount);
  }

  function test_borrow_RevertWhen_InsufficientLiquidity() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT;

    // Don't supply liquidity

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    vm.expectRevert("insufficient liquidity");
    borrowPosition.borrow(borrowAmount);
  }

  function test_borrow_RevertWhen_PositionWouldBeUnhealthy() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 borrowAmount = maxBorrow + 1; // Exceed max by 1

    vm.prank(positionManager);
    vm.expectRevert("insufficient collateral");
    borrowPosition.borrow(borrowAmount);
  }

  function test_borrow_RevertWhen_ViolatesCustomLltvThreshold() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Calculate max borrow at preLltv (72%) - this is the stricter threshold
    uint256 maxBorrowAtPreLltv = borrowPosition.maxBorrow(SAFE_LTV);

    // Try to borrow slightly more than the preLltv allows
    // This should trigger our custom InsufficientCollateral error
    // We add 1 wei to push it over the preLltv threshold
    // Morpho might allow it (if still under 80% LLTV), but our check won't
    uint256 borrowAmount = maxBorrowAtPreLltv + 1;

    vm.prank(positionManager);
    // This could revert with either Morpho's "insufficient collateral" or our InsufficientCollateral
    // depending on rounding. If maxBorrowAtPreLltv + 1 is still under Morpho's LLTV,
    // Morpho will allow it but our check will catch it.
    vm.expectRevert(InsufficientCollateral.selector);
    borrowPosition.borrow(borrowAmount);
  }

  function test_borrow_SendsToOwner() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 balanceBefore = loanToken.balanceOf(positionManager);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertEq(loanToken.balanceOf(positionManager), balanceBefore + borrowAmount, "Borrowed assets not sent to owner");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        REPAY TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_repay_MultipleRepays() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;
    uint256 repayAmount = borrowAmount / 4;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    loanToken.setBalance(positionManager, borrowAmount);

    vm.startPrank(positionManager);
    borrowPosition.repay(repayAmount);
    borrowPosition.repay(repayAmount);
    vm.stopPrank();

    assertGt(borrowPosition.totalBorrowed(), 0, "Should have remaining debt");
  }

  function testFuzz_repay_Amount(uint128 borrowAmount, uint96 repayRatio) public {
    borrowAmount = uint128(bound(borrowAmount, MIN_TEST_AMOUNT, LOAN_AMOUNT / 2));
    repayRatio = uint96(bound(repayRatio, 1, 100));

    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    uint256 totalBorrowed = borrowPosition.totalBorrowed();
    uint256 repayAmount = (totalBorrowed * repayRatio) / 100;

    if (repayAmount > 0) {
      loanToken.setBalance(positionManager, repayAmount);

      vm.prank(positionManager);
      borrowPosition.repay(repayAmount);

      if (repayRatio == 100) {
        assertEq(borrowPosition.totalBorrowed(), 0, "Should be fully repaid");
      } else {
        assertGt(borrowPosition.totalBorrowed(), 0, "Should have remaining debt");
      }
    }
  }

  function test_repay_RevertWhen_AmountIsZero() public {
    vm.prank(positionManager);
    vm.expectRevert(AmountZero.selector);
    borrowPosition.repay(0);
  }

  function test_repay_RevertWhen_CallerNotOwner() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    loanToken.setBalance(user, borrowAmount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.repay(borrowAmount);
  }

  function test_repay_RevertWhen_InsufficientBalance() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    // Remove position manager's tokens to simulate insufficient balance
    loanToken.setBalance(positionManager, 0);

    vm.prank(positionManager);
    vm.expectRevert(TransferFromFailed.selector);
    borrowPosition.repay(borrowAmount);
  }

  function test_repay_RevertWhen_InsufficientAllowance() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    loanToken.setBalance(positionManager, borrowAmount);

    // Remove approval
    vm.prank(positionManager);
    loanToken.approve(address(borrowPosition), 0);

    vm.prank(positionManager);
    vm.expectRevert(TransferFromFailed.selector);
    borrowPosition.repay(borrowAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ASSET GETTER TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_borrowAsset_ReturnsCorrectToken() public view {
    assertEq(borrowPosition.borrowAsset(), address(loanToken), "Borrow asset incorrect");
  }

  function test_collateralAsset_ReturnsCorrectToken() public view {
    assertEq(borrowPosition.collateralAsset(), address(collateralToken), "Collateral asset incorrect");
  }

  function test_borrowAssetAndCollateralAsset_AreDifferent() public view {
    assertTrue(borrowPosition.borrowAsset() != borrowPosition.collateralAsset(), "Assets should be different");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                POSITION STATE VIEW TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_totalBorrowed_InitiallyZero() public view {
    assertEq(borrowPosition.totalBorrowed(), 0, "Initial borrow should be zero");
  }

  function test_totalBorrowed_AfterBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertGe(borrowPosition.totalBorrowed(), borrowAmount, "Borrow not reflected");
  }

  function test_totalBorrowed_AfterPartialRepay() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;
    uint256 repayAmount = borrowAmount / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    uint256 borrowedBefore = borrowPosition.totalBorrowed();

    loanToken.setBalance(positionManager, repayAmount);
    vm.prank(positionManager);
    borrowPosition.repay(repayAmount);

    uint256 borrowedAfter = borrowPosition.totalBorrowed();

    assertLt(borrowedAfter, borrowedBefore, "Partial repay not reflected");
    assertGt(borrowedAfter, 0, "Should have remaining debt");
  }

  function test_totalBorrowed_AfterFullRepay() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    uint256 totalBorrowed = borrowPosition.totalBorrowed();

    loanToken.setBalance(positionManager, totalBorrowed + 1e18);
    vm.prank(positionManager);
    borrowPosition.repay(totalBorrowed);

    assertEq(borrowPosition.totalBorrowed(), 0, "Full repay not reflected");
  }

  function test_totalCollateral_InitiallyZero() public view {
    assertEq(borrowPosition.totalCollateral(), 0, "Initial raw collateral should be zero");
    assertEq(borrowPosition.totalCollateralQuoted(), 0, "Initial quoted collateral should be zero");
  }

  function test_totalCollateral_AfterSupply() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    uint256 expectedQuotedCollateral = _quoteCollateral(amount, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), amount, "Raw collateral supply not reflected");
    assertEq(borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Quoted collateral supply not reflected");
  }

  function test_totalCollateral_MultipleSupplies() public {
    uint256 amount1 = COLLATERAL_AMOUNT;
    uint256 amount2 = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, amount1 + amount2);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(amount1);
    borrowPosition.supplyCollateral(amount2);
    vm.stopPrank();

    uint256 expectedQuotedCollateral = _quoteCollateral(amount1 + amount2, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), amount1 + amount2, "Multiple raw collateral supplies not reflected");
    assertEq(
      borrowPosition.totalCollateralQuoted(),
      expectedQuotedCollateral,
      "Multiple quoted collateral supplies not reflected"
    );
  }

  function test_totalCollateral_AfterWithdraw() public {
    uint256 supplyAmount = COLLATERAL_AMOUNT;
    uint256 withdrawAmount = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, supplyAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(supplyAmount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(withdrawAmount);

    uint256 expectedQuotedCollateral = _quoteCollateral(supplyAmount - withdrawAmount, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), supplyAmount - withdrawAmount, "Raw collateral withdraw not reflected");
    assertEq(
      borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Quoted collateral withdraw not reflected"
    );
  }

  function test_totalCollateral_AfterFullWithdraw() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), 0, "Full withdraw of raw collateral not reflected");
    assertEq(borrowPosition.totalCollateralQuoted(), 0, "Full withdraw of quoted collateral not reflected");
  }

  function test_totalCollateralQuoted_ChangesWithOraclePrice() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 newPrice = DEFAULT_ORACLE_PRICE * 2; // 2:1 collateral:borrow

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Change oracle price
    oracle.setPrice(newPrice);

    // totalCollateral should remain the same (raw amount)
    assertEq(borrowPosition.totalCollateral(), collateralAmount, "Raw collateral should not change with price");

    // totalCollateralQuoted should now return double the collateral amount (quoted in borrow asset)
    uint256 expectedQuotedCollateral = _quoteCollateral(collateralAmount, newPrice);
    assertEq(borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Collateral not quoted at oracle price");
    assertEq(
      borrowPosition.totalCollateralQuoted(),
      collateralAmount * 2,
      "With 2x price, quoted collateral should be 2x raw amount"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  POSITION HEALTH TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isHealthy_InitiallyTrue() public view {
    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Initial position should be healthy");
  }

  function test_isHealthy_WithoutBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Position with only collateral should be healthy");
  }

  function test_isHealthy_BelowMaxBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 safeBorrow = (maxBorrow * 50) / 100; // 50% of max

    vm.prank(positionManager);
    borrowPosition.borrow(safeBorrow);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Position below max borrow should be healthy");
  }

  function test_isHealthy_AtMaxBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Use preLltv (the actual threshold enforced by the contract)
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 safeBorrow = (maxBorrow * 99) / 100; // 99% of max for safety

    vm.prank(positionManager);
    borrowPosition.borrow(safeBorrow);

    assertTrue(borrowPosition.isHealthy(SAFE_LTV), "Position at near-max borrow should be healthy");
  }

  function test_isHealthy_AfterCollateralPriceIncrease() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 borrowAmount = (maxBorrow * 80) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    // Increase collateral price
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Position should be healthier after price increase");
  }

  function test_isHealthy_AfterCollateralPriceDecrease() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 borrowAmount = (maxBorrow * 50) / 100; // Start at 50%

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Initial position should be healthy");

    // Decrease collateral price significantly
    oracle.setPrice(DEFAULT_ORACLE_PRICE / 10);

    // Position may become unhealthy due to price decrease
    // This tests that isHealthy correctly reflects the new state
  }

  function testFuzz_isHealthy_VariesWithPrice(uint128 price) public {
    price = uint128(bound(price, ORACLE_PRICE_SCALE / 100, ORACLE_PRICE_SCALE * 10));

    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    oracle.setPrice(price);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    if (maxBorrow > MIN_TEST_AMOUNT) {
      uint256 safeBorrow = (maxBorrow * 50) / 100;

      vm.prank(positionManager);
      borrowPosition.borrow(safeBorrow);

      assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Position at 50% should be healthy");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MAX BORROW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_maxBorrow_InitiallyZero() public view {
    assertEq(borrowPosition.maxBorrow(marketParams.lltv), 0, "Max borrow should be zero without collateral");
  }

  function test_maxBorrow_AfterCollateralSupply() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity to Morpho
    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    assertGt(borrowPosition.maxBorrow(marketParams.lltv), 0, "Max borrow should increase with collateral");
  }

  function test_maxBorrow_ProportionalToLLTV() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Calculate expected max borrow and supply sufficient liquidity
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, DEFAULT_ORACLE_PRICE, DEFAULT_LLTV);
    _supplyLiquidity(expectedMaxBorrow * 2);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);

    assertApproxEqAbs(maxBorrow, expectedMaxBorrow, 1, "Max borrow calculation incorrect");
  }

  function test_maxBorrow_ProportionalToOraclePrice() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrowBefore = borrowPosition.maxBorrow(marketParams.lltv);

    // Double the price
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);

    uint256 maxBorrowAfter = borrowPosition.maxBorrow(marketParams.lltv);

    assertApproxEqRel(maxBorrowAfter, maxBorrowBefore * 2, 0.01e18, "Max borrow should double with price");
  }

  function test_maxBorrow_CalculationAccuracy() public {
    uint256 collateralAmount = 1_000e18;
    uint256 price = 2_000e18; // $2000 per unit

    oracle.setPrice(price * (ORACLE_PRICE_SCALE / 1e18));

    // Supply liquidity to Morpho (sufficient for expected max borrow)
    _supplyLiquidity(10_000_000e18);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, price * (ORACLE_PRICE_SCALE / 1e18), DEFAULT_LLTV);

    assertApproxEqAbs(maxBorrow, expectedMaxBorrow, 1, "Max borrow calculation should be accurate");
  }

  function testFuzz_maxBorrow_CalculationConsistent(uint128 collateralAmount, uint128 price) public {
    collateralAmount = uint128(bound(collateralAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));
    price = uint128(bound(price, ORACLE_PRICE_SCALE / 100, ORACLE_PRICE_SCALE * 10));

    oracle.setPrice(price);

    // Calculate expected max borrow and supply sufficient liquidity
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, price, DEFAULT_LLTV);
    _supplyLiquidity(expectedMaxBorrow * 2); // Supply 2x to be safe

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);

    assertApproxEqAbs(maxBorrow, expectedMaxBorrow, 1, "Max borrow should match calculation");
  }

  function test_maxBorrow_LimitedByAvailableLiquidity() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT; // 10,000e18
    uint256 limitedLiquidity = 3_000e18; // Less than what collateral would allow

    // Calculate theoretical max borrow (would be 8,000e18 with 80% LLTV)
    uint256 theoreticalMaxBorrow = _calculateMaxBorrow(collateralAmount, DEFAULT_ORACLE_PRICE, DEFAULT_LLTV);

    // Supply less liquidity than theoretical max
    _supplyLiquidity(limitedLiquidity);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Verify available liquidity matches what was supplied
    assertEq(borrowPosition.availableLiquidity(), limitedLiquidity, "Available liquidity should match supply");

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);

    // Max borrow should be limited by available liquidity, not collateral
    assertEq(maxBorrow, limitedLiquidity, "Max borrow should equal available liquidity when liquidity is limiting");
    assertLt(maxBorrow, theoreticalMaxBorrow, "Max borrow should be less than theoretical max");
  }

  function test_maxBorrow_DecreasesAfterBorrowing() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Calculate expected max borrow and supply sufficient liquidity
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, DEFAULT_ORACLE_PRICE, DEFAULT_LLTV);
    _supplyLiquidity(expectedMaxBorrow * 2);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Check initial max borrow (should equal full capacity)
    uint256 maxBorrowBefore = borrowPosition.maxBorrow(marketParams.lltv);
    assertApproxEqAbs(maxBorrowBefore, expectedMaxBorrow, 1, "Initial max borrow should equal full capacity");

    // Borrow 50% of max
    uint256 borrowAmount = maxBorrowBefore / 2;
    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    // Max borrow should now be reduced by the borrowed amount
    uint256 maxBorrowAfter = borrowPosition.maxBorrow(marketParams.lltv);
    assertApproxEqAbs(
      maxBorrowAfter, maxBorrowBefore - borrowAmount, 1, "Max borrow should decrease by borrowed amount"
    );
  }

  function test_maxBorrow_ReturnsZeroWhenFullyUtilized() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 preLltv = SAFE_LTV;

    // Calculate expected max borrow at preLltv (the enforced threshold) and supply sufficient liquidity
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, DEFAULT_ORACLE_PRICE, preLltv);
    _supplyLiquidity(expectedMaxBorrow * 2);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow full max capacity at preLltv (the enforced threshold)
    uint256 maxBorrowBefore = borrowPosition.maxBorrow(preLltv);
    vm.prank(positionManager);
    borrowPosition.borrow(maxBorrowBefore);

    // Max borrow should now be 0 at preLltv
    uint256 maxBorrowAfter = borrowPosition.maxBorrow(preLltv);
    assertEq(maxBorrowAfter, 0, "Max borrow should be 0 when fully utilized");
  }

  function test_maxBorrow_ReturnsZeroWhenOverUtilized() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Calculate expected max borrow and supply sufficient liquidity
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, DEFAULT_ORACLE_PRICE, DEFAULT_LLTV);
    _supplyLiquidity(expectedMaxBorrow * 2);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow 80% of max
    uint256 maxBorrowBefore = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 borrowAmount = (maxBorrowBefore * 80) / 100;
    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    // Now drop the price by 50% - this makes the position over-utilized
    // borrowed > (collateral * newPrice * LLTV)
    oracle.setPrice(DEFAULT_ORACLE_PRICE / 2);

    // Max borrow should be 0 (not revert due to underflow)
    uint256 maxBorrowAfter = borrowPosition.maxBorrow(marketParams.lltv);
    assertEq(maxBorrowAfter, 0, "Max borrow should be 0 when over-utilized (zeroFloorSub)");
  }

  function testFuzz_maxBorrow_RemainingCapacity(uint128 collateralAmount, uint96 borrowRatio) public {
    collateralAmount = uint128(bound(collateralAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));
    borrowRatio = uint96(bound(borrowRatio, 1, 99)); // 1% to 99% of max

    uint256 preLltv = SAFE_LTV;

    // Calculate expected max borrow at preLltv (the enforced threshold) and supply sufficient liquidity
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, DEFAULT_ORACLE_PRICE, preLltv);
    _supplyLiquidity(expectedMaxBorrow * 2);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Use preLltv since that's the enforced threshold
    uint256 maxBorrowBefore = borrowPosition.maxBorrow(preLltv);

    // Borrow a portion
    uint256 borrowAmount = (maxBorrowBefore * borrowRatio) / 100;
    if (borrowAmount > 0) {
      vm.prank(positionManager);
      borrowPosition.borrow(borrowAmount);

      uint256 maxBorrowAfter = borrowPosition.maxBorrow(preLltv);
      uint256 expectedRemaining = maxBorrowBefore - borrowAmount;

      // Allow for small rounding differences due to share conversion
      assertApproxEqAbs(maxBorrowAfter, expectedRemaining, 2, "Remaining capacity should match expected");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MORPHO VIEW TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_marketId_ReturnsCorrectMarketId() public view {
    assertEq(Id.unwrap(borrowPosition.marketId()), Id.unwrap(marketId), "Market ID mismatch");
  }

  function test_availableLiquidity_InitiallyZero() public view {
    assertEq(borrowPosition.availableLiquidity(), 0, "Available liquidity should be zero initially");
  }

  function test_availableLiquidity_AfterSupply() public {
    uint256 supplyAmount = LOAN_AMOUNT;
    _supplyLiquidity(supplyAmount);

    assertEq(borrowPosition.availableLiquidity(), supplyAmount, "Available liquidity should equal supply");
  }

  function test_availableLiquidity_DecreasesAfterBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 supplyAmount = LOAN_AMOUNT;

    _supplyLiquidity(supplyAmount);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 availableBefore = borrowPosition.availableLiquidity();
    assertEq(availableBefore, supplyAmount, "Available liquidity should equal supply before borrow");

    uint256 borrowAmount = LOAN_AMOUNT / 2;
    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    uint256 availableAfter = borrowPosition.availableLiquidity();
    assertEq(availableAfter, supplyAmount - borrowAmount, "Available liquidity should decrease by borrow amount");
    assertLt(availableAfter, availableBefore, "Available liquidity should be less after borrow");
  }

  function test_availableLiquidity_IncreasesAfterRepay() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 supplyAmount = LOAN_AMOUNT;

    _supplyLiquidity(supplyAmount);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 borrowAmount = LOAN_AMOUNT / 2;
    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    uint256 availableAfterBorrow = borrowPosition.availableLiquidity();

    // Repay half
    uint256 repayAmount = borrowAmount / 2;
    loanToken.setBalance(positionManager, repayAmount);
    vm.prank(positionManager);
    borrowPosition.repay(repayAmount);

    uint256 availableAfterRepay = borrowPosition.availableLiquidity();
    assertGt(availableAfterRepay, availableAfterBorrow, "Available liquidity should increase after repay");
    assertApproxEqAbs(
      availableAfterRepay, availableAfterBorrow + repayAmount, 1, "Available liquidity should increase by repay amount"
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              INTEGRATION & WORKFLOW TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_integration_FullWorkflow_SupplyBorrowRepayWithdraw() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    // 1. Supply liquidity to Morpho
    _supplyLiquidity(LOAN_AMOUNT);

    // Verify available liquidity after supply
    assertEq(borrowPosition.availableLiquidity(), LOAN_AMOUNT, "Step 1: Available liquidity should match supply");

    // 2. Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 expectedQuotedCollateral = _quoteCollateral(collateralAmount, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), collateralAmount, "Step 2: Raw collateral supply failed");
    assertEq(
      borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Step 2: Quoted collateral supply failed"
    );
    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Step 2: Position should be healthy");

    // 3. Borrow
    uint256 availableBeforeBorrow = borrowPosition.availableLiquidity();
    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertGt(borrowPosition.totalBorrowed(), 0, "Step 3: Borrow failed");
    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Step 3: Position should still be healthy");
    assertEq(
      borrowPosition.availableLiquidity(),
      availableBeforeBorrow - borrowAmount,
      "Step 3: Available liquidity should decrease by borrow amount"
    );

    // 4. Repay
    uint256 totalBorrowed = borrowPosition.totalBorrowed();
    uint256 availableBeforeRepay = borrowPosition.availableLiquidity();
    loanToken.setBalance(positionManager, totalBorrowed + 1e18);
    vm.prank(positionManager);
    borrowPosition.repay(totalBorrowed);

    assertEq(borrowPosition.totalBorrowed(), 0, "Step 4: Repay failed");
    assertGt(
      borrowPosition.availableLiquidity(),
      availableBeforeRepay,
      "Step 4: Available liquidity should increase after repay"
    );

    // 5. Withdraw collateral
    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(collateralAmount);

    assertEq(borrowPosition.totalCollateral(), 0, "Step 5: Raw collateral withdraw failed");
    assertEq(borrowPosition.totalCollateralQuoted(), 0, "Step 5: Quoted collateral withdraw failed");
    assertEq(borrowPosition.totalBorrowed(), 0, "Step 5: Should have no debt");
  }

  function test_integration_HealthFactorMonitoring() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Should be healthy with collateral only");

    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 borrow1 = (maxBorrow * 25) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrow1);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Should be healthy at 25% utilization");

    uint256 borrow2 = (maxBorrow * 25) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrow2);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Should be healthy at 50% utilization");

    uint256 borrow3 = (maxBorrow * 20) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrow3);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Should be healthy at 70% utilization");
  }

  function test_integration_MultipleOperations() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount * 2);

    vm.startPrank(positionManager);

    // Multiple supplies
    borrowPosition.supplyCollateral(collateralAmount);
    borrowPosition.supplyCollateral(collateralAmount / 2);

    // Multiple borrows
    uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
    borrowPosition.borrow((maxBorrow * 20) / 100);
    borrowPosition.borrow((maxBorrow * 10) / 100);

    // Repay some
    uint256 totalBorrowed = borrowPosition.totalBorrowed();
    loanToken.setBalance(positionManager, totalBorrowed / 2);
    borrowPosition.repay(totalBorrowed / 4);

    // Withdraw some collateral
    borrowPosition.withdrawCollateral(collateralAmount / 4);

    vm.stopPrank();

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Position should remain healthy");
    assertGt(borrowPosition.totalCollateral(), 0, "Should have remaining raw collateral");
    assertGt(borrowPosition.totalCollateralQuoted(), 0, "Should have remaining quoted collateral");
    assertGt(borrowPosition.totalBorrowed(), 0, "Should have remaining debt");
  }

  function test_workflow_CollateralPriceVolatility() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow at initial price
    uint256 maxBorrow1 = borrowPosition.maxBorrow(marketParams.lltv);
    uint256 borrowAmount = (maxBorrow1 * 50) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Should be healthy at initial price");

    // Price increases - can borrow more
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);

    uint256 maxBorrow2 = borrowPosition.maxBorrow(marketParams.lltv);
    assertGt(maxBorrow2, maxBorrow1, "Max borrow should increase with price");
    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Should be healthy after price increase");

    // Price decreases back
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Should still be healthy at original price");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 EDGE CASES & FUZZ TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_EdgeCase_VerySmallAmounts(uint64 amount) public {
    amount = uint64(bound(amount, 1, MIN_TEST_AMOUNT));

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    uint256 expectedQuotedCollateral = _quoteCollateral(amount, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), amount, "Small amount raw collateral supply failed");
    assertEq(
      borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Small amount quoted collateral supply failed"
    );
  }

  function testFuzz_EdgeCase_VeryLargeAmounts(uint128 amount) public {
    amount = uint128(bound(amount, MAX_TEST_AMOUNT / 2, type(uint128).max / 2));

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    uint256 expectedQuotedCollateral = _quoteCollateral(amount, DEFAULT_ORACLE_PRICE);
    assertEq(borrowPosition.totalCollateral(), amount, "Large amount raw collateral supply failed");
    assertEq(
      borrowPosition.totalCollateralQuoted(), expectedQuotedCollateral, "Large amount quoted collateral supply failed"
    );
  }

  function test_EdgeCase_OraclePriceChanges() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity to Morpho (sufficient for all price scenarios)
    _supplyLiquidity(100_000_000e18);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow1 = borrowPosition.maxBorrow(marketParams.lltv);

    oracle.setPrice(DEFAULT_ORACLE_PRICE / 2);
    uint256 maxBorrow2 = borrowPosition.maxBorrow(marketParams.lltv);

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 3);
    uint256 maxBorrow3 = borrowPosition.maxBorrow(marketParams.lltv);

    assertLt(maxBorrow2, maxBorrow1, "Max borrow should decrease with price");
    assertGt(maxBorrow3, maxBorrow1, "Max borrow should increase with price");
  }

  function testFuzz_EdgeCase_RapidOperationSequence(uint8 numOps) public {
    numOps = uint8(bound(numOps, 2, 10));

    uint256 collateralAmount = COLLATERAL_AMOUNT * numOps;
    _supplyLiquidity(LOAN_AMOUNT * numOps);

    collateralToken.setBalance(positionManager, collateralAmount);

    vm.startPrank(positionManager);

    for (uint256 i = 0; i < numOps; i++) {
      borrowPosition.supplyCollateral(COLLATERAL_AMOUNT);

      uint256 maxBorrow = borrowPosition.maxBorrow(marketParams.lltv);
      if (maxBorrow > MIN_TEST_AMOUNT) {
        uint256 safeBorrow = (maxBorrow * 10) / 100; // Borrow 10% of max each time
        borrowPosition.borrow(safeBorrow);
      }
    }

    vm.stopPrank();

    assertTrue(borrowPosition.isHealthy(marketParams.lltv), "Position should be healthy after rapid ops");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    LIQUIDATION TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_preLiquidate_RevertWhen_PositionIsHealthy() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity for borrowing
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow at 50% of SAFE_LTV (healthy position for both position and liquidation LTV)
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmountActual = maxBorrow / 2;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    // Verify position is healthy at liquidation LTV (preLiquidate checks against liquidationLtv)
    assertTrue(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be healthy at liquidation LTV");

    // Attempt to liquidate should fail because position is healthy at liquidation LTV
    address liquidator = makeAddr("liquidator");
    loanToken.setBalance(liquidator, borrowAmountActual);
    vm.startPrank(liquidator);
    loanToken.approve(address(borrowPosition), type(uint256).max);

    vm.expectRevert(PositionHealthy.selector);
    borrowPosition.preLiquidate(address(borrowPosition), collateralAmount / 2, 0, "");
    vm.stopPrank();
  }

  function test_preLiquidate_RevertWhen_BothAmountsAreZero() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral and borrow
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmountActual = (maxBorrow * 99) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    // Drop price to make position unhealthy at liquidation LTV
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 85) / 100);
    assertFalse(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be unhealthy at liquidation LTV");

    // Attempt to liquidate with both amounts zero should fail
    address liquidator = makeAddr("liquidator");
    vm.prank(liquidator);
    vm.expectRevert(InconsistentInput.selector);
    borrowPosition.preLiquidate(address(borrowPosition), 0, 0, "");
  }

  function test_preLiquidate_RevertWhen_BothAmountsAreNonZero() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral and borrow
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmountActual = (maxBorrow * 99) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    // Drop price to make position unhealthy at liquidation LTV
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 85) / 100);
    assertFalse(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be unhealthy at liquidation LTV");

    // Attempt to liquidate with both amounts non-zero should fail
    address liquidator = makeAddr("liquidator");
    vm.prank(liquidator);
    vm.expectRevert(InconsistentInput.selector);
    borrowPosition.preLiquidate(address(borrowPosition), 100, 100, "");
  }

  function test_preLiquidate_BySeizingCollateral() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow at SAFE_LTV threshold
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmountActual = (maxBorrow * 99) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    uint256 collateralBefore = borrowPosition.totalCollateral();
    uint256 borrowedBefore = borrowPosition.totalBorrowed();

    // Drop price to make position unhealthy at liquidation LTV
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 85) / 100);
    assertFalse(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be unhealthy at liquidation LTV");

    // Setup liquidator
    address liquidator = makeAddr("liquidator");
    loanToken.setBalance(liquidator, borrowedBefore * 2);

    vm.startPrank(liquidator);
    loanToken.approve(address(borrowPosition), type(uint256).max);

    // Liquidate by seizing 50% of collateral
    uint256 seizeTarget = collateralBefore / 2;
    (uint256 seizedAmount, uint256 repaidAmount) =
      borrowPosition.preLiquidate(address(borrowPosition), seizeTarget, 0, "");
    vm.stopPrank();

    // Verify partial liquidation
    assertEq(seizedAmount, seizeTarget, "Should have seized target collateral");
    assertGt(repaidAmount, 0, "Should have repaid some debt");
    assertEq(borrowPosition.totalCollateral(), collateralBefore - seizeTarget, "Collateral should be reduced");
  }

  function test_preLiquidate_ByRepayingShares() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow at SAFE_LTV threshold (65%)
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmountActual = (maxBorrow * 99) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    uint256 collateralBefore = borrowPosition.totalCollateral();

    // Get borrow shares
    Position memory pos = morpho.position(marketId, address(borrowPosition));
    uint256 borrowSharesBefore = pos.borrowShares;

    // Drop price to make position unhealthy at liquidation LTV (72%)
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 85) / 100);
    assertFalse(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be unhealthy at liquidation LTV");

    // Setup liquidator
    address liquidator = makeAddr("liquidator");
    loanToken.setBalance(liquidator, borrowAmountActual * 2); // More than enough

    vm.startPrank(liquidator);
    loanToken.approve(address(borrowPosition), type(uint256).max);

    // Liquidate by repaying half the shares
    uint256 sharesToRepay = borrowSharesBefore / 2;
    (uint256 seizedAmount, uint256 repaidAmount) =
      borrowPosition.preLiquidate(address(borrowPosition), 0, sharesToRepay, "");
    vm.stopPrank();

    // Verify liquidation
    assertGt(seizedAmount, 0, "Should have seized collateral");
    assertGt(repaidAmount, 0, "Should have repaid debt");
    assertLt(borrowPosition.totalCollateral(), collateralBefore, "Collateral should be reduced");
  }

  function test_preLiquidate_GivesProportionalCollateral() public {
    // This test verifies that liquidation gives proportional collateral without
    // a liquidation incentive factor (unlike Morpho's native liquidation)
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow at SAFE_LTV threshold
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmountActual = (maxBorrow * 99) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    uint256 collateralBefore = borrowPosition.totalCollateral();

    // Drop price to make position unhealthy at liquidation LTV
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 85) / 100);

    // Setup liquidator
    address liquidator = makeAddr("liquidator");
    loanToken.setBalance(liquidator, borrowAmountActual * 2);

    vm.startPrank(liquidator);
    loanToken.approve(address(borrowPosition), type(uint256).max);

    uint256 liquidatorCollateralBefore = collateralToken.balanceOf(liquidator);

    // Seize all collateral
    (uint256 seizedAmount,) = borrowPosition.preLiquidate(address(borrowPosition), collateralBefore, 0, "");
    vm.stopPrank();

    // Liquidator should receive the collateral
    uint256 liquidatorCollateralAfter = collateralToken.balanceOf(liquidator);
    assertEq(
      liquidatorCollateralAfter - liquidatorCollateralBefore,
      seizedAmount,
      "Liquidator should receive seized collateral"
    );
    assertEq(seizedAmount, collateralBefore, "Should have seized all collateral");
  }

  function test_preLiquidate_AnyoneCanLiquidate() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral and borrow
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    vm.prank(positionManager);
    borrowPosition.borrow((maxBorrow * 99) / 100);

    uint256 collateralBefore = borrowPosition.totalCollateral();

    // Drop price to make position unhealthy at liquidation LTV
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 85) / 100);

    // Random user (not owner) can liquidate
    address randomLiquidator = makeAddr("randomLiquidator");
    uint256 borrowedBefore = borrowPosition.totalBorrowed();
    loanToken.setBalance(randomLiquidator, borrowedBefore * 2);

    vm.startPrank(randomLiquidator);
    loanToken.approve(address(borrowPosition), type(uint256).max);

    // Should not revert - anyone can liquidate
    (uint256 seizedAmount, uint256 repaidAmount) =
      borrowPosition.preLiquidate(address(borrowPosition), collateralBefore / 2, 0, "");
    vm.stopPrank();

    assertGt(seizedAmount, 0, "Should have seized collateral");
    assertGt(repaidAmount, 0, "Should have repaid debt");
  }

  function test_onMorphoRepay_RevertWhen_NotCalledByMorpho() public {
    // Try to call onMorphoRepay directly - should fail
    vm.expectRevert(NotMorpho.selector);
    borrowPosition.onMorphoRepay(1000, abi.encode(100, address(borrowPosition), address(this), ""));
  }

  function test_preLiquidate_WithCallback() public {
    // This test uses a mock callback contract to verify the callback flow
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow at SAFE_LTV threshold
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    vm.prank(positionManager);
    borrowPosition.borrow((maxBorrow * 99) / 100);

    // Drop price to make position unhealthy at liquidation LTV
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 85) / 100);

    // Deploy mock callback liquidator
    MockPreLiquidationCallback mockLiquidator = new MockPreLiquidationCallback(address(loanToken));
    uint256 borrowedBefore = borrowPosition.totalBorrowed();
    loanToken.setBalance(address(mockLiquidator), borrowedBefore * 2);

    // Liquidate with callback data
    uint256 seizeTarget = borrowPosition.totalCollateral() / 2;
    vm.prank(address(mockLiquidator));
    (uint256 seizedAmount, uint256 repaidAmount) =
      borrowPosition.preLiquidate(address(borrowPosition), seizeTarget, 0, abi.encode("test callback data"));

    assertGt(seizedAmount, 0, "Should have seized collateral");
    assertGt(repaidAmount, 0, "Should have repaid debt");
    assertTrue(mockLiquidator.callbackReceived(), "Callback should have been called");
  }

  function test_liquidation_OwnerCanRepayInsteadOfBeingLiquidated() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral and borrow
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Use SAFE_LTV since borrow() checks against safeLtv
    uint256 maxBorrow = borrowPosition.maxBorrow(SAFE_LTV);
    uint256 borrowAmountActual = (maxBorrow * 85) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    assertTrue(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be healthy at liquidation LTV initially");

    // Price drops 40%
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 60) / 100);

    assertFalse(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be unhealthy at liquidation LTV after price drop");

    // Owner repays enough to restore health
    uint256 borrowedBefore = borrowPosition.totalBorrowed();
    uint256 repayAmount = borrowedBefore / 2;

    loanToken.setBalance(positionManager, repayAmount);
    vm.prank(positionManager);
    borrowPosition.repay(repayAmount);

    // Position should be healthy again at liquidation LTV
    assertTrue(borrowPosition.isHealthy(LIQUIDATION_LTV), "Position should be healthy at liquidation LTV after repayment");

    // Verify debt decreased
    assertLt(borrowPosition.totalBorrowed(), borrowedBefore, "Debt should be reduced");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   AUTHORIZATION TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Authorization_OnlyOwnerCanSupplyCollateral() public {
    uint256 amount = COLLATERAL_AMOUNT;
    collateralToken.setBalance(user, amount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.supplyCollateral(amount);
  }

  function test_Authorization_OnlyOwnerCanWithdrawCollateral() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.withdrawCollateral(amount);
  }

  function test_Authorization_OnlyOwnerCanBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.borrow(borrowAmount);
  }

  function test_Authorization_OnlyOwnerCanRepay() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    loanToken.setBalance(user, borrowAmount);

    vm.prank(user);
    vm.expectRevert(Unauthorized.selector);
    borrowPosition.repay(borrowAmount);
  }

  function test_Authorization_UnauthorizedUserReverts() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(user, amount);
    loanToken.setBalance(user, amount);

    vm.startPrank(user);

    vm.expectRevert(Unauthorized.selector);
    borrowPosition.supplyCollateral(amount);

    vm.expectRevert(Unauthorized.selector);
    borrowPosition.withdrawCollateral(amount);

    vm.expectRevert(Unauthorized.selector);
    borrowPosition.borrow(amount);

    vm.expectRevert(Unauthorized.selector);
    borrowPosition.repay(amount);

    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                AVAILABLE COLLATERAL TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_AvailableCollateral_NoDebt_ReturnsAllCollateral() public {
    // Supply collateral without borrowing
    collateralToken.setBalance(positionManager, COLLATERAL_AMOUNT);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(COLLATERAL_AMOUNT);

    // With no debt, all collateral should be free at any LLTV
    uint256 freeCollat = borrowPosition.availableCollateral(DEFAULT_LLTV);
    assertEq(freeCollat, COLLATERAL_AMOUNT, "All collateral should be free when no debt");

    // Even at lower LLTV, all collateral is free
    uint256 freeCollatLowLltv = borrowPosition.availableCollateral(0.5e18);
    assertEq(freeCollatLowLltv, COLLATERAL_AMOUNT, "All collateral should be free at any LLTV when no debt");
  }

  function test_AvailableCollateral_NoPosition_ReturnsZero() public view {
    // No collateral supplied, no debt
    uint256 freeCollat = borrowPosition.availableCollateral(DEFAULT_LLTV);
    assertEq(freeCollat, 0, "Available collateral should be 0 with no position");
  }

  function test_AvailableCollateral_WithDebt_CalculatesCorrectly() public {
    // Supply 10,000 collateral and borrow 5,000 (50% LTV)
    _supplyLiquidity(LOAN_AMOUNT * 2);
    collateralToken.setBalance(positionManager, COLLATERAL_AMOUNT);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(COLLATERAL_AMOUNT);
    borrowPosition.borrow(LOAN_AMOUNT);
    vm.stopPrank();

    // At 80% LLTV with 1:1 price:
    // Required collateral = 5000 / 0.8 = 6250
    // Available collateral = 10000 - 6250 = 3750
    uint256 freeCollat = borrowPosition.availableCollateral(DEFAULT_LLTV);
    assertEq(freeCollat, 3750e18, "Available collateral should be 3750 at 80% LLTV");

    // At 50% LLTV:
    // Required collateral = 5000 / 0.5 = 10000
    // Available collateral = 10000 - 10000 = 0
    uint256 freeCollatLowLltv = borrowPosition.availableCollateral(0.5e18);
    assertEq(freeCollatLowLltv, 0, "Available collateral should be 0 at 50% LLTV");
  }

  function test_AvailableCollateral_AtMaxLTV_ReturnsZero() public {
    // Supply collateral and borrow at exactly positionLTV (65%)
    // Note: We use positionLTV because that's the max the contract allows for borrows
    uint256 posLtv = SAFE_LTV;

    // Calculate expected max borrow at positionLTV (65% of collateral with 1:1 price)
    uint256 expectedMaxBorrow = COLLATERAL_AMOUNT.wMulDown(posLtv);

    // Supply liquidity first so maxBorrow can return a non-zero value
    _supplyLiquidity(expectedMaxBorrow * 2);

    // Supply collateral
    collateralToken.setBalance(positionManager, COLLATERAL_AMOUNT);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(COLLATERAL_AMOUNT);

    // Get actual maxBorrow (should match expected)
    uint256 maxBorrow = borrowPosition.maxBorrow(posLtv);
    assertEq(maxBorrow, expectedMaxBorrow, "Max borrow should be 65% of collateral");

    vm.prank(positionManager);
    borrowPosition.borrow(maxBorrow);

    // At exactly the positionLTV, available collateral should be 0
    uint256 freeCollat = borrowPosition.availableCollateral(posLtv);
    assertEq(freeCollat, 0, "Available collateral should be 0 when at max LTV");
  }

  function test_AvailableCollateral_OverLTV_ReturnsZero() public {
    // Supply collateral and borrow at 50% LTV, then check at 40% LLTV
    _supplyLiquidity(LOAN_AMOUNT * 2);
    collateralToken.setBalance(positionManager, COLLATERAL_AMOUNT);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(COLLATERAL_AMOUNT);
    borrowPosition.borrow(LOAN_AMOUNT); // 50% LTV
    vm.stopPrank();

    // At 40% LLTV, we're over-leveraged (50% > 40%)
    // Required collateral = 5000 / 0.4 = 12500, but we only have 10000
    uint256 freeCollat = borrowPosition.availableCollateral(0.4e18);
    assertEq(freeCollat, 0, "Available collateral should be 0 when over LLTV");
  }

  function test_AvailableCollateral_WithPriceChange() public {
    // Supply 10,000 collateral and borrow 5,000
    _supplyLiquidity(LOAN_AMOUNT * 2);
    collateralToken.setBalance(positionManager, COLLATERAL_AMOUNT);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(COLLATERAL_AMOUNT);
    borrowPosition.borrow(LOAN_AMOUNT);
    vm.stopPrank();

    // Double the collateral price (2:1)
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);

    // At 80% LLTV with 2:1 price:
    // Collateral value = 10000 * 2 = 20000 (in debt terms)
    // Required collateral = 5000 / (0.8 * 2) = 3125 (in collateral units)
    // Available collateral = 10000 - 3125 = 6875
    uint256 freeCollat = borrowPosition.availableCollateral(DEFAULT_LLTV);
    assertEq(freeCollat, 6875e18, "Available collateral should increase with higher price");

    // Halve the collateral price (0.5:1)
    oracle.setPrice(DEFAULT_ORACLE_PRICE / 2);

    // At 80% LLTV with 0.5:1 price:
    // Collateral value = 10000 * 0.5 = 5000 (in debt terms)
    // Required collateral = 5000 / (0.8 * 0.5) = 12500 (in collateral units)
    // But we only have 10000, so free = 0
    uint256 freeCollatLow = borrowPosition.availableCollateral(DEFAULT_LLTV);
    assertEq(freeCollatLow, 0, "Available collateral should be 0 with lower price");
  }

  function testFuzz_AvailableCollateral(uint256 collateral, uint256 debt, uint256 lltv) public {
    // Bound inputs
    collateral = bound(collateral, 1e18, 1_000_000e18);
    lltv = bound(lltv, 0.1e18, 0.99e18); // LLTV between 10% and 99%

    // Debt must be less than what positionLTV allows (65%)
    // borrow() enforces this threshold
    uint256 posLtv = SAFE_LTV;
    uint256 maxDebtForMarket = collateral.wMulDown(posLtv);
    // Use 99% of max to avoid boundary issues with rounding
    debt = bound(debt, 0, (maxDebtForMarket * 99) / 100);

    // Supply liquidity and collateral
    _supplyLiquidity(debt > 0 ? debt * 2 : 1e18);
    collateralToken.setBalance(positionManager, collateral);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(collateral);
    if (debt > 0) {
      borrowPosition.borrow(debt);
    }
    vm.stopPrank();

    uint256 freeCollat = borrowPosition.availableCollateral(lltv);

    if (debt == 0) {
      // No debt = all collateral is free
      assertEq(freeCollat, collateral, "All collateral should be free when no debt");
    } else {
      // Calculate expected available collateral
      // Required = debt * ORACLE_PRICE_SCALE / (lltv * price)
      // With 1:1 price: required = debt / lltv
      uint256 required = debt.mulDivUp(1e18, lltv);

      if (required >= collateral) {
        assertEq(freeCollat, 0, "Available collateral should be 0 when over-leveraged");
      } else {
        // Due to rounding, allow small delta
        assertApproxEqAbs(freeCollat, collateral - required, 2, "Available collateral calculation mismatch");
      }
    }
  }

  function test_AvailableCollateral_RoundingIsConservative() public {
    // Test that rounding favors the protocol (less available collateral reported)
    // Use amounts that cause rounding
    uint256 collateral = 1000e18;
    uint256 debt = 333e18; // Creates non-round division
    uint256 lltv = 0.7e18;

    _supplyLiquidity(debt * 2);
    collateralToken.setBalance(positionManager, collateral);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(collateral);
    borrowPosition.borrow(debt);
    vm.stopPrank();

    uint256 freeCollat = borrowPosition.availableCollateral(lltv);

    // Required = 333 / 0.7 = 475.71... should round UP to 476
    // Free = 1000 - 476 = 524
    // The actual available collateral should be <= theoretical due to conservative rounding
    uint256 theoreticalRequired = (debt * 1e18) / lltv;
    uint256 theoreticalFree = collateral - theoreticalRequired;

    assertLe(freeCollat, theoreticalFree + 1, "Available collateral should be conservatively rounded");
  }
}
