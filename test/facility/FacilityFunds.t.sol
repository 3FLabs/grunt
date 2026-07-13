// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {IFacilityFunds} from "src/interfaces/facility/base/IFacilityFunds.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title FacilityFundsTest
/// @notice Tests for Facility fund operations (create, cancel, commit, unlock, recover)
contract FacilityFundsTest is FacilityBaseTest {
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SETUP HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates an intent with deposits and fund set
  /// @dev Uses PM share deposits (default intent type)
  function _createIntentWithFund(uint256 depositAmount) internal returns (uint256 intentId) {
    intentId = _createIntentWithDeposits(depositAmount);

    // Set fund for the intent
    vm.prank(facilitator);
    _setFund(intentId, address(mockFund));
  }

  /// @notice Creates an intent with debtToken deposits for testing DEPOSIT mode fund operations
  /// @dev For DEPOSIT mode: facility sends Fund.asset() (debtToken) to fund
  ///      Intent needs debtToken tracked in its balance
  function _createIntentWithFundForDeposit(uint256 depositAmount) internal returns (uint256 intentId) {
    // Create intent with targetPM config (depositAsset = debtToken, targetAsset = PM)
    vm.prank(owner);
    intentId = facility.createIntent(_intentParamsWithTargetPM());

    // Deposit debtToken to the intent
    _mintDebt(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Move to resolving phase
    vm.warp(block.timestamp + 1 days + 1);

    // Set fund for the intent
    vm.prank(facilitator);
    _setFund(intentId, address(mockFund));
  }

  /// @notice Supplies tokens to the mock fund for testing (for unlock/recover output)
  function _supplyFundTokens(uint256 amount) internal {
    // Fund.share() = collateralToken, Fund.asset() = debtToken
    // For DEPOSIT mode: unlock returns collateral (fund's share)
    // For REDEEM mode: unlock returns debt (fund's asset)
    _mintCollateral(address(mockFund), amount);
    _mintDebt(address(mockFund), amount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      GETORDER TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_getOrder_noActiveOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    (Order memory order, bytes32 orderId) = facility.getOrder(intentId);

    // Should return empty order (no active order has been created)
    assertEq(order.owner, address(0), "Owner should be zero for empty order");
    assertEq(order.input, 0, "Input should be 0");
    assertEq(order.output, 0, "Output should be 0");
    // When order.owner is address(0), toId returns bytes32(0)
    assertEq(orderId, bytes32(0), "Order ID should be zero for null order");
  }

  function test_getOrder_withActiveOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    // Create an order
    vm.prank(facilitator);
    Order memory createdOrder = facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    (Order memory order, bytes32 orderId) = facility.getOrder(intentId);

    assertEq(order.input, createdOrder.input, "Input should match");
    assertEq(order.output, createdOrder.output, "Output should match");
    assertTrue(orderId != bytes32(0), "Order ID should be non-zero");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CREATE TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_create_emitsEvent() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    vm.expectEmit(true, false, false, false);
    emit IFacilityFunds.CreatingOrder(intentId, bytes32(0)); // orderId is computed
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);
  }

  function test_create_revertWhenPaused() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);
  }

  function test_create_revertWhenNotFacilitator() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);
  }

  function test_create_revertWhenMissingFund() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);
    // Fund not set

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.MissingFund.selector, intentId));
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);
  }

  function test_create_revertWhenPendingOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    // Create first order
    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    // Try to create second order
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.ActiveOrder.selector, intentId));
    facility.create(intentId, 300e18, 270e18, Mode.DEPOSIT);
  }

  function test_create_revertWhenNotResolving() public {
    uint256 intentId = _createDefaultIntent();

    // Set fund while still in depositing phase
    vm.prank(facilitator);
    _setFund(intentId, address(mockFund));

    // Still in depositing phase - should revert
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);
  }

  /*´:°•:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
  /*                        CREATE RECOVERY TESTS                 */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_create_afterSetFundRecovery() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    (Order memory order, bytes32 orderId) = facility.getOrder(intentId);
    mockFund.setOrderState(orderId, State.ENDED);

    // Rebind fund to recover from stale ended order using fresh deadline to avoid SwapDigestUsed.
    vm.prank(facilitator);
    {
      uint256 deadline = block.timestamp + 2 hours;
      address[] memory signers = new address[](1);
      bytes[] memory signatures = new bytes[](1);
      signers[0] = guardian;
      signatures[0] = _signSetFund(intentId, address(mockFund), deadline, GUARDIAN_PK);
      facility.setFund(intentId, address(mockFund), deadline, signers, signatures);
    }

    // Order can be created again after recovery
    vm.prank(facilitator);
    facility.create(intentId, 300e18, 270e18, Mode.DEPOSIT);

    (Order memory recreatedOrder,) = facility.getOrder(intentId);
    assertEq(recreatedOrder.input, 300e18, "Order should be recreated");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CANCEL TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_cancel_removesOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    // Create order
    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    // Cancel order
    vm.prank(facilitator);
    facility.cancel(intentId);

    // Verify order is removed
    (Order memory order,) = facility.getOrder(intentId);
    assertEq(order.input, 0, "Order should be cleared");
  }

  function test_cancel_revertWhenPaused() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.cancel(intentId);
  }

  function test_cancel_revertWhenNotFacilitator() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.cancel(intentId);
  }

  function test_cancel_revertWhenNoActiveOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NoActiveOrder.selector, intentId));
    facility.cancel(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       COMMIT TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_commit_transfersTokensToFund() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;

    // Create order
    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 450e18, Mode.DEPOSIT);

    // Set commit amount on mock fund
    mockFund.setCommitAmount(orderAmount);

    // Commit - transfers debt token (fund asset) to fund
    vm.prank(facilitator);
    facility.commit(intentId);

    // Commit should transfer tokens to the fund without errors
    // The fund's commit function should have been called successfully
  }

  function test_commit_revertWhenPaused() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.commit(intentId);
  }

  function test_commit_revertWhenNotFacilitator() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.commit(intentId);
  }

  function test_commit_revertWhenNoActiveOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NoActiveOrder.selector, intentId));
    facility.commit(intentId);
  }

  function test_commit_revertWhenAmountMismatch() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;

    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 450e18, Mode.DEPOSIT);

    // Mock fund returns different amount
    mockFund.setCommitAmount(orderAmount - 1);

    vm.prank(facilitator);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.CommitAmountMismatch.selector, intentId, orderAmount, orderAmount - 1)
    );
    facility.commit(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       UNLOCK TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_unlock_receivesOutputTokens() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;
    uint256 outputAmount = 480e18;

    // Create and commit order
    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 450e18, Mode.DEPOSIT);

    mockFund.setCommitAmount(orderAmount);
    vm.prank(facilitator);
    facility.commit(intentId);

    // Setup unlock to return collateral (fund's share for DEPOSIT mode)
    mockFund.setUnlockAmount(outputAmount);
    _supplyFundTokens(outputAmount);

    // Unlock
    vm.prank(facilitator);
    facility.unlock(intentId);

    // Order should be cleared after ENDED state
    (Order memory order,) = facility.getOrder(intentId);
    assertEq(order.input, 0, "Order should be cleared after unlock");
  }

  function test_unlock_doesNotClearOrderIfNotEnded() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;
    uint256 minOut = 450e18;

    vm.prank(facilitator);
    facility.create(intentId, orderAmount, minOut, Mode.DEPOSIT);

    mockFund.setCommitAmount(orderAmount);
    vm.prank(facilitator);
    facility.commit(intentId);

    // Set state to not ended (PROCESSING) - partial unlock scenario
    mockFund.setNextUnlockState(State.PROCESSING);
    // Supply fund with tokens for the unlock (uses order.output if unlockAmount is 0)
    _supplyFundTokens(minOut);
    mockFund.setUnlockAmount(minOut);

    vm.prank(facilitator);
    facility.unlock(intentId);

    // Order should still exist because state is PROCESSING, not ENDED
    (Order memory order,) = facility.getOrder(intentId);
    assertEq(order.input, orderAmount, "Order should still exist");
  }

  function test_unlock_zeroAmountTerminalUnlockEndsOrder() public {
    // Funds may finalize a fully swept partial-unlock order with a zero-amount terminal
    // unlock returning (ENDED, 0) (e.g. a MidasFund redeem whose holdback was confirmed
    // after the last sweep): no tokens move, intent accounting is untouched, and the ENDED
    // return clears the order and fund binding.
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;

    // minAmountOut = 0 so the mock's unlock fallback amount (order.output) is zero.
    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 0, Mode.DEPOSIT);

    mockFund.setCommitAmount(orderAmount);
    vm.prank(facilitator);
    facility.commit(intentId);

    (address[] memory tokensBefore, uint256[] memory amountsBefore) = facility.intentBalances(intentId);
    uint256 facilityShareBalanceBefore = collateralToken.balanceOf(address(facility));

    vm.prank(facilitator);
    facility.unlock(intentId);

    // Zero tokens received and no accounting change.
    assertEq(collateralToken.balanceOf(address(facility)), facilityShareBalanceBefore, "no tokens received");
    (address[] memory tokensAfter, uint256[] memory amountsAfter) = facility.intentBalances(intentId);
    assertEq(tokensAfter.length, tokensBefore.length, "no new tracked token");
    for (uint256 i = 0; i < tokensAfter.length; i++) {
      assertEq(tokensAfter[i], tokensBefore[i], "tracked token unchanged");
      assertEq(amountsAfter[i], amountsBefore[i], "tracked amount unchanged");
    }

    // The ENDED return clears the stored order and the fund binding.
    (Order memory order,) = facility.getOrder(intentId);
    assertEq(order.owner, address(0), "order cleared");
    assertEq(order.input, 0, "order input cleared");
    (, address fund,,) = facility.getIntent(intentId);
    assertEq(fund, address(0), "fund binding cleared");
  }

  function test_unlock_revertWhenPaused() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;

    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 450e18, Mode.DEPOSIT);

    mockFund.setCommitAmount(orderAmount);
    vm.prank(facilitator);
    facility.commit(intentId);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.unlock(intentId);
  }

  function test_unlock_revertWhenNotFacilitator() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.unlock(intentId);
  }

  function test_unlock_revertWhenNoActiveOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NoActiveOrder.selector, intentId));
    facility.unlock(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       RECOVER TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_recover_receivesInputTokensBack() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;

    // Create and commit order
    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 450e18, Mode.DEPOSIT);

    mockFund.setCommitAmount(orderAmount);
    vm.prank(facilitator);
    facility.commit(intentId);

    // Setup recover to return input tokens (debt token for DEPOSIT mode)
    mockFund.setRecoverAmount(orderAmount);
    _mintDebt(address(mockFund), orderAmount);

    // Recover
    vm.prank(facilitator);
    facility.recover(intentId);

    // Order should be cleared after ENDED state
    (Order memory order,) = facility.getOrder(intentId);
    assertEq(order.input, 0, "Order should be cleared after recover");
  }

  function test_recover_doesNotClearOrderIfNotEnded() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;

    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 450e18, Mode.DEPOSIT);

    mockFund.setCommitAmount(orderAmount);
    vm.prank(facilitator);
    facility.commit(intentId);

    // Set state to not ended (PROCESSING)
    mockFund.setNextRecoverState(State.PROCESSING);
    mockFund.setRecoverAmount(0);

    vm.prank(facilitator);
    facility.recover(intentId);

    // Order should still exist
    (Order memory order,) = facility.getOrder(intentId);
    assertEq(order.input, orderAmount, "Order should still exist");
  }

  function test_recover_revertWhenPaused() public {
    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(1000e18);
    uint256 orderAmount = 500e18;

    vm.prank(facilitator);
    facility.create(intentId, orderAmount, 450e18, Mode.DEPOSIT);

    mockFund.setCommitAmount(orderAmount);
    vm.prank(facilitator);
    facility.commit(intentId);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.recover(intentId);
  }

  function test_recover_revertWhenNotFacilitator() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    facility.create(intentId, 500e18, 450e18, Mode.DEPOSIT);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.recover(intentId);
  }

  function test_recover_revertWhenNoActiveOrder() public {
    uint256 intentId = _createIntentWithFund(1000e18);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NoActiveOrder.selector, intentId));
    facility.recover(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_create_validAmounts(uint256 amount, uint256 minOut) public {
    amount = bound(amount, 1, DEFAULT_DEPOSIT_CAP);
    minOut = bound(minOut, 0, amount);

    uint256 intentId = _createIntentWithFund(DEFAULT_DEPOSIT_CAP);

    vm.prank(facilitator);
    Order memory order = facility.create(intentId, amount, minOut, Mode.DEPOSIT);

    assertEq(order.input, amount, "Input should match");
    assertEq(order.output, minOut, "Output should match");
  }

  function testFuzz_create_differentModes(bool isDeposit) public {
    uint256 intentId = _createIntentWithFund(1000e18);
    Mode mode = isDeposit ? Mode.DEPOSIT : Mode.REDEEM;

    vm.prank(facilitator);
    Order memory order = facility.create(intentId, 500e18, 450e18, mode);

    assertEq(uint8(order.mode), uint8(mode), "Mode should match");
  }

  function testFuzz_orderLifecycle(uint256 amount, uint256 minOut, bool shouldRecover) public {
    amount = bound(amount, 1e18, DEFAULT_DEPOSIT_CAP / 2);
    minOut = bound(minOut, 0, amount);

    // Use intent with debtToken deposits for DEPOSIT mode fund operations
    uint256 intentId = _createIntentWithFundForDeposit(DEFAULT_DEPOSIT_CAP);

    // Create
    vm.prank(facilitator);
    Order memory order = facility.create(intentId, amount, minOut, Mode.DEPOSIT);

    (Order memory storedOrder,) = facility.getOrder(intentId);
    assertEq(storedOrder.input, order.input, "Stored order should match");

    // Commit
    mockFund.setCommitAmount(amount);
    vm.prank(facilitator);
    facility.commit(intentId);

    // Either recover or unlock
    if (shouldRecover) {
      mockFund.setRecoverAmount(amount);
      _mintDebt(address(mockFund), amount);
      vm.prank(facilitator);
      facility.recover(intentId);
    } else {
      mockFund.setUnlockAmount(minOut);
      _supplyFundTokens(minOut);
      vm.prank(facilitator);
      facility.unlock(intentId);
    }

    // Order should be cleared
    (Order memory finalOrder,) = facility.getOrder(intentId);
    assertEq(finalOrder.input, 0, "Order should be cleared");
  }
}
