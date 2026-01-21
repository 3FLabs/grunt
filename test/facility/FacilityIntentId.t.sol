// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract FacilityIntentIdTest is Test {
  Facility internal facility;
  PositionManager internal positionManager;
  MockERC20 internal debt;

  function setUp() public {
    facility = new Facility();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    positionManager = new PositionManager();
    positionManager.initialize(
      address(this),
      PositionManagerMetadata({
        name: "PM", symbol: "PM", decimals: 6, collateralAsset: address(collateral), debtAsset: address(debt)
      }),
      0.8e18,
      address(0)
    );
  }

  function _createIntent() internal returns (uint256) {
    Asset memory depositAsset = Asset({asset: address(positionManager), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    return facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(positionManager),
        depositCap: 1_000_000,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0,
        transferableIntent: true
      })
    );
  }

  function test_CreateIntent_AllocatesSequentialIds() public {
    uint256 id1 = _createIntent();
    uint256 id2 = _createIntent();

    assertEq(id1, 1, "first intent id");
    assertEq(id2, 2, "second intent id");
  }

  function test_RevertWhen_LockIntentIdIsZero() public {
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, uint256(0)));
    facility.lock(0);
  }

  function test_RevertWhen_LockIntentIdNotAllocatedYet() public {
    _createIntent();

    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentNotFound.selector, uint256(2)));
    facility.lock(2);
  }
}
