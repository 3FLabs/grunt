// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerBaseTest} from "./PositionManagerBase.t.sol";
import {
  IPositionManager,
  SupplyQueueEntry,
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/IPositionManager.sol";

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
}
