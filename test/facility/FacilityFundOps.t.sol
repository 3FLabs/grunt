// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IntentDescriptor} from "src/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/interfaces/IFacility.sol";

import {Order, Mode} from "src/libs/Order.sol";

import {PositionManager} from "src/manager/PositionManager.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {MockFund} from "test/facility/MockFund.sol";

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";

contract FacilityFundHarness is Facility {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

  function amountOf(uint256 id, address token) external view returns (uint256) {
    FacilityStorageData storage $ = LibStorage.facilityStorage();
    (bool exists, uint256 value) = $.intents[id].amounts.tryGet(token);
    return exists ? value : 0;
  }

  function orderOwner(uint256 id) external view returns (address) {
    return LibStorage.facilityStorage().intents[id].order.owner;
  }
}

contract FacilityFundOpsTest is Test {
  FacilityFundHarness internal facility;
  MockERC20 internal asset;
  MockERC20 internal share;
  PositionManager internal pm;
  MockFund internal fund;
  uint256 internal intentId;

  function setUp() public {
    facility = new FacilityFundHarness();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    asset = new MockERC20("Debt", "DEBT", 6);
    share = new MockERC20("Collateral", "COL", 18);

    pm = new PositionManager();
    pm.initialize(address(this), "PM", "PM", 18, address(share), address(asset), 0.8e18, address(0));

    fund = new MockFund(address(asset), address(share));

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

    facility.setFund(intentId, address(fund));

    // Seed the intent with assets (deposit phase).
    asset.mint(address(this), 1_000_000);
    asset.approve(address(facility), 1_000_000);
    facility.deposit(intentId, 1_000_000);

    facility.lock(intentId);
  }

  function test_FundUnlock_LoopsTwiceAndClearsOrder() public {
    uint256 amountIn = 600_000;
    uint256 amountOut = 400_000;

    // Fund must be pre-funded so it can transfer output.
    share.mint(address(fund), amountOut);

    Order memory order = facility.create(intentId, amountIn, amountOut, Mode.DEPOSIT);
    assertEq(facility.orderOwner(intentId), address(facility), "order active after create");

    facility.commit(intentId);

    assertEq(asset.balanceOf(address(facility)), 400_000, "facility asset after commit");
    assertEq(asset.balanceOf(address(fund)), amountIn, "fund asset after commit");
    assertEq(facility.amountOf(intentId, address(asset)), 400_000, "intent tracks commit");

    facility.unlock(intentId);

    // First unlock: partial output, order remains active.
    assertEq(facility.orderOwner(intentId), address(facility), "order still active after first unlock");
    assertEq(share.balanceOf(address(facility)), amountOut / 2, "facility share after first unlock");
    assertEq(
      facility.amountOf(intentId, address(share)), share.balanceOf(address(facility)), "intent tracks first unlock"
    );

    facility.unlock(intentId);

    // Second unlock: finishes output, order cleared.
    assertEq(facility.orderOwner(intentId), address(0), "order cleared after second unlock");
    assertEq(share.balanceOf(address(facility)), amountOut, "facility share after second unlock");
    assertEq(
      facility.amountOf(intentId, address(share)), share.balanceOf(address(facility)), "intent tracks second unlock"
    );

    // Sanity: recorded balances match actual balances for tracked tokens.
    assertEq(facility.amountOf(intentId, address(asset)), asset.balanceOf(address(facility)), "final asset tracked");
    assertEq(facility.amountOf(intentId, address(share)), share.balanceOf(address(facility)), "final share tracked");

    // Silence unused variable warning.
    order;
  }
}
