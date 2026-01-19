// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";

import {PositionManager} from "src/manager/PositionManager.sol";

import {RequestFactory} from "src/request/RequestFactory.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";

contract FacilityRequestHarness is Facility {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

  error CallbackFired(uint256 amount, bytes data);

  function amountOf(uint256 id, address token) external view returns (uint256) {
    FacilityStorageData storage $ = LibStorage.facilityStorage();
    (bool exists, uint256 value) = $.intents[id].amounts.tryGet(token);
    return exists ? value : 0;
  }

  function onPullFunds(uint256 amount, bytes calldata data) external {
    revert CallbackFired(amount, data);
  }
}

contract FacilityRequestOpsTest is Test {
  FacilityRequestHarness internal facility;
  MockERC20 internal asset;
  PositionManager internal pm;

  uint256 internal intentId;
  address internal request;

  function setUp() public {
    facility = new FacilityRequestHarness();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    asset = new MockERC20("USDC", "USDC", 6);
    MockERC20 collateral = new MockERC20("COL", "COL", 18);

    pm = new PositionManager();
    pm.initialize(address(this), "PM", "PM", 18, address(collateral), address(asset), 0.8e18, address(0));

    RequestFactory factory = new RequestFactory(address(this));
    (request,,) = factory.createRequest(
      address(this), address(facility), address(this), address(asset), "Req", "REQ", uint64(type(uint64).max)
    );

    Asset memory depositAsset = Asset({asset: address(asset), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    intentId = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(pm),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0
      })
    );

    facility.setRequest(intentId, request);
    facility.lock(intentId);
  }

  function test_RequestPullAndRepay_NoCallback() public {
    asset.mint(request, 1_000_000);

    facility.pull(intentId, 123_456);

    assertEq(asset.balanceOf(address(facility)), 123_456, "facility received pull");
    assertEq(facility.amountOf(intentId, address(asset)), 123_456, "intent tracks pull");

    facility.repay(intentId, 100_000);

    assertEq(asset.balanceOf(address(facility)), 23_456, "facility after repay");
    assertEq(facility.amountOf(intentId, address(asset)), 23_456, "intent tracks repay");
    assertEq(asset.balanceOf(request), 976_544, "request after repay");
  }
}
