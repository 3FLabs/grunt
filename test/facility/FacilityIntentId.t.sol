// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IIntentDescriptor} from "src/interfaces/IIntentDescriptor.sol";
import {Asset} from "src/interfaces/IFacility.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract FacilityIntentIdTest is Test {
  Facility internal facility;
  PositionManager internal positionManager;

  function setUp() public {
    facility = new Facility();
    facility.initialize(address(this), address(this), IIntentDescriptor(address(0)));

    MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
    MockERC20 debt = new MockERC20("Debt", "DEBT", 6);

    positionManager = new PositionManager();
    positionManager.initialize(address(this), "PM", "PM", 6, address(collateral), address(debt), 0.8e18);
  }

  function _createIntent() internal returns (uint256) {
    Asset memory depositAsset = Asset({asset: address(positionManager), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(0xB0B), isPositionManager: false});

    return facility.createIntent(
      depositAsset,
      targetAsset,
      address(positionManager),
      address(0),
      address(0),
      1_000_000,
      uint40(block.timestamp + 1 days),
      0
    );
  }

  function test_CreateIntent_AllocatesSequentialIds() public {
    uint256 id1 = _createIntent();
    uint256 id2 = _createIntent();

    assertEq(id1, 1, "first intent id");
    assertEq(id2, 2, "second intent id");
  }

  function test_RevertWhen_LockIntentIdIsZero() public {
    vm.expectRevert(abi.encodeWithSelector(Facility.IntentNotFound.selector, uint256(0)));
    facility.lock(0);
  }

  function test_RevertWhen_LockIntentIdNotAllocatedYet() public {
    _createIntent();

    vm.expectRevert(abi.encodeWithSelector(Facility.IntentNotFound.selector, uint256(2)));
    facility.lock(2);
  }
}
