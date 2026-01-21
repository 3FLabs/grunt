// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "../PositionManagerBase.t.sol";
import {MorphoRebalancer} from "src/manager/rebalancer/MorphoRebalancer.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";

/// @title MorphoRebalancerTest
/// @notice Test suite for MorphoRebalancer contract
contract MorphoRebalancerTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MorphoRebalancer public morphoRebalancer;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public override {
    super.setUp();

    // Deploy MorphoRebalancer (only needs owner and morpho)
    morphoRebalancer = new MorphoRebalancer(owner, address(morpho));

    // Grant rebalancer role to MorphoRebalancer
    vm.prank(owner);
    positionManager.grantRoles(address(morphoRebalancer), _ROLE_REBALANCER);

    // Set max rebalance loss to allow some flexibility
    vm.prank(owner);
    positionManager.setMaxRebalanceLoss(1000); // 10%

    // Label contract
    vm.label(address(morphoRebalancer), "MorphoRebalancer");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONSTRUCTOR TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_constructor_setsMorpho() public view {
    assertEq(address(morphoRebalancer.MORPHO()), address(morpho), "MORPHO should be set");
  }

  function test_constructor_setsOwner() public view {
    assertEq(morphoRebalancer.owner(), owner, "Owner should be set");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REBALANCE TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_moveLiquidityBetweenPositions() public {
    // Setup: deposit collateral and borrow in position 1
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Verify initial state
    assertEq(borrowPosition1.totalCollateral(), COLLATERAL_AMOUNT, "Initial collateral in position 1");
    assertEq(borrowPosition1.totalBorrowed(), DEBT_AMOUNT, "Initial debt in position 1");
    assertEq(borrowPosition2.totalCollateral(), 0, "No collateral in position 2");
    assertEq(borrowPosition2.totalBorrowed(), 0, "No debt in position 2");

    // Prepare rebalancing: move half to position 2
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
      debt: debtToMove, // Used as flash loan amount
      operations: ops
    });

    // Execute rebalance via flash loan
    vm.prank(owner);
    morphoRebalancer.rebalance(positionManager, data, owner);

    // Verify positions were rebalanced
    assertApproxEqRel(borrowPosition1.totalCollateral(), collateralToMove, 0.01e18, "Position 1 collateral");
    assertApproxEqRel(borrowPosition2.totalCollateral(), collateralToMove, 0.01e18, "Position 2 collateral");
    assertApproxEqRel(borrowPosition1.totalBorrowed(), debtToMove, 0.01e18, "Position 1 debt");
    assertApproxEqRel(borrowPosition2.totalBorrowed(), debtToMove, 0.01e18, "Position 2 debt");
  }

  function test_rebalance_emitsEvent() public {
    // Setup
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    uint256 debtToMove = DEBT_AMOUNT / 2;

    RebalancingOperation[] memory ops = new RebalancingOperation[](4);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: debtToMove
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1),
      operationType: RebalancingOperationType.WITHDRAW,
      amount: COLLATERAL_AMOUNT / 2
    });
    ops[2] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.SUPPLY, amount: COLLATERAL_AMOUNT / 2
    });
    ops[3] = RebalancingOperation({
      position: address(borrowPosition2), operationType: RebalancingOperationType.BORROW, amount: debtToMove
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: debtToMove, operations: ops});

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit MorphoRebalancer.Rebalanced(address(positionManager), debtToMove, 0);
    morphoRebalancer.rebalance(positionManager, data, owner);
  }

  function test_rebalance_returnsZeroExcessWhenFullyUsed() public {
    // Setup: deposit collateral and borrow
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, DEBT_AMOUNT);

    // Repay and reborrow same amount - no excess since borrowed amount repays flash loan
    uint256 debtAmount = DEBT_AMOUNT / 4;

    RebalancingOperation[] memory ops = new RebalancingOperation[](2);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: debtAmount
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.BORROW, amount: debtAmount
    });

    RebalancingData memory data = RebalancingData({collateral: 0, debt: debtAmount, operations: ops});

    uint256 ownerDebtBefore = debtToken.balanceOf(owner);

    vm.prank(owner);
    morphoRebalancer.rebalance(positionManager, data, owner);

    // No excess since borrowed amount exactly covers flash loan repayment
    assertEq(debtToken.balanceOf(owner), ownerDebtBefore, "Owner balance unchanged");
  }

  function test_rebalance_revertCollateralNotAllowed() public {
    RebalancingOperation[] memory ops = new RebalancingOperation[](0);
    RebalancingData memory data = RebalancingData({
      collateral: 100e18, // Non-zero collateral should revert
      debt: 1000e18,
      operations: ops
    });

    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.CollateralNotAllowed.selector);
    morphoRebalancer.rebalance(positionManager, data, owner);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ACCESS CONTROL TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_onlyOwner() public {
    RebalancingOperation[] memory ops = new RebalancingOperation[](0);
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 1000e18, operations: ops});

    vm.prank(user);
    vm.expectRevert();
    morphoRebalancer.rebalance(positionManager, data, owner);
  }

  function test_rescue_onlyOwner() public {
    _mintCollateral(address(morphoRebalancer), 100e18);

    vm.prank(user);
    vm.expectRevert();
    morphoRebalancer.rescue(address(collateralToken), user);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                CALLBACK SECURITY TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_onMorphoFlashLoan_revertUnauthorizedCaller() public {
    // Try to call callback directly (not from Morpho)
    RebalancingOperation[] memory ops = new RebalancingOperation[](0);
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    bytes memory callbackData = abi.encode(positionManager, data, owner);

    vm.prank(user);
    vm.expectRevert(LibManagerErrors.UnauthorizedCaller.selector);
    morphoRebalancer.onMorphoFlashLoan(1000e18, callbackData);
  }

  function test_onMorphoFlashLoan_canBeCalledByMorpho() public {
    // Setup: deposit collateral so PM has a position
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // Give rebalancer debt tokens
    _mintDebt(address(morphoRebalancer), 1000e18);

    RebalancingOperation[] memory ops = new RebalancingOperation[](0);
    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    bytes memory callbackData = abi.encode(positionManager, data, owner);

    // This simulates Morpho calling the callback
    vm.prank(address(morpho));
    morphoRebalancer.onMorphoFlashLoan(1000e18, callbackData);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      RESCUE TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rescue_collateralToken() public {
    uint256 amount = 100e18;
    _mintCollateral(address(morphoRebalancer), amount);

    uint256 ownerBalanceBefore = collateralToken.balanceOf(owner);

    vm.prank(owner);
    uint256 rescued = morphoRebalancer.rescue(address(collateralToken), owner);

    assertEq(rescued, amount, "Should return rescued amount");
    assertEq(collateralToken.balanceOf(owner), ownerBalanceBefore + amount, "Owner should receive tokens");
    assertEq(collateralToken.balanceOf(address(morphoRebalancer)), 0, "Rebalancer should have 0 balance");
  }

  function test_rescue_debtToken() public {
    uint256 amount = 100e18;
    _mintDebt(address(morphoRebalancer), amount);

    uint256 ownerBalanceBefore = debtToken.balanceOf(owner);

    vm.prank(owner);
    uint256 rescued = morphoRebalancer.rescue(address(debtToken), owner);

    assertEq(rescued, amount, "Should return rescued amount");
    assertEq(debtToken.balanceOf(owner), ownerBalanceBefore + amount, "Owner should receive tokens");
    assertEq(debtToken.balanceOf(address(morphoRebalancer)), 0, "Rebalancer should have 0 balance");
  }

  function test_rescue_toArbitraryAddress() public {
    uint256 amount = 100e18;
    _mintCollateral(address(morphoRebalancer), amount);

    address recipient = makeAddr("recipient");
    uint256 recipientBalanceBefore = collateralToken.balanceOf(recipient);

    vm.prank(owner);
    uint256 rescued = morphoRebalancer.rescue(address(collateralToken), recipient);

    assertEq(rescued, amount, "Should return rescued amount");
    assertEq(collateralToken.balanceOf(recipient), recipientBalanceBefore + amount, "Recipient should receive tokens");
  }

  function test_rescue_zeroBalance() public {
    uint256 ownerBalanceBefore = collateralToken.balanceOf(owner);

    vm.prank(owner);
    uint256 rescued = morphoRebalancer.rescue(address(collateralToken), owner);

    assertEq(rescued, 0, "Should return 0 when no balance");
    assertEq(collateralToken.balanceOf(owner), ownerBalanceBefore, "Owner balance unchanged");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FUZZ TESTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_rebalance_variableAmounts(uint256 collateralAmount, uint256 debtAmount) public {
    // Bound to reasonable values
    collateralAmount = bound(collateralAmount, 10e18, 100_000e18);
    debtAmount = bound(debtAmount, 1e18, collateralAmount / 2); // Keep healthy LTV

    // Setup
    _mintCollateral(minter, collateralAmount);
    vm.prank(minter);
    positionManager.deposit(collateralAmount, debtAmount);

    // Move quarter of everything to position 2
    uint256 collateralToMove = collateralAmount / 4;
    uint256 debtToMove = debtAmount / 4;

    if (debtToMove == 0) return; // Skip if debt too small

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

    vm.prank(owner);
    morphoRebalancer.rebalance(positionManager, data, owner);

    // Verify total assets roughly unchanged
    uint256 totalCollateral = borrowPosition1.totalCollateral() + borrowPosition2.totalCollateral();
    assertApproxEqRel(totalCollateral, collateralAmount, 0.01e18, "Total collateral should be preserved");
  }
}
