// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
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
  uint256 internal constant TRANSFER_AMOUNT = 5_000_000;

  function setUp() public {
    facility = new Facility();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    transferGuard = new TransferGuard();
    transferGuard.initialize(address(this));

    positionManager = new PositionManager();
    positionManager.initialize(
      address(this),
      PositionManagerMetadata({
        name: "PM", symbol: "PM", decimals: 6, collateralAsset: address(collateral), debtAsset: address(debt)
      }),
      0.8e18,
      address(transferGuard)
    );

    transferGuard.setTokenConfig(address(positionManager), false, true);
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
        quorum: 0,
        transferableIntent: true
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

  function test_TransferGuard_AllowsWhitelistedTransfers() public {
    uint256 id = _createIntent();
    uint256 amount = TRANSFER_AMOUNT;

    transferGuard.setAddressStatus(alice, AddressStatus.WHITELIST);
    transferGuard.setAddressStatus(bob, AddressStatus.WHITELIST);

    _deposit(alice, id, amount);

    vm.prank(alice);
    facility.transfer(bob, id, amount);

    assertEq(facility.balanceOf(bob, id), amount, "bob balance");
  }

  function test_TransferGuard_BlocksNonWhitelistedRecipient() public {
    uint256 id = _createIntent();
    uint256 amount = TRANSFER_AMOUNT;

    transferGuard.setAddressStatus(alice, AddressStatus.WHITELIST);

    _deposit(alice, id, amount);

    vm.startPrank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(LibFacilityErrors.TransferBlocked.selector, address(transferGuard), alice, bob, amount)
    );
    facility.transfer(bob, id, amount);
    vm.stopPrank();

    assertEq(facility.balanceOf(alice, id), amount, "alice balance");
    assertEq(facility.balanceOf(bob, id), 0, "bob balance");
  }

  function test_TransferLock_RevertsTransfersEvenIfWhitelisted() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(positionManager), isPositionManager: true});

    uint256 id = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(positionManager),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0,
        transferableIntent: false
      })
    );

    transferGuard.setAddressStatus(alice, AddressStatus.WHITELIST);
    transferGuard.setAddressStatus(bob, AddressStatus.WHITELIST);

    _deposit(alice, id, TRANSFER_AMOUNT);

    vm.startPrank(alice);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.IntentTransfersLocked.selector, id));
    facility.transfer(bob, id, TRANSFER_AMOUNT);
    vm.stopPrank();
  }

  function test_TransferLock_DoesNotBlockMintOrBurn() public {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(positionManager), isPositionManager: true});

    uint256 id = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(positionManager),
        depositCap: type(uint256).max,
        resolveStart: uint40(block.timestamp + 1 days),
        quorum: 0,
        transferableIntent: false
      })
    );

    transferGuard.setAddressStatus(alice, AddressStatus.WHITELIST);

    _deposit(alice, id, TRANSFER_AMOUNT);
    assertEq(facility.balanceOf(alice, id), TRANSFER_AMOUNT, "alice intent balance");

    vm.prank(alice);
    facility.withdraw(id, alice, alice, TRANSFER_AMOUNT);
    assertEq(facility.balanceOf(alice, id), 0, "alice intent balance after burn");
  }
}
