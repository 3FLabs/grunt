// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";

/// @title PositionManagerInitTest
/// @notice Tests for PositionManager initialization and view functions
contract PositionManagerInitTest is PositionManagerBaseTest {
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
  /*                   VIEW FUNCTION TESTS                      */
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
}
