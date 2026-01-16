// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IIntentDescriptor} from "src/interfaces/IIntentDescriptor.sol";
import {Asset} from "src/interfaces/IFacility.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract FacilityUpdateTargetTest is Test {
  event IntentTargetUpdated(
    uint256 indexed id,
    address oldTargetAsset,
    bool oldTargetIsPositionManager,
    address newTargetAsset,
    bool newTargetIsPositionManager,
    address indexed oldGuardKey,
    address indexed newGuardKey
  );

  Facility internal facility;

  MockERC20 internal collateral;
  MockERC20 internal collateral2;
  MockERC20 internal debt;

  PositionManager internal pm1;
  PositionManager internal pm2;
  PositionManager internal pmMismatch;

  function setUp() public {
    facility = new Facility();
    facility.initialize(address(this), address(this), IIntentDescriptor(address(0)));

    collateral = new MockERC20("Collateral", "COL", 18);
    collateral2 = new MockERC20("Collateral2", "COL2", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    pm1 = _newPositionManager(address(collateral), address(debt));
    pm2 = _newPositionManager(address(collateral), address(debt));
    pmMismatch = _newPositionManager(address(collateral2), address(debt));
  }

  function _newPositionManager(address collateralAsset, address debtAsset) internal returns (PositionManager manager) {
    manager = new PositionManager();
    manager.initialize(address(this), "PM", "PM", 6, collateralAsset, debtAsset, 0.8e18);
  }

  function _createPmPmIntent() internal returns (uint256 id) {
    Asset memory depositAsset = Asset({asset: address(pm1), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(pm2), isPositionManager: true});

    id = facility.createIntent(
      depositAsset, targetAsset, address(pm1), address(0), address(0), 1, uint40(block.timestamp + 1 days), 0
    );
  }

  function _createDebtPmIntent() internal returns (uint256 id) {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm1), isPositionManager: true});

    id = facility.createIntent(
      depositAsset, targetAsset, address(pm1), address(0), address(0), 1, uint40(block.timestamp + 1 days), 0
    );
  }

  function test_RevertWhen_UpdateTarget_NotOwner() public {
    uint256 id = _createPmPmIntent();

    Asset memory newTarget = Asset({asset: address(pm1), isPositionManager: true});

    vm.prank(address(0xBEEF));
    vm.expectRevert();
    facility.updateTarget(id, newTarget, address(pm1));
  }

  function test_UpdateTarget_AllowsGuardKeyChange_WhenBothSidesPM() public {
    uint256 id = _createPmPmIntent();

    Asset memory newTarget = Asset({asset: address(pm2), isPositionManager: true});

    vm.expectEmit(true, true, false, true);
    emit IntentTargetUpdated(id, address(pm2), true, address(pm2), true, address(pm1), address(pm2));

    facility.updateTarget(id, newTarget, address(pm2));
  }

  function test_UpdateTarget_WorksAfterLockAndResolve() public {
    uint256 id = _createPmPmIntent();

    facility.lock(id);

    Asset memory newTarget1 = Asset({asset: address(pm1), isPositionManager: true});
    facility.updateTarget(id, newTarget1, address(pm1));

    facility.resolve(id);

    Asset memory newTarget2 = Asset({asset: address(pm2), isPositionManager: true});
    facility.updateTarget(id, newTarget2, address(pm2));
  }

  function test_RevertWhen_UpdateTarget_RemovesLastPM() public {
    uint256 id = _createDebtPmIntent();

    Asset memory newTarget = Asset({asset: address(collateral), isPositionManager: false});

    vm.expectRevert(abi.encodeWithSelector(Facility.InvalidAsset.selector, id));
    facility.updateTarget(id, newTarget, address(pm1));
  }

  function test_RevertWhen_UpdateTarget_NewPMAssetsMismatch() public {
    uint256 id = _createPmPmIntent();

    Asset memory newTarget = Asset({asset: address(pmMismatch), isPositionManager: true});

    vm.expectRevert(abi.encodeWithSelector(Facility.InvalidAsset.selector, id));
    facility.updateTarget(id, newTarget, address(pm1));
  }
}
