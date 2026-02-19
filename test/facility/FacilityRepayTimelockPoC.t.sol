// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {MockRequest} from "test/mock/facility/MockRequest.sol";

/// @title FacilityRepayTimelockPoCTest
/// @notice Proof of Concept demonstrating that the repay timelock prevents the CS-I-11 attack.
/// @dev Reference: ChainSecurity I-11 — CRITICAL: Facilitator can steal all deposits within two blocks.
///
///      Attack sequence (without fix):
///        Block N:
///          1. lock(intentId)                 → Intent transitions from DEPOSITING to RESOLVING
///          2. createRequest(facilitator, ...) → Creates a malicious Request owned by the Facilitator
///          3. authorizeMinting + mint()       → Facilitator deposits 1 wei, gets 1 PT + 1 YT
///          4. setRequest(intentId, request)   → Links the malicious Request to the intent
///          5. repay(intentId, allFunds)       → Facility transfers ALL deposited funds to the Request
///
///        Block N+1 (12 seconds later):
///          6. burnAll(self, self)             → Facilitator extracts all funds via PT/YT burn
///
///      With the repay timelock fix (Option 4), step 5 reverts because a minimum delay is enforced
///      between setRequest() and the first repay() call. This gives guardians and depositors
///      time to review the request before deposited funds can be sent to it.
contract FacilityRepayTimelockPoCTest is FacilityBaseTest {
  /// @notice Demonstrates that the attack is blocked by the repay timelock.
  /// @dev The facilitator cannot atomically call setRequest + repay in the same block.
  ///      After lock → setRequest, calling repay reverts with RepayTimelockActive.
  function test_poc_facilitatorCannotStealDepositsAtomically() public {
    // --- Setup: Users deposit 1,000,000 PM shares into the intent ---
    uint256 depositAmount = 1_000_000e18;
    uint256 intentId = _createDefaultIntent();

    // Simulate user deposits
    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Verify deposits are in the facility
    assertEq(facility.totalSupply(intentId), depositAmount, "Users deposited 1M shares");

    // --- Block N: Facilitator attempts the attack ---

    // Step 1: Lock the intent (DEPOSITING → RESOLVING)
    vm.prank(facilitator);
    facility.lock(intentId);

    // Step 2-3: Facilitator creates a malicious request (simulated by MockRequest)
    MockRequest maliciousRequest = new MockRequest(address(debtToken));

    // Step 4: Facilitator links the malicious request to the intent
    vm.prank(facilitator);
    _setRequest(intentId, address(maliciousRequest));

    // Step 5: Facilitator tries to drain all funds via repay — THIS MUST REVERT
    uint40 expectedAvailableAt = uint40(block.timestamp) + DEFAULT_REPAY_TIMELOCK;
    vm.prank(facilitator);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.RepayTimelockActive.selector, intentId, expectedAvailableAt)
    );
    facility.repay(intentId, depositAmount);

    // --- Verify the attack was fully prevented ---
    // User deposits are still in the facility (not drained)
    assertEq(facility.totalSupply(intentId), depositAmount, "User deposits should be intact");
  }

  /// @notice Verifies that after the timelock expires, legitimate pull/repay operations succeed.
  /// @dev This ensures the timelock doesn't permanently block operations — only delays them.
  function test_poc_legitimateOperationsSucceedAfterTimelock() public {
    uint256 depositAmount = 1_000_000e18;
    uint256 intentId = _createDefaultIntent();

    _depositToPM(user, depositAmount);
    vm.prank(user);
    facility.deposit(intentId, depositAmount);

    // Lock and set request
    vm.prank(facilitator);
    facility.lock(intentId);

    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    // Warp past the timelock
    vm.warp(block.timestamp + DEFAULT_REPAY_TIMELOCK);

    // Pull should succeed after timelock
    uint256 pullAmount = 500e18;
    _mintDebt(address(mockRequest), pullAmount);
    vm.prank(facilitator);
    facility.pull(intentId, pullAmount);

    assertEq(mockRequest.lastPullAmount(), pullAmount, "Pull should work after timelock");
  }

  /// @notice Verifies the view function repayAvailableAt returns the correct unlock time.
  /// @dev Guardians and depositors can query this to know when to check for suspicious activity.
  function test_poc_repayAvailableAtReturnsCorrectTime() public {
    uint256 intentId = _createDefaultIntent();

    // Before request: repayAvailableAt should return 0
    assertEq(facility.repayAvailableAt(intentId), 0, "No request = available at 0");

    // Lock + set request
    vm.prank(facilitator);
    facility.lock(intentId);

    uint40 setTime = uint40(block.timestamp);
    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    // repayAvailableAt should return setTime + timelock
    uint40 expected = setTime + DEFAULT_REPAY_TIMELOCK;
    assertEq(facility.repayAvailableAt(intentId), expected, "Should return correct unlock time");

    // After timelock passes, operations are available
    vm.warp(expected);
    assertLe(facility.repayAvailableAt(intentId), uint40(block.timestamp), "Should be available now");
  }

  /// @notice Verifies that replacing the request restarts the timelock.
  /// @dev Prevents the facilitator from pre-setting a legitimate request, waiting for the timelock,
  ///      then swapping to a malicious request and draining immediately.
  function test_poc_replacingRequestRestartsTimelock() public {
    uint256 intentId = _createDefaultIntent();

    _depositToPM(user, 1_000_000e18);
    vm.prank(user);
    facility.deposit(intentId, 1_000_000e18);

    // Lock and set legitimate request
    vm.prank(facilitator);
    facility.lock(intentId);

    vm.prank(facilitator);
    _setRequest(intentId, address(mockRequest));

    // Warp past timelock — operations now allowed
    vm.warp(block.timestamp + DEFAULT_REPAY_TIMELOCK);

    // Now swap to a malicious request
    MockRequest maliciousRequest = new MockRequest(address(debtToken));
    mockRequest.setRepaid(true); // Mark old request as repaid so replacement is allowed

    vm.prank(facilitator);
    _setRequest(intentId, address(maliciousRequest));

    // Timelock has restarted — repay must revert
    uint40 newAvailableAt = uint40(block.timestamp) + DEFAULT_REPAY_TIMELOCK;
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.RepayTimelockActive.selector, intentId, newAvailableAt));
    facility.repay(intentId, 1_000_000e18);
  }
}
