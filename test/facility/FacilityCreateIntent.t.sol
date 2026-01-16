// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IntentDescriptor} from "src/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/interfaces/IFacility.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract MockFund {
  address internal immutable ASSET;
  address internal immutable SHARE;

  constructor(address asset_, address share_) {
    ASSET = asset_;
    SHARE = share_;
  }

  function asset() external view returns (address) {
    return ASSET;
  }

  function share() external view returns (address) {
    return SHARE;
  }
}

contract MockRequest {
  address internal immutable ASSET;

  constructor(address asset_) {
    ASSET = asset_;
  }

  function asset() external view returns (address) {
    return ASSET;
  }
}

contract FacilityCreateIntentTest is Test {
  event IntentCreated(uint256 indexed id, Asset depositAsset, uint8 quorum);

  Facility internal facility;

  MockERC20 internal collateral;
  MockERC20 internal collateral2;
  MockERC20 internal debt;

  PositionManager internal pm;
  PositionManager internal pmSame;
  PositionManager internal pmMismatch;

  function setUp() public {
    facility = new Facility();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    collateral = new MockERC20("Collateral", "COL", 18);
    collateral2 = new MockERC20("Collateral2", "COL2", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    pm = _newPositionManager(address(collateral), address(debt));
    pmSame = _newPositionManager(address(collateral), address(debt));
    pmMismatch = _newPositionManager(address(collateral2), address(debt));
  }

  function _newPositionManager(address collateralAsset, address debtAsset) internal returns (PositionManager manager) {
    manager = new PositionManager();
    manager.initialize(address(this), "PM", "PM", 6, collateralAsset, debtAsset, 0.8e18, address(0));
  }

  function _createIntent(
    Asset memory depositAsset,
    Asset memory targetAsset,
    address guardKey,
    uint256 depositCap,
    uint40 resolveStart,
    uint8 quorum
  ) internal returns (uint256 id) {
    id = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: guardKey,
        depositCap: depositCap,
        resolveStart: resolveStart,
        quorum: quorum
      })
    );
  }

  function test_RevertWhen_CreateIntent_ResolveStartNotInFuture() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    vm.expectRevert(
      abi.encodeWithSelector(
        Facility.InvalidResolveStart.selector, uint40(block.timestamp), uint40(block.timestamp)
      )
    );
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp), 0);
  }

  function test_RevertWhen_CreateIntent_NoPositionManager() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(collateral), isPositionManager: false});

    vm.expectRevert(Facility.MissingPositionManager.selector);
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_RevertWhen_CreateIntent_BothPMAssetsMismatch() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(pmMismatch), isPositionManager: true});

    vm.expectRevert(abi.encodeWithSelector(Facility.AssetMismatch.selector, address(collateral), address(collateral2)));
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_RevertWhen_CreateIntent_GuardKeyNotPMSide() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    vm.expectRevert(abi.encodeWithSelector(Facility.InvalidGuardKey.selector, address(pmMismatch)));
    _createIntent(depositAsset, targetAsset, address(pmMismatch), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_RevertWhen_CreateIntent_DepositAssetNotPmDebt() public {
    Asset memory depositAsset = Asset({asset: address(collateral), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    vm.expectRevert(abi.encodeWithSelector(Facility.AssetMismatch.selector, address(debt), address(collateral)));
    _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);
  }

  function test_RevertWhen_CreateIntent_FundAssetMismatch() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockERC20 wrongDebt = new MockERC20("WrongDebt", "WDEBT", 6);
    MockFund fund = new MockFund(address(wrongDebt), address(collateral));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    vm.expectRevert(abi.encodeWithSelector(Facility.AssetMismatch.selector, address(debt), address(wrongDebt)));
    facility.setFund(id, address(fund));
  }

  function test_RevertWhen_CreateIntent_RequestAssetMismatch() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    MockRequest request = new MockRequest(address(collateral));

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 0);

    vm.expectRevert(abi.encodeWithSelector(Facility.AssetMismatch.selector, address(debt), address(collateral)));
    facility.setRequest(id, address(request));
  }

  function test_CreateIntent_Succeeds_WhenDepositIsPM() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(debt), isPositionManager: false});

    vm.expectEmit(true, false, false, true);
    emit IntentCreated(1, depositAsset, 7);

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 123, uint40(block.timestamp + 1 days), 7);

    assertEq(id, 1);
  }

  function test_CreateIntent_Succeeds_WhenTargetIsPM() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    vm.expectEmit(true, false, false, true);
    emit IntentCreated(1, depositAsset, 0);

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 456, uint40(block.timestamp + 1 days), 0);

    assertEq(id, 1);
  }

  function test_CreateIntent_Succeeds_WhenBothArePMAndMatchAssets() public {
    Asset memory depositAsset = Asset({asset: address(pm), isPositionManager: true});
    Asset memory targetAsset = Asset({asset: address(pmSame), isPositionManager: true});

    vm.expectEmit(true, false, false, true);
    emit IntentCreated(1, depositAsset, 1);

    uint256 id = _createIntent(depositAsset, targetAsset, address(pm), 1, uint40(block.timestamp + 1 days), 1);

    assertEq(id, 1);
  }
}
