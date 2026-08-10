// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {RetargetterBaseTest} from "./RetargetterBase.t.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {RebalancingOperationType} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {ITokenController} from "src/interfaces/request/ITokenController.sol";
import {IRequest} from "src/interfaces/request/IRequest.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {OPERATION_STORAGE_SLOT} from "src/libs/manager/rebalancer/LibRetargetterConstants.sol";

contract RetargetterSmokeTest is RetargetterBaseTest {
  function test_smoke_asyncUpHappyPath() public {
    // LTV 0.5 with target 0.7: below target, LTV-up operation
    _seedPosition(10_000e18, 5_000e18);
    // The gate sizes the cap on the operation's own 1% yield cap
    uint256 cap = _gateCap(100);
    assertGt(cap, 6_000e18, "cap sanity");

    address request = _startAsync(6_000e18, 100);
    assertTrue(retargetter.isActive(), "active");

    // Consume a 1% offer and pull the funds
    _consume(request, 6_000e18, 60e18, 6_000e18);
    vm.prank(rebalancer);
    retargetter.pullRequestFunds(6_000e18);
    assertEq(debtToken.balanceOf(address(retargetter)), 6_000e18, "pulled");

    // Subscribe into the fund (asynchronous settlement)
    vm.startPrank(rebalancer);
    retargetter.create(_order(Mode.DEPOSIT, 6_000e18, 6_000e18, bytes32(uint256(1))));
    retargetter.commit();
    vm.stopPrank();

    vm.warp(block.timestamp + 2 days);
    fund.settle();

    vm.startPrank(rebalancer);
    uint256 shares = retargetter.unlock();
    assertEq(shares, 6_000e18, "shares out");

    // Tail: supply everything, borrow the owed amount, repay and resolve in one transaction
    uint256 owedAmount = retargetter.owed();
    retargetter.rebalance(
      _rebalancingData2(
        MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL, RebalancingOperationType.BORROW, owedAmount
      )
    );
    retargetter.repay();
    retargetter.resolve();
    vm.stopPrank();

    assertFalse(retargetter.isActive(), "resolved");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "zero debt residual");
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "zero collateral residual");
    assertTrue(IRequest(request).isRepaid(), "request repaid");
    // 2 ticks owed for 2 days elapsed (tick 1 day, threshold 10 hours; promotion to 3 at 2d10h)
    (uint128 pt,) = ITokenController(request).totalSupplies();
    assertEq(uint256(pt), 6_000e18, "pt supply");
    assertLe(_currentLtv(), POSITION_MANAGER_LTV, "at or below target");
  }

  function test_smoke_syncUpHappyPath() public {
    _seedPosition(10_000e18, 5_000e18);
    fund.setSyncSettlement(true);

    uint256 amount = 6_000e18;
    bytes[] memory calls = new bytes[](4);
    calls[0] = abi.encodeCall(retargetter.create, (_order(Mode.DEPOSIT, amount, amount, bytes32(uint256(2)))));
    calls[1] = abi.encodeCall(retargetter.commit, ());
    calls[2] = abi.encodeCall(retargetter.unlock, ());
    calls[3] = abi.encodeCall(
      retargetter.rebalance,
      (_rebalancingData2(
          MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL, RebalancingOperationType.BORROW, amount
        ))
    );

    vm.prank(rebalancer);
    retargetter.startSyncRetargetting(address(flashLoanAdapter), amount, address(fund), calls);

    assertFalse(retargetter.isActive(), "no persistent operation");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "zero debt residual");
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "zero collateral residual");
    assertApproxEqAbs(_currentLtv(), 6875e14, 1e14, "post LTV (11000/16000)");
  }

  /// @dev Plants a stray live order directly in storage. The orderLive flag sits alone at bit
  ///      0 of the operation namespace's third slot (the fund address and the order mode moved
  ///      into the second slot); no reachable flow leaves it set without an active operation,
  ///      so the defensive OrderActive guards at both start entry points need this exercised.
  function _plantStrayOrder() internal {
    bytes32 slot = bytes32(uint256(OPERATION_STORAGE_SLOT) + 2);
    vm.store(address(retargetter), slot, bytes32(uint256(1)));
  }

  function test_startRetargetting_revertsOrderActiveOnStrayOrder() public {
    _seedPosition(10_000e18, 5_000e18);
    _plantStrayOrder();
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OrderActive.selector);
    retargetter.startRetargetting(1e18, 100, address(fund), REQUEST_NAME, REQUEST_SYMBOL);
  }

  function test_startSyncRetargetting_revertsOrderActiveOnStrayOrder() public {
    _seedPosition(10_000e18, 5_000e18);
    _plantStrayOrder();
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.OrderActive.selector);
    retargetter.startSyncRetargetting(address(flashLoanAdapter), 1e18, address(fund), new bytes[](0));
  }

  function test_repay_zeroShortfallWhenRequestBalanceCovers() public {
    _seedPosition(10_000e18, 5_000e18);
    address request = _startAsync(6_000e18, 100);
    _consume(request, 6_000e18, 60e18, 6_000e18);

    // A donation covering the owed amount means repay transfers nothing
    uint256 owedAmount = retargetter.owed();
    _mintDebt(address(this), owedAmount);
    debtToken.transfer(request, owedAmount);

    uint256 balanceBefore = debtToken.balanceOf(address(retargetter));
    vm.prank(rebalancer);
    uint256 repaid = retargetter.repay();
    assertEq(repaid, owedAmount, "owed");
    assertEq(debtToken.balanceOf(address(retargetter)), balanceBefore, "no transfer on zero shortfall");
    assertTrue(IRequest(request).isRepaid(), "repaid");
  }

  function test_resolve_revertsNoActiveOperationWhenIdle() public {
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.resolve();
  }

  function test_repay_revertsNoActiveOperationWhenIdle() public {
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.repay();
  }
}
