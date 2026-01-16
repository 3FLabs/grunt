// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IntentDescriptor} from "src/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/interfaces/IFacility.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {TransferGuard, AddressStatus} from "src/guard/TransferGuard.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract FacilityTransferGuardTest is Test {
  Facility internal facility;
  PositionManager internal positionManager;
  TransferGuard internal transferGuard;
  MockERC20 internal debt;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");

  // 6-decimal token units.
  uint256 internal constant THRESHOLD = 5_000_000;

  function setUp() public {
    facility = new Facility();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    positionManager = new PositionManager();
    positionManager.initialize(address(this), "PM", "PM", 6, address(collateral), address(debt), 0.8e18);

    transferGuard = new TransferGuard();
    transferGuard.initialize(address(this));

    positionManager.setTransferGuard(address(transferGuard));
    transferGuard.setTokenConfig(address(positionManager), false, THRESHOLD, address(0));
  }

  function _createIntent() internal returns (uint256 id) {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(positionManager), isPositionManager: true});

    id = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(positionManager),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0
      })
    );
  }

  function _deposit(address depositor, uint256 id, uint256 amount) internal {
    debt.mint(depositor, amount);

    vm.startPrank(depositor);
    debt.approve(address(facility), amount);
    facility.deposit(id, amount);
    vm.stopPrank();
  }

  function test_TransferGuard_AllowsSmallTransfers() public {
    uint256 id = _createIntent();
    uint256 amount = THRESHOLD - 1;

    _deposit(alice, id, amount);

    vm.prank(alice);
    facility.transfer(bob, id, amount);

    assertEq(facility.balanceOf(bob, id), amount, "bob balance");
  }

  function test_TransferGuard_BlocksLargeTransfers() public {
    uint256 id = _createIntent();
    uint256 amount = THRESHOLD;

    // Allow minting a large amount to alice.
    transferGuard.setAddressStatus(alice, AddressStatus.WHITELIST_ALL_AMOUNTS);

    _deposit(alice, id, amount);

    vm.startPrank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(Facility.TransferBlocked.selector, address(transferGuard), alice, bob, amount)
    );
    facility.transfer(bob, id, amount);
    vm.stopPrank();

    assertEq(facility.balanceOf(alice, id), amount, "alice balance");
    assertEq(facility.balanceOf(bob, id), 0, "bob balance");
  }
}
