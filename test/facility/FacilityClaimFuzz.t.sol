// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/Facility.sol";
import {IIntentDescriptor} from "src/interfaces/IIntentDescriptor.sol";
import {Asset, CreateIntentParams} from "src/interfaces/IFacility.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract FacilityClaimFuzzTest is Test {
  Facility internal facility;
  PositionManager internal pm;
  MockERC20 internal collateral;
  MockERC20 internal debt;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal carol = makeAddr("carol");

  function setUp() public {
    facility = new Facility();
    facility.initialize(address(this), address(this), IIntentDescriptor(address(0)));

    collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    pm = new PositionManager();
    pm.initialize(address(this), "PM", "PM", 6, address(collateral), address(debt), 0.8e18);
  }

  function _createIntent() internal returns (uint256 id) {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    id = facility.createIntent(
      CreateIntentParams({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(pm),
        fund: address(0),
        request: address(0),
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

  function testFuzz_Claim_TotalDistributedNeverExceedsHoldings(uint96 a, uint96 b, uint96 c) public {
    uint256 id = _createIntent();

    a = uint96(bound(a, 1, 1_000_000_000_000));
    b = uint96(bound(b, 1, 1_000_000_000_000));
    c = uint96(bound(c, 1, 1_000_000_000_000));

    _deposit(alice, id, a);
    _deposit(bob, id, b);
    _deposit(carol, id, c);

    uint256 totalDeposited = uint256(a) + uint256(b) + uint256(c);
    assertEq(debt.balanceOf(address(facility)), totalDeposited, "facility balance before");

    facility.lock(id);
    facility.resolve(id);

    vm.prank(alice);
    facility.claim(id);
    vm.prank(bob);
    facility.claim(id);
    vm.prank(carol);
    facility.claim(id);

    uint256 claimed = debt.balanceOf(alice) + debt.balanceOf(bob) + debt.balanceOf(carol);

    // Hard requirement: total distributed across claimers does not exceed the original holdings.
    assertLe(claimed, totalDeposited, "distributed exceeds holdings");

    // Stronger invariant: any residual is retained in Facility (dust).
    assertEq(claimed + debt.balanceOf(address(facility)), totalDeposited, "accounting mismatch");

    assertEq(facility.totalSupply(id), 0, "intent supply");
    assertEq(facility.balanceOf(alice, id), 0, "alice intent balance");
    assertEq(facility.balanceOf(bob, id), 0, "bob intent balance");
    assertEq(facility.balanceOf(carol, id), 0, "carol intent balance");
  }
}
