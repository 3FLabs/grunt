// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IIntentDescriptor} from "src/interfaces/IIntentDescriptor.sol";
import {Asset, CreateIntentParams} from "src/interfaces/IFacility.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract FacilityDecimalsTest is Test {
  Facility internal facility;
  PositionManager internal positionManager;
  MockERC20 internal debt;

  function setUp() public {
    facility = new Facility();
    facility.initialize(address(this), address(this), address(0));

    MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    positionManager = new PositionManager();
    positionManager.initialize(address(this), "PM", "PM", 6, address(collateral), address(debt), 0.8e18);
  }

  function test_Decimals_EqualsDepositAssetDecimals() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(positionManager), isPositionManager: true});

    uint256 id = facility.createIntent(
      CreateIntentParams({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(positionManager),
        fund: address(0),
        request: address(0),
        depositCap: 1,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0
      })
    );

    assertEq(facility.decimals(id), 6, "decimals(id)");
  }
}
