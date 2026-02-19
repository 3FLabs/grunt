// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {MockRequest} from "test/mock/facility/MockRequest.sol";

/// @title FacilityRequestsTest
/// @notice Tests for Facility request operations (pull, repay)
contract FacilityRequestsTest is FacilityBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SETUP HELPERS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates an intent with deposits and request set, warped past the repay timelock
  function _createIntentWithRequest(uint256 depositAmount) internal returns (uint256 intentId) {
    intentId = _createIntentWithDeposits(depositAmount);

    // Set request for the intent
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    // Warp past the repay timelock so repay is allowed
    vm.warp(block.timestamp + DEFAULT_REPAY_TIMELOCK);
  }

  /// @notice Funds the mock request with tokens for pulling
  function _fundMockRequest(uint256 amount) internal {
    _mintDebt(address(mockRequest), amount);
  }

  /// @notice Funds the facility intent with tokens for repaying
  function _fundIntentForRepay(uint256 intentId, uint256 amount) internal {
    // Transfer debt tokens to facility
    _mintDebt(address(this), amount);
    debtToken.transfer(address(facility), amount);
    // Note: We need to track the balance internally too, but for testing we just transfer
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        PULL TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pull_updatesIntentBalance() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    uint256 pullAmount = 500e18;

    _fundMockRequest(pullAmount);

    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);

    // Check intent balances
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(intentId);

    // Should have both PM shares (from deposit) and debt token (from pull)
    bool hasDebtToken = false;
    for (uint256 i = 0; i < tokens.length; i++) {
      if (tokens[i] == address(debtToken)) {
        assertEq(amounts[i], pullAmount, "Debt token balance should match pull amount");
        hasDebtToken = true;
      }
    }
    assertTrue(hasDebtToken, "Should have debt token in balances");
  }

  function test_pull_multiplePulls() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    uint256 pullAmount1 = 300e18;
    uint256 pullAmount2 = 200e18;

    _fundMockRequest(pullAmount1 + pullAmount2);

    // First pull
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount1);

    // Second pull
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount2);

    assertEq(mockRequest.pullFundsCallCount(), 2, "pullFunds should be called twice");
  }

  function test_pull_revertWhenPaused() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    _fundMockRequest(500e18);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.pull(intentId, 500e18);
  }

  function test_pull_revertWhenNotFacilitator() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    _fundMockRequest(500e18);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.pull(intentId, 500e18);
  }

  function test_pull_revertWhenMissingRequest() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);
    // Request not set

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.MissingRequest.selector, intentId));
    facility.pull(intentId, 500e18);
  }

  function test_pull_revertWhenNotResolving() public {
    uint256 intentId = _createDefaultIntent();

    // Set request while still in depositing phase
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    _fundMockRequest(500e18);

    // Still in depositing phase - should revert
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.pull(intentId, 500e18);
  }

  function test_pull_revertWhenRequestReverts() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    _fundMockRequest(500e18);

    // Set mock to revert
    mockRequest.setShouldRevert(true, "Request failed");

    vm.prank(facilitator);
    vm.expectRevert("Request failed");
    facility.pull(intentId, 500e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        REPAY TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_repay_updatesIntentBalance() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    uint256 pullAmount = 500e18;
    uint256 repayAmount = 300e18;

    _fundMockRequest(pullAmount);
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);

    vm.prank(facilitator);
    facility.repay(intentId, repayAmount);

    // Check intent balances - should have pullAmount - repayAmount of debt token
    (address[] memory tokens, uint256[] memory amounts) = facility.intentBalances(intentId);

    for (uint256 i = 0; i < tokens.length; i++) {
      if (tokens[i] == address(debtToken)) {
        assertEq(amounts[i], pullAmount - repayAmount, "Debt token balance should be reduced");
      }
    }
  }

  function test_repay_multipleRepays() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    uint256 pullAmount = 500e18;
    uint256 repay1 = 150e18;
    uint256 repay2 = 150e18;

    _fundMockRequest(pullAmount);
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);

    // First repay
    vm.prank(facilitator);
    facility.repay(intentId, repay1);

    // Second repay
    vm.prank(facilitator);
    facility.repay(intentId, repay2);

    assertEq(mockRequest.repayCallCount(), 2, "repay should be called twice");
  }

  function test_repay_revertWhenPaused() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    _fundMockRequest(500e18);
    vm.prank(facilitator);
    facility.pull(intentId, 500e18);

    vm.prank(pauser);
    facility.pauseFor(1 hours);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.repay(intentId, 300e18);
  }

  function test_repay_revertWhenNotFacilitator() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    _fundMockRequest(500e18);
    vm.prank(facilitator);
    facility.pull(intentId, 500e18);

    vm.prank(user);
    vm.expectRevert(); // Unauthorized
    facility.repay(intentId, 300e18);
  }

  function test_repay_revertWhenMissingRequest() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);
    // Request not set

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.MissingRequest.selector, intentId));
    facility.repay(intentId, 300e18);
  }

  function test_repay_revertWhenNotResolving() public {
    uint256 intentId = _createDefaultIntent();

    // Set request while still in depositing phase
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    // Still in depositing phase - should revert
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.repay(intentId, 300e18);
  }

  function test_repay_revertWhenRequestReverts() public {
    uint256 intentId = _createIntentWithRequest(1000e18);
    _fundMockRequest(500e18);
    vm.prank(facilitator);
    facility.pull(intentId, 500e18);

    // Set mock to revert
    mockRequest.setShouldRevert(true, "Repay failed");

    vm.prank(facilitator);
    vm.expectRevert("Repay failed");
    facility.repay(intentId, 300e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUZZ TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_pull_validAmount(uint256 amount) public {
    amount = bound(amount, 1, 10_000_000e18);

    uint256 intentId = _createIntentWithRequest(DEFAULT_DEPOSIT_CAP);
    _fundMockRequest(amount);

    vm.prank(facilitator);
    facility.pull(intentId, amount);

    assertEq(mockRequest.lastPullAmount(), amount, "Pull amount should match");
  }

  function testFuzz_repay_validAmount(uint256 pullAmount, uint256 repayAmount) public {
    pullAmount = bound(pullAmount, 1e18, 10_000_000e18);
    repayAmount = bound(repayAmount, 1, pullAmount);

    uint256 intentId = _createIntentWithRequest(DEFAULT_DEPOSIT_CAP);
    _fundMockRequest(pullAmount);

    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);

    vm.prank(facilitator);
    facility.repay(intentId, repayAmount);

    assertEq(mockRequest.lastRepayAmount(), repayAmount, "Repay amount should match");
  }

  function testFuzz_pullAndRepay_cycle(uint256 pullAmount, uint256 repayAmount, uint256 secondPull) public {
    pullAmount = bound(pullAmount, 1e18, 1_000_000e18);
    repayAmount = bound(repayAmount, 1, pullAmount);
    secondPull = bound(secondPull, 1, 1_000_000e18);

    uint256 intentId = _createIntentWithRequest(DEFAULT_DEPOSIT_CAP);

    // First pull
    _fundMockRequest(pullAmount);
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);

    // Repay some
    vm.prank(facilitator);
    facility.repay(intentId, repayAmount);

    // Pull again
    _fundMockRequest(secondPull);
    vm.prank(facilitator);
    facility.pull(intentId, secondPull);

    assertEq(mockRequest.pullFundsCallCount(), 2, "Should have 2 pulls");
    assertEq(mockRequest.repayCallCount(), 1, "Should have 1 repay");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REPAY TIMELOCK TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_pull_succeedsImmediatelyAfterSetRequest() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);
    uint256 pullAmount = 500e18;

    // Set request (starts the repay timelock, but pull is NOT affected)
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));
    _fundMockRequest(pullAmount);

    // Pull should succeed immediately — timelock only applies to repay
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);
    assertEq(mockRequest.lastPullAmount(), pullAmount, "Pull should succeed immediately");
  }

  function test_repay_revertWhenTimelockActive() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);

    // Set request (starts the timelock)
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    // Try to repay immediately - should revert
    uint40 expectedAvailableAt = uint40(block.timestamp) + DEFAULT_REPAY_TIMELOCK;
    vm.prank(facilitator);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.RepayTimelockActive.selector, intentId, expectedAvailableAt)
    );
    facility.repay(intentId, 300e18);
  }

  function test_repay_succeedsAfterTimelockExpires() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);
    uint256 pullAmount = 500e18;

    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));
    _fundMockRequest(pullAmount);

    // Warp past the timelock
    vm.warp(block.timestamp + DEFAULT_REPAY_TIMELOCK);

    // Pull first, then repay
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);
    vm.prank(facilitator);
    facility.repay(intentId, 200e18);
    assertEq(mockRequest.lastRepayAmount(), 200e18, "Repay should succeed after timelock");
  }

  function test_repayAvailableAt_returnsCorrectTimestamp() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);

    // Before request is set, should return 0
    assertEq(facility.repayAvailableAt(intentId), 0, "Should be 0 when no request");

    // Set request
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    // Should return requestSetAt + repayTimelock
    uint40 expected = uint40(block.timestamp) + DEFAULT_REPAY_TIMELOCK;
    assertEq(facility.repayAvailableAt(intentId), expected, "Should return correct available timestamp");
  }

  function test_requestSetAt_trackedOnSetRequest() public {
    uint256 intentId = _createResolvingIntent();

    // Set request and check requestSetAt is tracked
    uint40 beforeTimestamp = uint40(block.timestamp);
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    (,,,, uint40 requestSetAt) = facility.getIntent(intentId);
    assertEq(requestSetAt, beforeTimestamp, "requestSetAt should equal block.timestamp");
  }

  function test_requestSetAt_clearedOnRemoveRequest() public {
    uint256 intentId = _createResolvingIntent();

    // Set request
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));
    mockRequest.setRepaid(true);

    // Remove request (set to address(0))
    vm.prank(facilitator);
    _setRequest(intentId, address(0));

    (,,,, uint40 requestSetAt) = facility.getIntent(intentId);
    assertEq(requestSetAt, 0, "requestSetAt should be cleared when request is removed");
  }

  function test_timelockRestartsOnNewRequest() public {
    uint256 intentId = _createIntentWithDeposits(1000e18);

    // Set first request
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));
    mockRequest.setRepaid(true);

    // Warp past timelock
    vm.warp(block.timestamp + DEFAULT_REPAY_TIMELOCK);

    // Replace request - timelock restarts
    MockRequest newRequest = new MockRequest(address(debtToken));
    vm.prank(facilitator);
    _setRequest(intentId, address(newRequest));

    // Try to repay immediately - should revert (timelock restarted)
    uint40 expectedAvailableAt = uint40(block.timestamp) + DEFAULT_REPAY_TIMELOCK;
    vm.prank(facilitator);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.RepayTimelockActive.selector, intentId, expectedAvailableAt)
    );
    facility.repay(intentId, 100e18);
  }
}
