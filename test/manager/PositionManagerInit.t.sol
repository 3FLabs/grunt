// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

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
    assertEq(_ltv(), POSITION_MANAGER_LTV);
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
    assertEq(_collateralAsset(), address(collateralToken));
  }

  function test_debtAsset() public view {
    assertEq(_debtAsset(), address(debtToken));
  }

  function test_lastTotalAssets() public {
    // Initially should be 0
    assertEq(_lastTotalAssets(), 0);

    // Deposit
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    // After deposit, lastTotalAssets should be updated
    assertEq(_lastTotalAssets(), COLLATERAL_AMOUNT);
  }

  function test_lastFeeAccrualTimestamp() public {
    uint256 initialTimestamp = _lastFeeAccrualTimestamp();
    assertEq(initialTimestamp, block.timestamp);

    // Advance time
    vm.warp(block.timestamp + 100);

    // Deposit triggers fee accrual
    _mintCollateral(minter, COLLATERAL_AMOUNT);
    vm.prank(minter);
    positionManager.deposit(COLLATERAL_AMOUNT, 0);

    assertEq(_lastFeeAccrualTimestamp(), block.timestamp);
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

  function test_initialize_withRebalanceConfig() public {
    PositionManager pm = new PositionManager();
    pm.initialize(
      owner,
      PositionManagerMetadata({
        name: "PM with Rebalance",
        symbol: "PMR",
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      100, // maxRebalanceLoss = 1%
      300 // rebalanceCooldown = 300s
    );
    (uint16 maxLoss, uint40 cooldown,) = pm.rebalanceConfig();
    assertEq(maxLoss, 100);
    assertEq(cooldown, 300);
  }

  function testFuzz_virtualShareOffset(uint8 decimals_) public {
    MockERC20 token = new MockERC20("TKN", "TKN", decimals_);
    PositionManager pm = new PositionManager();
    pm.initialize(
      owner,
      PositionManagerMetadata({
        name: "PM", symbol: "PM", collateralAsset: address(collateralToken), debtAsset: address(token)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );
    uint256 expectedOffset = decimals_ >= 18 ? 1 : 10 ** (18 - uint256(decimals_));
    assertEq(pm.virtualShareOffset(), expectedOffset);
    assertEq(pm.decimals(), 18);
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
