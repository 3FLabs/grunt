// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title FacilityIntentsTest
/// @notice Tests for intent creation, update, lock, and resolve operations
contract FacilityIntentsTest is FacilityBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    CREATE INTENT TESTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_createIntent_success() public {
    IntentProperties memory params = _defaultIntentProperties();

    vm.prank(owner);
    uint256 intentId = facility.createIntent(params);

    assertEq(intentId, 1, "First intent should have ID 1");

    (IntentProperties memory props, address fund, address request, bool resolved) = facility.getIntent(intentId);

    assertEq(props.depositAsset.asset, address(positionManager), "Deposit asset should match");
    assertTrue(props.depositAsset.isPositionManager, "Deposit should be PM");
    assertEq(props.targetAsset.asset, address(debtToken), "Target asset should match");
    assertFalse(props.targetAsset.isPositionManager, "Target should not be PM");
    assertEq(props.depositCap, DEFAULT_DEPOSIT_CAP, "Deposit cap should match");
    assertEq(props.guardKey, address(positionManager), "Guard key should match");
    assertEq(props.resolveStart, uint40(block.timestamp + 1 days), "Resolve start should match");
    assertEq(props.quorum, 1, "Quorum should match");
    assertTrue(props.transferableIntent, "Should be transferable");
    assertEq(fund, address(0), "Fund should be zero");
    assertEq(request, address(0), "Request should be zero");
    assertFalse(resolved, "Should not be resolved");
  }

  function test_createIntent_incrementsId() public {
    vm.startPrank(owner);
    uint256 id1 = facility.createIntent(_defaultIntentProperties());
    uint256 id2 = facility.createIntent(_defaultIntentProperties());
    uint256 id3 = facility.createIntent(_defaultIntentProperties());
    vm.stopPrank();

    assertEq(id1, 1, "First intent ID should be 1");
    assertEq(id2, 2, "Second intent ID should be 2");
    assertEq(id3, 3, "Third intent ID should be 3");
  }

  function test_createIntent_withTargetPM() public {
    IntentProperties memory params = _intentParamsWithTargetPM();

    vm.prank(owner);
    uint256 intentId = facility.createIntent(params);

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.depositAsset.asset, address(debtToken), "Deposit should be debt token");
    assertFalse(props.depositAsset.isPositionManager, "Deposit should not be PM");
    assertEq(props.targetAsset.asset, address(positionManager), "Target should be PM");
    assertTrue(props.targetAsset.isPositionManager, "Target should be PM");
  }

  function test_createIntent_withDualPM() public {
    IntentProperties memory params = _intentParamsWithDualPM();

    vm.prank(owner);
    uint256 intentId = facility.createIntent(params);

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertTrue(props.depositAsset.isPositionManager, "Deposit should be PM");
    assertTrue(props.targetAsset.isPositionManager, "Target should be PM");
    assertEq(props.quorum, 2, "Quorum should be 2");
    assertFalse(props.transferableIntent, "Should not be transferable");
  }

  function test_createIntent_emitsEvent() public {
    IntentProperties memory params = _defaultIntentProperties();

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit IFacilityIntents.IntentCreated(1, params.depositAsset, params.quorum, params.transferableIntent);
    facility.createIntent(params);
  }

  function test_createIntent_revertOnNonOwner() public {
    vm.prank(user);
    vm.expectRevert();
    facility.createIntent(_defaultIntentProperties());
  }

  function test_createIntent_revertOnPastResolveStart() public {
    IntentProperties memory params = _defaultIntentProperties();
    params.resolveStart = uint40(block.timestamp - 1);

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibFacilityErrors.InvalidResolveStart.selector, params.resolveStart, uint40(block.timestamp)
      )
    );
    facility.createIntent(params);
  }

  function test_createIntent_revertOnNoPositionManager() public {
    IntentProperties memory params = _defaultIntentProperties();
    params.depositAsset = Asset({asset: address(debtToken), isPositionManager: false});
    params.targetAsset = Asset({asset: address(collateralToken), isPositionManager: false});

    vm.prank(owner);
    vm.expectRevert(LibFacilityErrors.MissingPositionManager.selector);
    facility.createIntent(params);
  }

  function test_createIntent_revertOnInvalidGuardKey() public {
    IntentProperties memory params = _defaultIntentProperties();
    params.guardKey = address(debtToken); // Wrong guard key

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidGuardKey.selector, address(debtToken)));
    facility.createIntent(params);
  }

  function test_createIntent_revertOnZeroDepositAsset() public {
    IntentProperties memory params = _defaultIntentProperties();
    params.depositAsset = Asset({asset: address(0), isPositionManager: false});

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibCommonErrors.InvalidContract.selector, address(0)));
    facility.createIntent(params);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   UPDATE TARGET TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_updateTarget_success() public {
    uint256 intentId = _createDefaultIntent();

    Asset memory newTarget = Asset({asset: address(collateralToken), isPositionManager: false});

    vm.prank(owner);
    facility.updateTarget(intentId, newTarget, address(positionManager));

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.targetAsset.asset, address(collateralToken), "Target should be updated");
  }

  function test_updateTarget_emitsEvent() public {
    uint256 intentId = _createDefaultIntent();

    Asset memory newTarget = Asset({asset: address(collateralToken), isPositionManager: false});

    vm.prank(owner);
    vm.expectEmit(true, true, true, true);
    emit IFacilityIntents.IntentTargetUpdated(intentId, newTarget, address(positionManager));
    facility.updateTarget(intentId, newTarget, address(positionManager));
  }

  function test_updateTarget_revertOnNonOwner() public {
    uint256 intentId = _createDefaultIntent();

    Asset memory newTarget = Asset({asset: address(collateralToken), isPositionManager: false});

    vm.prank(user);
    vm.expectRevert();
    facility.updateTarget(intentId, newTarget, address(positionManager));
  }

  function test_updateTarget_worksOnResolving() public {
    uint256 intentId = _createResolvingIntent();

    // updateTarget uses getIntent, so it works in any state
    Asset memory newTarget = Asset({asset: address(collateralToken), isPositionManager: false});

    vm.prank(owner);
    facility.updateTarget(intentId, newTarget, address(positionManager));

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.targetAsset.asset, address(collateralToken), "Target should be updated");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   SET DEPOSIT CAP TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setDepositCap_emitsEvent() public {
    uint256 intentId = _createDefaultIntent();
    uint256 newCap = 500_000e18;

    vm.prank(facilitator);
    vm.expectEmit(true, true, true, true);
    emit IFacilityIntents.DepositCapUpdated(intentId, newCap);
    facility.setDepositCap(intentId, newCap);
  }

  function test_setDepositCap_revertOnNonFacilitator() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(user);
    vm.expectRevert();
    facility.setDepositCap(intentId, 500_000e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        LOCK TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_lock_success() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    facility.lock(intentId);

    // Should now be in resolving phase
    assertTrue(_isResolving(intentId), "Intent should be resolving after lock");
  }

  function test_lock_emitsEvent() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    vm.expectEmit(true, true, true, true);
    emit IFacilityIntents.ResolveStartUpdated(intentId, uint40(block.timestamp));
    facility.lock(intentId);
  }

  function test_lock_revertOnNonFacilitator() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(user);
    vm.expectRevert();
    facility.lock(intentId);
  }

  function test_lock_revertOnAlreadyResolving() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotDepositing.selector, intentId));
    facility.lock(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       RESOLVE TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_resolve_success() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    facility.resolve(intentId);

    assertTrue(_isResolved(intentId), "Intent should be resolved");
  }

  function test_resolve_emitsEvent() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    vm.expectEmit(true, true, true, true);
    emit IFacilityIntents.IntentResolved(intentId);
    facility.resolve(intentId);
  }

  function test_resolve_revertOnNotResolving() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.resolve(intentId);
  }

  function test_resolve_revertOnAlreadyResolved() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    facility.resolve(intentId);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.NotResolving.selector, intentId));
    facility.resolve(intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SET FUND TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setFund_success() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    facility.setFund(intentId, address(mockFund));

    (, address fund,,) = facility.getIntent(intentId);
    assertEq(fund, address(mockFund), "Fund should be set");
  }

  function test_setFund_emitsEvent() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    vm.expectEmit(true, true, true, true);
    emit IFacilityIntents.FundUpdated(intentId, address(mockFund));
    facility.setFund(intentId, address(mockFund));
  }

  function test_setFund_revertOnNonFacilitator() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(user);
    vm.expectRevert();
    facility.setFund(intentId, address(mockFund));
  }

  function test_setFund_worksOnDepositing() public {
    // setFund uses getIntent, so it works in any state (not restricted to resolving)
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    facility.setFund(intentId, address(mockFund));

    (, address fund,,) = facility.getIntent(intentId);
    assertEq(fund, address(mockFund), "Fund should be set");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     SET REQUEST TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setRequest_success() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    facility.setRequest(intentId, address(mockRequest));

    (,, address request,) = facility.getIntent(intentId);
    assertEq(request, address(mockRequest), "Request should be set");
  }

  function test_setRequest_emitsEvent() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(facilitator);
    vm.expectEmit(true, true, true, true);
    emit IFacilityIntents.RequestUpdated(intentId, address(mockRequest));
    facility.setRequest(intentId, address(mockRequest));
  }

  function test_setRequest_revertOnNonFacilitator() public {
    uint256 intentId = _createResolvingIntent();

    vm.prank(user);
    vm.expectRevert();
    facility.setRequest(intentId, address(mockRequest));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       FUZZ TESTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_createIntent_withDifferentQuorums(uint8 quorum) public {
    IntentProperties memory params = _defaultIntentProperties();
    params.quorum = quorum;

    vm.prank(owner);
    uint256 intentId = facility.createIntent(params);

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.quorum, quorum, "Quorum should match");
  }

  function testFuzz_createIntent_withDifferentDepositCaps(uint256 cap) public {
    IntentProperties memory params = _defaultIntentProperties();
    params.depositCap = cap;

    vm.prank(owner);
    uint256 intentId = facility.createIntent(params);

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.depositCap, cap, "Deposit cap should match");
  }

  function testFuzz_createIntent_withDifferentResolveStarts(uint40 resolveStart) public {
    vm.assume(resolveStart > block.timestamp);

    IntentProperties memory params = _defaultIntentProperties();
    params.resolveStart = resolveStart;

    vm.prank(owner);
    uint256 intentId = facility.createIntent(params);

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.resolveStart, resolveStart, "Resolve start should match");
  }

  function testFuzz_setDepositCap_withDifferentValues(uint256 cap) public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    facility.setDepositCap(intentId, cap);

    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    assertEq(props.depositCap, cap, "Deposit cap should be updated");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   ADDITIONAL COVERAGE TESTS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setFund_removesFundWithAddressZero() public {
    uint256 intentId = _createResolvingIntent();

    // First set a fund
    vm.prank(facilitator);
    facility.setFund(intentId, address(mockFund));

    // Verify fund is set
    (, address fund,,) = facility.getIntent(intentId);
    assertEq(fund, address(mockFund), "Fund should be set");

    // Now remove the fund with address(0)
    vm.prank(facilitator);
    facility.setFund(intentId, address(0));

    // Verify fund is removed
    (, address newFund,,) = facility.getIntent(intentId);
    assertEq(newFund, address(0), "Fund should be removed");
  }

  function test_setFund_skipsWhenSameFund() public {
    uint256 intentId1 = _createResolvingIntent();

    vm.prank(owner);
    uint256 intentId2 = facility.createIntent(_defaultIntentProperties());
    vm.warp(block.timestamp + 1 days + 1);

    // Set fund on first intent
    vm.prank(facilitator);
    facility.setFund(intentId1, address(mockFund));

    // Call setFund again with the same fund — should be a no-op (early return)
    vm.prank(facilitator);
    facility.setFund(intentId1, address(mockFund));

    // Fund should still be set
    (, address fund,,) = facility.getIntent(intentId1);
    assertEq(fund, address(mockFund), "Fund should still be set");

    // Reverse mapping must be preserved — setting same fund on another intent should revert
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.FundAlreadyInUse.selector, address(mockFund), intentId1));
    facility.setFund(intentId2, address(mockFund));
  }

  function test_setFund_revertWhenFundAlreadyInUse() public {
    // Create two intents
    uint256 intentId1 = _createResolvingIntent();

    vm.prank(owner);
    uint256 intentId2 = facility.createIntent(_defaultIntentProperties());
    vm.warp(block.timestamp + 1 days + 1);

    // Set fund on first intent
    vm.prank(facilitator);
    facility.setFund(intentId1, address(mockFund));

    // Try to set same fund on second intent - should revert
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.FundAlreadyInUse.selector, address(mockFund), intentId1));
    facility.setFund(intentId2, address(mockFund));
  }

  function test_setRequest_skipsWhenSameRequest() public {
    uint256 intentId1 = _createResolvingIntent();

    vm.prank(owner);
    uint256 intentId2 = facility.createIntent(_defaultIntentProperties());
    vm.warp(block.timestamp + 1 days + 1);

    // Set request on first intent
    vm.prank(facilitator);
    facility.setRequest(intentId1, address(mockRequest));

    // Call setRequest again with the same request — should be a no-op (early return)
    vm.prank(facilitator);
    facility.setRequest(intentId1, address(mockRequest));

    // Request should still be set
    (,, address request,) = facility.getIntent(intentId1);
    assertEq(request, address(mockRequest), "Request should still be set");

    // Reverse mapping must be preserved — setting same request on another intent should revert
    vm.prank(facilitator);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.RequestAlreadyInUse.selector, address(mockRequest), intentId1)
    );
    facility.setRequest(intentId2, address(mockRequest));
  }

  function test_setRequest_revertWhenRequestAlreadyInUse() public {
    // Create two intents
    uint256 intentId1 = _createResolvingIntent();

    vm.prank(owner);
    uint256 intentId2 = facility.createIntent(_defaultIntentProperties());
    vm.warp(block.timestamp + 1 days + 1);

    // Set request on first intent
    vm.prank(facilitator);
    facility.setRequest(intentId1, address(mockRequest));

    // Try to set same request on second intent - should revert
    vm.prank(facilitator);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.RequestAlreadyInUse.selector, address(mockRequest), intentId1)
    );
    facility.setRequest(intentId2, address(mockRequest));
  }

  function test_resolve_revertWhenRequestNotRepaid() public {
    uint256 intentId = _createResolvingIntent();

    // Set a request that has outstanding debt
    vm.prank(facilitator);
    facility.setRequest(intentId, address(mockRequest));

    // Configure mock to report not repaid
    mockRequest.setRepaid(false);

    // Try to resolve - should revert
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.RequestNotRepaid.selector, address(mockRequest)));
    facility.resolve(intentId);
  }

  function test_createIntent_revertOnAssetMismatchInTargetPM() public {
    // Deploy a third ERC20 token that doesn't match PM's collateral or debt
    MockERC20 wrongToken = new MockERC20("Wrong Token", "WRONG", 18);

    IntentProperties memory params = _intentParamsWithTargetPM();
    // The deposit asset should match PM's collateral or debt
    // Setting deposit to a valid contract but not matching either PM asset
    params.depositAsset = Asset({asset: address(wrongToken), isPositionManager: false});

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.AssetMismatch.selector, address(collateralToken), address(wrongToken))
    );
    facility.createIntent(params);
  }

  function test_createIntent_revertOnInvalidGuardKeyInTargetPM() public {
    // When target is the only PM, guard key must match the target asset
    // Deploy a different PM to use as invalid guard key
    PositionManager pm3 = new PositionManager();
    pm3.initialize(
      owner,
      PositionManagerMetadata({
        name: "Position Manager 3",
        symbol: "PM3",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      8e17,
      address(transferGuard)
    );

    IntentProperties memory params = _intentParamsWithTargetPM();
    // Guard key is pm3 but target asset is positionManager - should revert
    params.guardKey = address(pm3);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidGuardKey.selector, address(pm3)));
    facility.createIntent(params);
  }

  function test_createIntent_revertOnInvalidGuardKeyInDualPM() public {
    // Deploy a third position manager to use as invalid guard key
    // (it must be a valid contract that responds to assets())
    PositionManager pm3 = new PositionManager();
    pm3.initialize(
      owner,
      PositionManagerMetadata({
        name: "Position Manager 3",
        symbol: "PM3",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      8e17, // 80% LLTV
      address(transferGuard)
    );

    IntentProperties memory params = _intentParamsWithDualPM();
    // Set guard key to pm3 which is a valid PM but doesn't match either deposit or target PM
    params.guardKey = address(pm3);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidGuardKey.selector, address(pm3)));
    facility.createIntent(params);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 NON-EXISTENT INTENT TESTS                  */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_getIntent_revertOnIntentIdZero() public {
    // Create an intent first to ensure ID 0 is always invalid
    vm.prank(owner);
    facility.createIntent(_defaultIntentProperties());

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, 0));
    facility.getIntent(0);
  }

  function testFuzz_getIntent_revertOnNonExistentIntent(uint8 numIntents, uint256 invalidId) public {
    // Create numIntents intents
    vm.startPrank(owner);
    for (uint256 i = 0; i < numIntents; i++) {
      facility.createIntent(_defaultIntentProperties());
    }
    vm.stopPrank();

    // Bound invalidId to be greater than numIntents (non-existent)
    invalidId = bound(invalidId, uint256(numIntents) + 1, type(uint256).max);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.getIntent(invalidId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*          ALL FUNCTIONS REVERT ON NON-EXISTENT INTENT       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_allFunctions_revertOnNonExistentIntent() public {
    uint256 invalidId = 999;

    // View functions
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.getIntent(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.intentBalances(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.getOrder(invalidId);

    // ERC6909 metadata functions that validate intent existence
    // Note: name(), symbol(), tokenURI() delegate to descriptor without validation
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.decimals(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.totalSupply(invalidId);

    // LP functions (called as user to have proper permissions)
    vm.startPrank(user);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.deposit(invalidId, 1000e18);

    // withdraw and claim check balance first (via ERC6909 balanceOf which returns 0),
    // so they revert with InsufficientBalance before checking intent existence
    vm.expectRevert(LibCommonErrors.InsufficientBalance.selector);
    facility.withdraw(invalidId, user, user, 1000e18);

    vm.expectRevert(LibCommonErrors.InsufficientBalance.selector);
    facility.claim(invalidId, user, user, 1000e18);

    vm.stopPrank();

    // Intent management functions (owner only)
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.updateTarget(invalidId, Asset({asset: address(debtToken), isPositionManager: false}), address(0));

    // Facilitator functions
    vm.startPrank(facilitator);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.setDepositCap(invalidId, 1000e18);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.lock(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.resolve(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.setFund(invalidId, address(mockFund));

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.setRequest(invalidId, address(mockRequest));

    // Position manager functions
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.depositManager(invalidId, 1000e18, 0, false);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.withdrawManager(invalidId, 1000e18, 0, false);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.burnManager(invalidId, 1000e18, false);

    // Fund order functions
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.cancel(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.commit(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.unlock(invalidId);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.recover(invalidId);

    // Request functions
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.pull(invalidId, 1000e18);

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, invalidId));
    facility.repay(invalidId, 1000e18);

    vm.stopPrank();
  }
}
