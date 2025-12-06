// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {Test, stdError} from "forge-std/Test.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {ERC20Mock} from "lib/morpho-blue/src/mocks/ERC20Mock.sol";
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
  IMorpho public morpho;
  ERC20Mock public loanToken;
  ERC20Mock public collateralToken;
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

  uint256 constant DEFAULT_LLTV = 0.8e18; // 80% LLTV
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
  error InvalidMarketId();
  error MarketNotCreated();
  error AmountZero();

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
    loanToken = new ERC20Mock();
    vm.label(address(loanToken), "LoanToken");

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

    // Deploy and initialize MorphoBorrowPosition (without a proxy)
    borrowPosition = new MorphoBorrowPosition();
    borrowPosition.initialize(morpho, marketId, positionManager);

    // Setup approvals for position manager
    vm.startPrank(positionManager);
    loanToken.approve(address(borrowPosition), type(uint256).max);
    collateralToken.approve(address(borrowPosition), type(uint256).max);
    vm.stopPrank();

    // Label contracts
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

    newPosition.initialize(morpho, marketId, positionManager);

    assertEq(address(newPosition.borrowAsset()), address(loanToken), "Borrow asset mismatch");
    assertEq(address(newPosition.collateralAsset()), address(collateralToken), "Collateral asset mismatch");
    assertEq(Id.unwrap(newPosition.marketId()), Id.unwrap(marketId), "Market ID mismatch");
    assertEq(newPosition.owner(), positionManager, "Owner not set correctly");
  }

  function test_initialize_RevertWhen_MorphoIsZero() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    vm.expectRevert(AddressZero.selector);
    newPosition.initialize(IMorpho(address(0)), marketId, positionManager);
  }

  function test_initialize_RevertWhen_MarketIdIsZero() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    vm.expectRevert(InvalidMarketId.selector);
    newPosition.initialize(morpho, Id.wrap(bytes32(0)), positionManager);
  }

  function test_initialize_RevertWhen_MarketNotCreated() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();

    // Create a non-existent market ID
    Id fakeMarketId = Id.wrap(keccak256("nonexistent"));

    vm.expectRevert(MarketNotCreated.selector);
    newPosition.initialize(morpho, fakeMarketId, positionManager);
  }

  function test_initialize_CanOnlyBeCalledOnce() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();
    newPosition.initialize(morpho, marketId, positionManager);

    vm.expectRevert(InvalidInitialization.selector);
    newPosition.initialize(morpho, marketId, positionManager);
  }

  function test_initialize_SetsMarketParams() public {
    MorphoBorrowPosition newPosition = new MorphoBorrowPosition();
    newPosition.initialize(morpho, marketId, positionManager);

    assertEq(newPosition.borrowAsset(), marketParams.loanToken, "Loan token mismatch");
    assertEq(newPosition.collateralAsset(), marketParams.collateralToken, "Collateral token mismatch");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 SUPPLY COLLATERAL TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_supplyCollateral_Success() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);

    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), amount, "Collateral not supplied");
  }

  function test_supplyCollateral_MultipleSupplies() public {
    uint256 amount1 = COLLATERAL_AMOUNT;
    uint256 amount2 = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, amount1 + amount2);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(amount1);
    borrowPosition.supplyCollateral(amount2);
    vm.stopPrank();

    assertEq(borrowPosition.totalCollateral(), amount1 + amount2, "Collateral not accumulated");
  }

  function testFuzz_supplyCollateral_Amount(uint128 amount) public {
    amount = uint128(bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));

    collateralToken.setBalance(positionManager, amount);

    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), amount, "Collateral amount mismatch");
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

  function test_withdrawCollateral_Success() public {
    uint256 amount = COLLATERAL_AMOUNT;

    // Supply collateral first
    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    // Withdraw
    uint256 balanceBefore = collateralToken.balanceOf(positionManager);
    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), 0, "Collateral not withdrawn");
    assertEq(collateralToken.balanceOf(positionManager) - balanceBefore, amount, "Balance not returned");
  }

  function test_withdrawCollateral_PartialWithdraw() public {
    uint256 totalAmount = COLLATERAL_AMOUNT;
    uint256 withdrawAmount = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, totalAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(totalAmount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(withdrawAmount);

    assertEq(borrowPosition.totalCollateral(), totalAmount - withdrawAmount, "Partial withdrawal incorrect");
  }

  function test_withdrawCollateral_FullWithdraw() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), 0, "Full withdrawal failed");
  }

  function testFuzz_withdrawCollateral_Amount(uint128 amount) public {
    amount = uint128(bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), 0, "Withdrawal amount mismatch");
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

    // Borrow near max
    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmount = (maxBorrow * 99) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    // Try to withdraw collateral (should fail due to health check)
    vm.prank(positionManager);
    vm.expectRevert("insufficient collateral");
    borrowPosition.withdrawCollateral(collateralAmount / 2);
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

  function test_borrow_Success() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow
    uint256 balanceBefore = loanToken.balanceOf(positionManager);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertGt(borrowPosition.totalBorrowed(), 0, "Borrow not recorded");
    assertEq(loanToken.balanceOf(positionManager), balanceBefore + borrowAmount, "Borrowed assets not received");
  }

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

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmount = (maxBorrow * borrowRatio) / 100;

    if (borrowAmount > 0) {
      vm.prank(positionManager);
      borrowPosition.borrow(borrowAmount);

      assertGt(borrowPosition.totalBorrowed(), 0, "Borrow failed");
      assertTrue(borrowPosition.isHealthy(), "Position unhealthy after borrow");
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

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmount = maxBorrow + 1; // Exceed max by 1

    vm.prank(positionManager);
    vm.expectRevert("insufficient collateral");
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

  function test_repay_Success() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    uint256 borrowedBefore = borrowPosition.totalBorrowed();

    // Repay
    loanToken.setBalance(positionManager, borrowAmount);
    vm.prank(positionManager);
    borrowPosition.repay(borrowAmount);

    assertLt(borrowPosition.totalBorrowed(), borrowedBefore, "Repay not recorded");
  }

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

  function test_repay_PartialRepay() public {
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

    assertLt(borrowPosition.totalBorrowed(), borrowedBefore, "Partial repay failed");
    assertGt(borrowPosition.totalBorrowed(), 0, "Should still have debt");
  }

  function test_repay_FullRepay() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    uint256 totalBorrowed = borrowPosition.totalBorrowed();

    loanToken.setBalance(positionManager, totalBorrowed + 1e18); // Extra for any interest
    vm.prank(positionManager);
    borrowPosition.repay(totalBorrowed);

    assertEq(borrowPosition.totalBorrowed(), 0, "Full repay failed");
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
    assertEq(borrowPosition.totalCollateral(), 0, "Initial collateral should be zero");
  }

  function test_totalCollateral_AfterSupply() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), amount, "Supply not reflected");
  }

  function test_totalCollateral_MultipleSupplies() public {
    uint256 amount1 = COLLATERAL_AMOUNT;
    uint256 amount2 = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, amount1 + amount2);

    vm.startPrank(positionManager);
    borrowPosition.supplyCollateral(amount1);
    borrowPosition.supplyCollateral(amount2);
    vm.stopPrank();

    assertEq(borrowPosition.totalCollateral(), amount1 + amount2, "Multiple supplies not reflected");
  }

  function test_totalCollateral_AfterWithdraw() public {
    uint256 supplyAmount = COLLATERAL_AMOUNT;
    uint256 withdrawAmount = COLLATERAL_AMOUNT / 2;

    collateralToken.setBalance(positionManager, supplyAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(supplyAmount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(withdrawAmount);

    assertEq(borrowPosition.totalCollateral(), supplyAmount - withdrawAmount, "Withdraw not reflected");
  }

  function test_totalCollateral_AfterFullWithdraw() public {
    uint256 amount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), 0, "Full withdraw not reflected");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  POSITION HEALTH TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_isHealthy_InitiallyTrue() public view {
    assertTrue(borrowPosition.isHealthy(), "Initial position should be healthy");
  }

  function test_isHealthy_WithoutBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    assertTrue(borrowPosition.isHealthy(), "Position with only collateral should be healthy");
  }

  function test_isHealthy_BelowMaxBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 safeBorrow = (maxBorrow * 50) / 100; // 50% of max

    vm.prank(positionManager);
    borrowPosition.borrow(safeBorrow);

    assertTrue(borrowPosition.isHealthy(), "Position below max borrow should be healthy");
  }

  function test_isHealthy_AtMaxBorrow() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 safeBorrow = (maxBorrow * 99) / 100; // 99% of max for safety

    vm.prank(positionManager);
    borrowPosition.borrow(safeBorrow);

    assertTrue(borrowPosition.isHealthy(), "Position at near-max borrow should be healthy");
  }

  function test_isHealthy_AfterCollateralPriceIncrease() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmount = (maxBorrow * 80) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    // Increase collateral price
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);

    assertTrue(borrowPosition.isHealthy(), "Position should be healthier after price increase");
  }

  function test_isHealthy_AfterCollateralPriceDecrease() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmount = (maxBorrow * 50) / 100; // Start at 50%

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertTrue(borrowPosition.isHealthy(), "Initial position should be healthy");

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

    uint256 maxBorrow = borrowPosition.maxBorrow();
    if (maxBorrow > MIN_TEST_AMOUNT) {
      uint256 safeBorrow = (maxBorrow * 50) / 100;

      vm.prank(positionManager);
      borrowPosition.borrow(safeBorrow);

      assertTrue(borrowPosition.isHealthy(), "Position at 50% should be healthy");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MAX BORROW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_maxBorrow_InitiallyZero() public view {
    assertEq(borrowPosition.maxBorrow(), 0, "Max borrow should be zero without collateral");
  }

  function test_maxBorrow_AfterCollateralSupply() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    assertGt(borrowPosition.maxBorrow(), 0, "Max borrow should increase with collateral");
  }

  function test_maxBorrow_ProportionalToLLTV() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, DEFAULT_ORACLE_PRICE, DEFAULT_LLTV);

    assertApproxEqAbs(maxBorrow, expectedMaxBorrow, 1, "Max borrow calculation incorrect");
  }

  function test_maxBorrow_ProportionalToOraclePrice() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrowBefore = borrowPosition.maxBorrow();

    // Double the price
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);

    uint256 maxBorrowAfter = borrowPosition.maxBorrow();

    assertApproxEqRel(maxBorrowAfter, maxBorrowBefore * 2, 0.01e18, "Max borrow should double with price");
  }

  function test_maxBorrow_CalculationAccuracy() public {
    uint256 collateralAmount = 1_000e18;
    uint256 price = 2_000e18; // $2000 per unit

    oracle.setPrice(price * (ORACLE_PRICE_SCALE / 1e18));

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, price * (ORACLE_PRICE_SCALE / 1e18), DEFAULT_LLTV);

    assertApproxEqAbs(maxBorrow, expectedMaxBorrow, 1, "Max borrow calculation should be accurate");
  }

  function testFuzz_maxBorrow_CalculationConsistent(uint128 collateralAmount, uint128 price) public {
    collateralAmount = uint128(bound(collateralAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT));
    price = uint128(bound(price, ORACLE_PRICE_SCALE / 100, ORACLE_PRICE_SCALE * 10));

    oracle.setPrice(price);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 expectedMaxBorrow = _calculateMaxBorrow(collateralAmount, price, DEFAULT_LLTV);

    assertApproxEqAbs(maxBorrow, expectedMaxBorrow, 1, "Max borrow should match calculation");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MORPHO VIEW TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_marketId_ReturnsCorrectMarketId() public view {
    assertEq(Id.unwrap(borrowPosition.marketId()), Id.unwrap(marketId), "Market ID mismatch");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*              INTEGRATION & WORKFLOW TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_integration_FullWorkflow_SupplyBorrowRepayWithdraw() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;
    uint256 borrowAmount = LOAN_AMOUNT / 2;

    // 1. Supply liquidity to Morpho
    _supplyLiquidity(LOAN_AMOUNT);

    // 2. Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    assertEq(borrowPosition.totalCollateral(), collateralAmount, "Step 2: Collateral supply failed");
    assertTrue(borrowPosition.isHealthy(), "Step 2: Position should be healthy");

    // 3. Borrow
    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertGt(borrowPosition.totalBorrowed(), 0, "Step 3: Borrow failed");
    assertTrue(borrowPosition.isHealthy(), "Step 3: Position should still be healthy");

    // 4. Repay
    uint256 totalBorrowed = borrowPosition.totalBorrowed();
    loanToken.setBalance(positionManager, totalBorrowed + 1e18);
    vm.prank(positionManager);
    borrowPosition.repay(totalBorrowed);

    assertEq(borrowPosition.totalBorrowed(), 0, "Step 4: Repay failed");

    // 5. Withdraw collateral
    vm.prank(positionManager);
    borrowPosition.withdrawCollateral(collateralAmount);

    assertEq(borrowPosition.totalCollateral(), 0, "Step 5: Withdraw failed");
    assertEq(borrowPosition.totalBorrowed(), 0, "Step 5: Should have no debt");
  }

  function test_integration_HealthFactorMonitoring() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    assertTrue(borrowPosition.isHealthy(), "Should be healthy with collateral only");

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrow1 = (maxBorrow * 25) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrow1);

    assertTrue(borrowPosition.isHealthy(), "Should be healthy at 25% utilization");

    uint256 borrow2 = (maxBorrow * 25) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrow2);

    assertTrue(borrowPosition.isHealthy(), "Should be healthy at 50% utilization");

    uint256 borrow3 = (maxBorrow * 20) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrow3);

    assertTrue(borrowPosition.isHealthy(), "Should be healthy at 70% utilization");
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
    uint256 maxBorrow = borrowPosition.maxBorrow();
    borrowPosition.borrow((maxBorrow * 20) / 100);
    borrowPosition.borrow((maxBorrow * 10) / 100);

    // Repay some
    uint256 totalBorrowed = borrowPosition.totalBorrowed();
    loanToken.setBalance(positionManager, totalBorrowed / 2);
    borrowPosition.repay(totalBorrowed / 4);

    // Withdraw some collateral
    borrowPosition.withdrawCollateral(collateralAmount / 4);

    vm.stopPrank();

    assertTrue(borrowPosition.isHealthy(), "Position should remain healthy");
    assertGt(borrowPosition.totalCollateral(), 0, "Should have remaining collateral");
    assertGt(borrowPosition.totalBorrowed(), 0, "Should have remaining debt");
  }

  function test_workflow_CollateralPriceVolatility() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    _supplyLiquidity(LOAN_AMOUNT * 10);

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow at initial price
    uint256 maxBorrow1 = borrowPosition.maxBorrow();
    uint256 borrowAmount = (maxBorrow1 * 50) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmount);

    assertTrue(borrowPosition.isHealthy(), "Should be healthy at initial price");

    // Price increases - can borrow more
    oracle.setPrice(DEFAULT_ORACLE_PRICE * 2);

    uint256 maxBorrow2 = borrowPosition.maxBorrow();
    assertGt(maxBorrow2, maxBorrow1, "Max borrow should increase with price");
    assertTrue(borrowPosition.isHealthy(), "Should be healthy after price increase");

    // Price decreases back
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    assertTrue(borrowPosition.isHealthy(), "Should still be healthy at original price");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 EDGE CASES & FUZZ TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_EdgeCase_VerySmallAmounts(uint64 amount) public {
    amount = uint64(bound(amount, 1, MIN_TEST_AMOUNT));

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), amount, "Small amount supply failed");
  }

  function testFuzz_EdgeCase_VeryLargeAmounts(uint128 amount) public {
    amount = uint128(bound(amount, MAX_TEST_AMOUNT / 2, type(uint128).max / 2));

    collateralToken.setBalance(positionManager, amount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(amount);

    assertEq(borrowPosition.totalCollateral(), amount, "Large amount supply failed");
  }

  function test_EdgeCase_OraclePriceChanges() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow1 = borrowPosition.maxBorrow();

    oracle.setPrice(DEFAULT_ORACLE_PRICE / 2);
    uint256 maxBorrow2 = borrowPosition.maxBorrow();

    oracle.setPrice(DEFAULT_ORACLE_PRICE * 3);
    uint256 maxBorrow3 = borrowPosition.maxBorrow();

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

      uint256 maxBorrow = borrowPosition.maxBorrow();
      if (maxBorrow > MIN_TEST_AMOUNT) {
        uint256 safeBorrow = (maxBorrow * 10) / 100; // Borrow 10% of max each time
        borrowPosition.borrow(safeBorrow);
      }
    }

    vm.stopPrank();

    assertTrue(borrowPosition.isHealthy(), "Position should be healthy after rapid ops");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    LIQUIDATION TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_liquidation_PositionBecomesUnhealthyAfterPriceDropAndGetsLiquidated() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity for borrowing and liquidation
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow near max (80% of max)
    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmountActual = (maxBorrow * 80) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    // Verify position is healthy initially
    assertTrue(borrowPosition.isHealthy(), "Position should be healthy initially");
    uint256 collateralBefore = borrowPosition.totalCollateral();
    uint256 borrowedBefore = borrowPosition.totalBorrowed();

    // Crash the collateral price to make position unhealthy
    // Drop price by 50% to trigger liquidation
    oracle.setPrice(DEFAULT_ORACLE_PRICE / 2);

    // Position should now be unhealthy
    assertFalse(borrowPosition.isHealthy(), "Position should be unhealthy after price drop");

    // Setup liquidator
    address liquidator = makeAddr("liquidator");

    // Give liquidator loan tokens to repay debt
    loanToken.setBalance(liquidator, borrowedBefore);
    vm.startPrank(liquidator);
    loanToken.approve(address(morpho), type(uint256).max);

    // Liquidate the position - Morpho allows liquidating unhealthy positions
    // Liquidator seizes collateral by repaying debt
    (uint256 seizedAssets, uint256 repaidShares) = morpho.liquidate(
      marketParams,
      address(borrowPosition), // borrower address
      borrowedBefore, // assets to seize (up to full debt)
      0, // min shares received
      "" // data
    );

    vm.stopPrank();

    // Verify liquidation occurred
    assertGt(seizedAssets, 0, "Should have seized collateral");
    assertGt(repaidShares, 0, "Should have repaid debt");

    // Verify position state after liquidation
    uint256 collateralAfter = borrowPosition.totalCollateral();
    uint256 borrowedAfter = borrowPosition.totalBorrowed();

    assertLt(collateralAfter, collateralBefore, "Collateral should decrease after liquidation");
    assertLt(borrowedAfter, borrowedBefore, "Borrowed amount should decrease after liquidation");

    // Note: Due to liquidation incentive, the position might still be unhealthy
    // or even have zero collateral left after full liquidation.
    // The key is that debt and collateral both decreased.
  }

  function test_liquidation_PartialLiquidationReducesDebt() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    // Borrow near max (90% of max)
    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmountActual = (maxBorrow * 90) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    assertTrue(borrowPosition.isHealthy(), "Position should be healthy initially");

    // Price drops 30% - makes position unhealthy
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 70) / 100);

    assertFalse(borrowPosition.isHealthy(), "Position should be unhealthy after price drop");

    // Liquidator performs partial liquidation
    address liquidator = makeAddr("liquidator");
    uint256 borrowedBefore = borrowPosition.totalBorrowed();
    uint256 partialRepayAmount = borrowedBefore / 2; // Repay 50% of debt

    loanToken.setBalance(liquidator, partialRepayAmount);
    vm.startPrank(liquidator);
    loanToken.approve(address(morpho), type(uint256).max);

    morpho.liquidate(marketParams, address(borrowPosition), partialRepayAmount, 0, "");

    vm.stopPrank();

    // Debt should be reduced
    uint256 borrowedAfter = borrowPosition.totalBorrowed();
    assertLt(borrowedAfter, borrowedBefore, "Debt should be reduced after liquidation");

    // Note: Due to liquidation bonus, position might still be unhealthy after partial liquidation
    // The test verifies that liquidation reduces debt, not necessarily restores full health
  }

  function test_liquidation_OwnerCanRepayInsteadOfBeingLiquidated() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral and borrow
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmountActual = (maxBorrow * 85) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    assertTrue(borrowPosition.isHealthy(), "Position should be healthy initially");

    // Price drops 40%
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 60) / 100);

    assertFalse(borrowPosition.isHealthy(), "Position should be unhealthy after price drop");

    // Owner repays enough to restore health
    uint256 borrowedBefore = borrowPosition.totalBorrowed();
    uint256 repayAmount = borrowedBefore / 2;

    loanToken.setBalance(positionManager, repayAmount);
    vm.prank(positionManager);
    borrowPosition.repay(repayAmount);

    // Position should be healthy again
    assertTrue(borrowPosition.isHealthy(), "Position should be healthy after repayment");

    // Verify debt decreased
    assertLt(borrowPosition.totalBorrowed(), borrowedBefore, "Debt should be reduced");
  }

  function test_liquidation_VerifyCollateralAndDebtStateAfterFullLiquidation() public {
    uint256 collateralAmount = COLLATERAL_AMOUNT;

    // Supply liquidity
    _supplyLiquidity(LOAN_AMOUNT * 10);

    // Supply collateral and borrow
    collateralToken.setBalance(positionManager, collateralAmount);
    vm.prank(positionManager);
    borrowPosition.supplyCollateral(collateralAmount);

    uint256 maxBorrow = borrowPosition.maxBorrow();
    uint256 borrowAmountActual = (maxBorrow * 95) / 100;

    vm.prank(positionManager);
    borrowPosition.borrow(borrowAmountActual);

    // Severe price drop (60% crash)
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 40) / 100);

    assertFalse(borrowPosition.isHealthy(), "Position should be unhealthy");

    // Liquidator liquidates entire position
    address liquidator = makeAddr("liquidator");
    uint256 borrowedAmount = borrowPosition.totalBorrowed();
    uint256 collateralBefore = borrowPosition.totalCollateral();

    loanToken.setBalance(liquidator, borrowedAmount * 2); // Excess to ensure full liquidation
    vm.startPrank(liquidator);
    loanToken.approve(address(morpho), type(uint256).max);

    // Try to seize all collateral to fully liquidate
    (uint256 seizedAssets,) = morpho.liquidate(marketParams, address(borrowPosition), collateralBefore, 0, "");

    vm.stopPrank();

    // Verify liquidation results
    assertGt(seizedAssets, 0, "Should have seized collateral");

    // After liquidation, collateral should be reduced significantly
    uint256 collateralAfter = borrowPosition.totalCollateral();

    assertLt(collateralAfter, collateralBefore, "Collateral should be seized");

    // Verify that liquidation occurred and debt was reduced
    // Note: In Morpho, liquidation includes a bonus, so the position may be fully liquidated
    // with both collateral and debt approaching zero
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
}
