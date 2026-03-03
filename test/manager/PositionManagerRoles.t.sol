// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {LibManagerErrors} from "../../src/libs/manager/LibManagerErrors.sol";
import {LibBorrowErrors} from "../../src/libs/borrow/LibBorrowErrors.sol";
import {LibCommonErrors as CommonErrors} from "../../src/libs/common/LibCommonErrors.sol";
import {MockBorrowPosition} from "test/mock/borrow/MockBorrowPosition.sol";
import {MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title PositionManagerRolesTest
/// @notice Tests for PositionManager admin functions and role-based access control
contract PositionManagerRolesTest is PositionManagerBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ADMIN FUNCTION TESTS                     */
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

  function test_setLtv_onlyOwner() public {
    uint256 newLtv = 0.6e18;

    vm.prank(user);
    vm.expectRevert();
    positionManager.setLtv(newLtv);

    vm.prank(owner);
    positionManager.setLtv(newLtv);

    assertEq(_ltv(), newLtv);
  }

  function test_setLtv_revertOnZero() public {
    vm.prank(owner);
    vm.expectRevert(CommonErrors.InvalidLtv.selector);
    positionManager.setLtv(0);
  }

  function test_setLtv_revertOnGreaterThanWad() public {
    vm.prank(owner);
    // With borrow modules present, the safeLtv check fires first; without modules, InvalidLtv fires via setLtv
    vm.expectRevert(LibManagerErrors.ModuleSafeLtvTooLow.selector);
    positionManager.setLtv(1e18 + 1);
  }

  function test_setLtv_allowsMaxWad() public {
    // First remove all borrow modules so no safeLtv constraint
    // Clear queues first
    vm.prank(curator);
    positionManager.setSupplyQueue(new SupplyQueueEntry[](0));
    vm.prank(curator);
    positionManager.setWithdrawalQueue(new address[](0));

    vm.startPrank(owner);
    positionManager.removeBorrowModule(address(borrowPosition1));
    positionManager.removeBorrowModule(address(borrowPosition2));
    positionManager.setLtv(1e18);
    vm.stopPrank();

    assertEq(_ltv(), 1e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  BORROW MODULE WHITELIST TESTS             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_addBorrowModule_onlyOwner() public {
    // Create a valid borrow module for the success case
    address newModule = borrowPositionFactory.createBorrowPosition(
      morpho, marketId1, address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );

    vm.prank(user);
    vm.expectRevert();
    positionManager.addBorrowModule(newModule);

    vm.prank(owner);
    positionManager.addBorrowModule(newModule);

    assertTrue(positionManager.isBorrowModule(newModule));
  }

  function test_addBorrowModule_revertWhen_CollateralAssetMismatch() public {
    // Create a module with wrong collateral asset
    MockERC20 wrongCollateral = new MockERC20("Wrong", "WRG", 18);

    // Create a Morpho market with wrong collateral
    MarketParams memory wrongParams = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(wrongCollateral),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    vm.prank(owner);
    morpho.createMarket(wrongParams);

    // Asset check now fires during initialize() in createBorrowPosition
    vm.expectRevert(
      abi.encodeWithSelector(LibBorrowErrors.AssetMismatch.selector, address(collateralToken), address(wrongCollateral))
    );
    borrowPositionFactory.createBorrowPosition(
      morpho, MarketParamsLib.id(wrongParams), address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
  }

  function test_addBorrowModule_revertWhen_DebtAssetMismatch() public {
    // Create a module with wrong debt asset
    MockERC20 wrongDebt = new MockERC20("Wrong", "WRG", 18);

    // Create a Morpho market with wrong debt
    MarketParams memory wrongParams = MarketParams({
      loanToken: address(wrongDebt),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    vm.prank(owner);
    morpho.createMarket(wrongParams);

    // Asset check now fires during initialize() in createBorrowPosition
    vm.expectRevert(
      abi.encodeWithSelector(LibBorrowErrors.AssetMismatch.selector, address(debtToken), address(wrongDebt))
    );
    borrowPositionFactory.createBorrowPosition(
      morpho, MarketParamsLib.id(wrongParams), address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
  }

  function test_addBorrowModule_revertWhen_InvalidOwner() public {
    // Create a second PositionManager with the same assets so initialize() passes
    PositionManager otherPM = PositionManager(LibClone.clone(address(new PositionManager())));
    otherPM.initialize(
      owner,
      PositionManagerMetadata({
        name: "Other PM", symbol: "OPM", collateralAsset: address(collateralToken), debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LTV,
      address(0),
      0,
      0
    );

    // Create a module owned by the other PM
    address wrongModule =
      borrowPositionFactory.createBorrowPosition(morpho, marketId1, address(otherPM), BP_SAFE_LTV, BP_LIQUIDATION_LTV);

    // Adding to the first PM fails because the module's owner is otherPM
    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.InvalidModuleOwner.selector);
    positionManager.addBorrowModule(wrongModule);
  }

  function test_addBorrowModule_revertWhen_ModuleAlreadyAdded() public {
    // borrowPosition1 is already whitelisted in setUp
    assertTrue(positionManager.isBorrowModule(address(borrowPosition1)));

    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.ModuleAlreadyAdded.selector);
    positionManager.addBorrowModule(address(borrowPosition1));
  }

  function test_addBorrowModule_revertWhen_SafeLtvTooLow() public {
    // Create a module with safeLtv < PM LTV
    uint128 lowSafeLtv = uint128(POSITION_MANAGER_LTV) - 1;
    uint128 liquidationLtv = uint128(POSITION_MANAGER_LTV) + 0.01e18;
    address wrongModule = borrowPositionFactory.createBorrowPosition(
      morpho, marketId1, address(positionManager), lowSafeLtv, liquidationLtv
    );

    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.ModuleSafeLtvTooLow.selector);
    positionManager.addBorrowModule(wrongModule);
  }

  function test_setLtv_revertWhen_ExceedsModuleSafeLtv() public {
    // Current BP_SAFE_LTV = 0.72e18, try to set PM LTV above it
    uint256 tooHighLtv = uint256(BP_SAFE_LTV) + 1;

    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.ModuleSafeLtvTooLow.selector);
    positionManager.setLtv(tooHighLtv);
  }

  function test_setLtv_succeedsWhenEqualToModuleSafeLtv() public {
    vm.prank(owner);
    positionManager.setLtv(uint256(BP_SAFE_LTV));

    assertEq(_ltv(), uint256(BP_SAFE_LTV));
  }

  function test_removeBorrowModule_onlyOwner() public {
    // borrowPosition1 is already whitelisted
    assertTrue(positionManager.isBorrowModule(address(borrowPosition1)));

    // First, clear the queues to remove borrowPosition1
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(supplyQueue);

    address[] memory withdrawalQueue = new address[](1);
    withdrawalQueue[0] = address(borrowPosition2);
    vm.prank(curator);
    positionManager.setWithdrawalQueue(withdrawalQueue);

    // Non-owner cannot remove
    vm.prank(user);
    vm.expectRevert();
    positionManager.removeBorrowModule(address(borrowPosition1));

    // Owner can remove after clearing from queues
    vm.prank(owner);
    positionManager.removeBorrowModule(address(borrowPosition1));

    assertFalse(positionManager.isBorrowModule(address(borrowPosition1)));
    assertEq(borrowPosition1.owner(), owner);
  }

  function test_removeBorrowModule_revertIfInSupplyQueue() public {
    // borrowPosition1 is in supply queue, try to remove it
    assertTrue(positionManager.isBorrowModule(address(borrowPosition1)));

    // Clear only withdrawal queue
    address[] memory withdrawalQueue = new address[](1);
    withdrawalQueue[0] = address(borrowPosition2);
    vm.prank(curator);
    positionManager.setWithdrawalQueue(withdrawalQueue);

    // Should revert because borrowPosition1 is still in supply queue
    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.ModuleStillInQueue.selector);
    positionManager.removeBorrowModule(address(borrowPosition1));
  }

  function test_removeBorrowModule_revertIfInWithdrawalQueue() public {
    // borrowPosition1 is in withdrawal queue, try to remove it
    assertTrue(positionManager.isBorrowModule(address(borrowPosition1)));

    // Clear only supply queue
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(supplyQueue);

    // Should revert because borrowPosition1 is still in withdrawal queue
    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.ModuleStillInQueue.selector);
    positionManager.removeBorrowModule(address(borrowPosition1));
  }

  function test_removeBorrowModule_successAfterClearingQueues() public {
    assertTrue(positionManager.isBorrowModule(address(borrowPosition1)));

    // Clear both queues
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](1);
    supplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});
    vm.prank(curator);
    positionManager.setSupplyQueue(supplyQueue);

    address[] memory withdrawalQueue = new address[](1);
    withdrawalQueue[0] = address(borrowPosition2);
    vm.prank(curator);
    positionManager.setWithdrawalQueue(withdrawalQueue);

    // Now removal should succeed
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
    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.setSupplyQueue(queue);
  }

  function test_setWithdrawalQueue_revertOnUnauthorizedPosition() public {
    address unauthorizedPosition = makeAddr("unauthorized");

    address[] memory queue = new address[](1);
    queue[0] = unauthorizedPosition;

    vm.prank(curator);
    vm.expectRevert(LibManagerErrors.UnauthorizedPosition.selector);
    positionManager.setWithdrawalQueue(queue);
  }

  function test_setSupplyQueue_revertOnDuplicateEntry() public {
    SupplyQueueEntry[] memory queue = new SupplyQueueEntry[](2);
    queue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    queue[1] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: 1000e18});

    vm.prank(curator);
    vm.expectRevert(LibManagerErrors.DuplicateQueueEntry.selector);
    positionManager.setSupplyQueue(queue);
  }

  function test_setWithdrawalQueue_revertOnDuplicateEntry() public {
    address[] memory queue = new address[](2);
    queue[0] = address(borrowPosition1);
    queue[1] = address(borrowPosition1);

    vm.prank(curator);
    vm.expectRevert(LibManagerErrors.DuplicateQueueEntry.selector);
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
    positionManager.rebalance(data, rebalancer);

    // Curator cannot rebalance
    vm.prank(curator);
    vm.expectRevert();
    positionManager.rebalance(data, rebalancer);

    // Random user cannot rebalance
    vm.prank(user);
    vm.expectRevert();
    positionManager.rebalance(data, rebalancer);
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
    positionManager.rebalance(data, rebalancer);

    vm.prank(newRebalancer);
    positionManager.rebalance(data, rebalancer);
  }
}
