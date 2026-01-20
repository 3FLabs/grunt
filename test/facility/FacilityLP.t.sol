// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Facility} from "src/facility/Facility.sol";
import {IntentDescriptor} from "src/facility/IntentDescriptor.sol";
import {Asset, IntentProperties} from "src/libs/facility/LibIntent.sol";

import {PositionManager} from "src/manager/PositionManager.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract FacilityLPTest is Test {
  Facility internal facility;
  PositionManager internal pm;
  MockERC20 internal collateral;
  MockERC20 internal debt;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal operator = makeAddr("operator");

  function setUp() public {
    facility = new Facility();
    IntentDescriptor descriptor = new IntentDescriptor();
    facility.initialize(address(this), address(this), address(descriptor));

    collateral = new MockERC20("Collateral", "COL", 18);
    debt = new MockERC20("Debt", "DEBT", 6);

    pm = new PositionManager();
    pm.initialize(address(this), "PM", "PM", 6, address(collateral), address(debt), 0.8e18, address(0));
  }

  function _createIntent() internal returns (uint256 id) {
    Asset memory depositAsset = Asset({asset: address(debt), isPositionManager: false});
    Asset memory targetAsset = Asset({asset: address(pm), isPositionManager: true});

    id = facility.createIntent(
      IntentProperties({
        depositAsset: depositAsset,
        targetAsset: targetAsset,
        guardKey: address(pm),
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WITHDRAW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Withdraw_FromSelf() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    assertEq(facility.balanceOf(alice, id), 100);
    assertEq(debt.balanceOf(alice), 0);

    vm.prank(alice);
    facility.withdraw(id, alice, alice, 50);

    assertEq(facility.balanceOf(alice, id), 50);
    assertEq(debt.balanceOf(alice), 50);
  }

  function test_Withdraw_FromSelfToReceiver() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    assertEq(facility.balanceOf(alice, id), 100);
    assertEq(debt.balanceOf(bob), 0);

    vm.prank(alice);
    facility.withdraw(id, alice, bob, 50);

    assertEq(facility.balanceOf(alice, id), 50);
    assertEq(debt.balanceOf(bob), 50);
  }

  function test_Withdraw_AsOperator() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    // alice sets operator as an operator
    vm.prank(alice);
    facility.setOperator(operator, true);

    assertEq(facility.balanceOf(alice, id), 100);
    assertEq(debt.balanceOf(bob), 0);

    // operator withdraws on behalf of alice to bob
    vm.prank(operator);
    facility.withdraw(id, alice, bob, 50);

    assertEq(facility.balanceOf(alice, id), 50);
    assertEq(debt.balanceOf(bob), 50);
  }

  function test_RevertWhen_Withdraw_NotOperator() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSignature("InsufficientPermission()"));
    facility.withdraw(id, alice, bob, 50);
  }

  function test_RevertWhen_Withdraw_InsufficientBalance() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
    facility.withdraw(id, alice, alice, 101);
  }

  function test_RevertWhen_Withdraw_AsOperator_InsufficientBalance() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    vm.prank(alice);
    facility.setOperator(operator, true);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
    facility.withdraw(id, alice, bob, 101);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CLAIM TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Claim_FromSelf() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    uint256 shares = facility.balanceOf(alice, id);
    assertEq(shares, 100);

    vm.prank(alice);
    facility.claim(id, alice, alice, shares);

    assertEq(facility.balanceOf(alice, id), 0);
    assertEq(debt.balanceOf(alice), 100);
  }

  function test_Claim_FromSelfToReceiver() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    uint256 shares = facility.balanceOf(alice, id);

    vm.prank(alice);
    facility.claim(id, alice, bob, shares);

    assertEq(facility.balanceOf(alice, id), 0);
    assertEq(debt.balanceOf(bob), 100);
  }

  function test_Claim_AsOperator() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    // alice sets operator as an operator
    vm.prank(alice);
    facility.setOperator(operator, true);

    facility.lock(id);
    facility.resolve(id);

    uint256 shares = facility.balanceOf(alice, id);
    assertEq(shares, 100);

    // operator claims on behalf of alice to bob
    vm.prank(operator);
    facility.claim(id, alice, bob, shares);

    assertEq(facility.balanceOf(alice, id), 0);
    assertEq(debt.balanceOf(bob), 100);
  }

  function test_RevertWhen_Claim_NotOperator() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    uint256 shares = facility.balanceOf(alice, id);

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSignature("InsufficientPermission()"));
    facility.claim(id, alice, bob, shares);
  }

  function test_RevertWhen_Claim_InsufficientBalance() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
    facility.claim(id, alice, alice, 101);
  }

  function test_RevertWhen_Claim_AsOperator_InsufficientBalance() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    vm.prank(alice);
    facility.setOperator(operator, true);

    facility.lock(id);
    facility.resolve(id);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
    facility.claim(id, alice, bob, 101);
  }

  function test_Claim_ZeroShares() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    uint256 sharesBefore = facility.balanceOf(alice, id);

    vm.prank(alice);
    facility.claim(id, alice, alice, 0);

    // Nothing should change
    assertEq(facility.balanceOf(alice, id), sharesBefore);
    assertEq(debt.balanceOf(alice), 0);
  }

  function test_Claim_PartialShares() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    vm.prank(alice);
    facility.claim(id, alice, alice, 40);

    assertEq(facility.balanceOf(alice, id), 60);
    assertEq(debt.balanceOf(alice), 40);

    vm.prank(alice);
    facility.claim(id, alice, alice, 60);

    assertEq(facility.balanceOf(alice, id), 0);
    assertEq(debt.balanceOf(alice), 100);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 CLAIM RETURN VALUES TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_Claim_ReturnsTokensAndAmounts() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    uint256 shares = facility.balanceOf(alice, id);

    vm.prank(alice);
    (address[] memory tokens, uint256[] memory amounts) = facility.claim(id, alice, alice, shares);

    // Verify return values
    assertEq(tokens.length, 1, "Should return 1 token");
    assertEq(amounts.length, 1, "Should return 1 amount");
    assertEq(tokens[0], address(debt), "Token should be debt token");
    assertEq(amounts[0], 100, "Amount should be 100");

    // Verify actual transfer happened
    assertEq(debt.balanceOf(alice), 100, "Alice should have received 100 debt tokens");
  }

  function test_Claim_ReturnsCorrectPartialAmounts() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    // Claim partial shares
    vm.prank(alice);
    (address[] memory tokens, uint256[] memory amounts) = facility.claim(id, alice, alice, 40);

    assertEq(tokens.length, 1);
    assertEq(amounts.length, 1);
    assertEq(tokens[0], address(debt));
    assertEq(amounts[0], 40, "Should return 40 for 40% of shares");

    // Claim remaining
    vm.prank(alice);
    (tokens, amounts) = facility.claim(id, alice, alice, 60);

    assertEq(amounts[0], 60, "Should return 60 for remaining 60% of shares");
  }

  function test_Claim_ZeroSharesReturnsEmptyArrays() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    vm.prank(alice);
    (address[] memory tokens, uint256[] memory amounts) = facility.claim(id, alice, alice, 0);

    assertEq(tokens.length, 0, "Should return empty tokens array for 0 shares");
    assertEq(amounts.length, 0, "Should return empty amounts array for 0 shares");
  }

  function test_Claim_ReturnValuesMatchActualTransfers() public {
    uint256 id = _createIntent();
    _deposit(alice, id, 100);

    facility.lock(id);
    facility.resolve(id);

    uint256 aliceBalanceBefore = debt.balanceOf(alice);

    vm.prank(alice);
    (address[] memory tokens, uint256[] memory amounts) = facility.claim(id, alice, alice, 50);

    uint256 aliceBalanceAfter = debt.balanceOf(alice);

    // Verify return values match actual transfer
    assertEq(tokens[0], address(debt));
    assertEq(amounts[0], aliceBalanceAfter - aliceBalanceBefore, "Return amount should match actual transfer");
  }
}
