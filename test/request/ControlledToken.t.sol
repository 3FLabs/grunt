// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockTokenController, ControlledToken, TokenController} from "../../src/mock/request/MockTokens.sol";

contract ControlledTokenTest is Test {
  MockTokenController public tokenController;
  ControlledToken public ptToken;
  ControlledToken public ytToken;

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Approval(address indexed owner, address indexed spender, uint256 amount);

  function setUp() public {
    tokenController = new MockTokenController("Token", "TKN", 18);
    ptToken = ControlledToken(tokenController.ptToken());
    ytToken = ControlledToken(tokenController.ytToken());
  }

  function test_name() public view {
    assertEq(ptToken.name(), "PT-Token");
    assertEq(ytToken.name(), "YT-Token");
  }

  function test_symbol() public view {
    assertEq(ptToken.symbol(), "PT-TKN");
    assertEq(ytToken.symbol(), "YT-TKN");
  }

  function test_decimals() public view {
    assertEq(ptToken.decimals(), 18);
    assertEq(ytToken.decimals(), 18);
  }

  function test_totalSupply() public {
    tokenController.mint(address(1), 1 ether, 2 ether);
    assertEq(ptToken.totalSupply(), 1 ether);
    assertEq(ytToken.totalSupply(), 2 ether);

    tokenController.mint(address(2), 3 ether, 4 ether);
    assertEq(ptToken.totalSupply(), 4 ether);
    assertEq(ytToken.totalSupply(), 6 ether);

    tokenController.mint(address(3), 5 ether, 6 ether);
    assertEq(ptToken.totalSupply(), 9 ether);
    assertEq(ytToken.totalSupply(), 12 ether);

    tokenController.burn(address(1), 1 ether, 2 ether);
    assertEq(ptToken.totalSupply(), 8 ether);
    assertEq(ytToken.totalSupply(), 10 ether);

    tokenController.burn(address(2), 3 ether, 4 ether);
    assertEq(ptToken.totalSupply(), 5 ether);
    assertEq(ytToken.totalSupply(), 6 ether);
  }

  function testFuzz_transferTokens(
    address from,
    address to,
    uint128 ptMint,
    uint128 ytMint,
    uint128 ptTransfer,
    uint128 ytTransfer
  ) public {
    vm.assume(from != address(0));
    vm.assume(to != address(0));
    vm.assume(from != to);

    tokenController.mint(from, ptMint, ytMint);

    bool success = true;

    vm.prank(from);
    if (ptTransfer > ptMint) {
      vm.expectRevert(TokenController.InsufficientBalance.selector);
      success = false;
    } else if (ptTransfer > 0) {
      vm.expectEmit(true, true, true, true, address(ptToken));
      emit Transfer(from, to, ptTransfer);
    }
    bool result = ptToken.transfer(to, ptTransfer);
    assertEq(result, success);

    if (success) {
      assertEq(ptToken.balanceOf(from), ptMint - ptTransfer);
      assertEq(ptToken.balanceOf(to), ptTransfer);
    } else {
      assertEq(ptToken.balanceOf(from), ptMint);
      assertEq(ptToken.balanceOf(to), 0);
      success = true;
    }

    vm.prank(from);
    if (ytTransfer > ytMint) {
      vm.expectRevert(TokenController.InsufficientBalance.selector);
      success = false;
    } else if (ytTransfer > 0) {
      vm.expectEmit(true, true, true, true, address(ytToken));
      emit Transfer(from, to, ytTransfer);
    }
    result = ytToken.transfer(to, ytTransfer);
    assertEq(result, success);

    if (success) {
      assertEq(ytToken.balanceOf(from), ytMint - ytTransfer);
      assertEq(ytToken.balanceOf(to), ytTransfer);
    } else {
      assertEq(ytToken.balanceOf(from), ytMint);
      assertEq(ytToken.balanceOf(to), 0);
    }
  }

  function test_approve() public {
    address owner = address(1);
    address spender = address(2);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(ptToken));
    emit Approval(owner, spender, 100 ether);
    bool result = ptToken.approve(spender, 100 ether);
    assertTrue(result);
    assertEq(ptToken.allowance(owner, spender), 100 ether);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(ytToken));
    emit Approval(owner, spender, 200 ether);
    result = ytToken.approve(spender, 200 ether);
    assertTrue(result);
    assertEq(ytToken.allowance(owner, spender), 200 ether);
  }

  function test_approveMaxAllowance() public {
    address owner = address(1);
    address spender = address(2);

    // Approve more than uint128 max should cap at uint128 max
    vm.prank(owner);
    ptToken.approve(spender, type(uint256).max);
    assertEq(ptToken.allowance(owner, spender), type(uint256).max);
  }

  function test_approveBatch() public {
    address owner = address(1);
    address spender = address(2);

    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(ptToken));
    emit Approval(owner, spender, 100 ether);
    vm.expectEmit(true, true, true, true, address(ytToken));
    emit Approval(owner, spender, 200 ether);
    bool result = tokenController.approveBatch(spender, 100 ether, 200 ether);
    assertTrue(result);

    assertEq(ptToken.allowance(owner, spender), 100 ether);
    assertEq(ytToken.allowance(owner, spender), 200 ether);
  }

  function test_transferFrom() public {
    address owner = address(1);
    address spender = address(2);
    address recipient = address(3);

    // Mint tokens to owner
    tokenController.mint(owner, 100 ether, 200 ether);

    // Approve spender
    vm.prank(owner);
    ptToken.approve(spender, 50 ether);

    // Transfer from owner to recipient
    vm.prank(spender);
    vm.expectEmit(true, true, true, true, address(ptToken));
    emit Transfer(owner, recipient, 30 ether);
    bool result = ptToken.transferFrom(owner, recipient, 30 ether);
    assertTrue(result);

    assertEq(ptToken.balanceOf(owner), 70 ether);
    assertEq(ptToken.balanceOf(recipient), 30 ether);
    assertEq(ptToken.allowance(owner, spender), 20 ether);
  }

  function test_transferFromInsufficientAllowance() public {
    address owner = address(1);
    address spender = address(2);
    address recipient = address(3);

    tokenController.mint(owner, 100 ether, 200 ether);

    vm.prank(owner);
    ptToken.approve(spender, 50 ether);

    vm.prank(spender);
    vm.expectRevert(TokenController.InsufficientAllowance.selector);
    ptToken.transferFrom(owner, recipient, 51 ether);
  }

  function test_transferFromMaxAllowance() public {
    address owner = address(1);
    address spender = address(2);
    address recipient = address(3);

    tokenController.mint(owner, 100 ether, 200 ether);

    // Approve max allowance (infinite approval) for both tokens using batch
    vm.prank(owner);
    tokenController.approveBatch(spender, type(uint256).max, type(uint256).max);

    assertEq(ptToken.allowance(owner, spender), type(uint256).max);
    assertEq(ytToken.allowance(owner, spender), type(uint256).max);

    // Transfer should not reduce allowance when both are max
    vm.prank(spender);
    ptToken.transferFrom(owner, recipient, 50 ether);

    assertEq(ptToken.allowance(owner, spender), type(uint256).max);
    assertEq(ptToken.balanceOf(recipient), 50 ether);

    // Try YT transfer too
    vm.prank(spender);
    ytToken.transferFrom(owner, recipient, 75 ether);

    assertEq(ytToken.allowance(owner, spender), type(uint256).max);
    assertEq(ytToken.balanceOf(recipient), 75 ether);
  }

  function test_transferFromPartialMaxAllowance() public {
    address owner = address(1);
    address spender = address(2);
    address recipient = address(3);

    tokenController.mint(owner, 100 ether, 200 ether);

    // Approve max allowance only for PT, limited for YT
    vm.prank(owner);
    tokenController.approveBatch(spender, type(uint256).max, 150 ether);

    assertEq(ptToken.allowance(owner, spender), type(uint256).max);
    assertEq(ytToken.allowance(owner, spender), 150 ether);

    // Transfer PT - allowance should still be reduced because YT is not max
    vm.prank(spender);
    ptToken.transferFrom(owner, recipient, 50 ether);

    // PT allowance is not reduced
    assertEq(ptToken.allowance(owner, spender), type(uint256).max);
    assertEq(ytToken.allowance(owner, spender), 150 ether);
  }

  function test_transferFromBatch() public {
    address owner = address(1);
    address spender = address(2);
    address recipient = address(3);

    tokenController.mint(owner, 100 ether, 200 ether);

    vm.prank(owner);
    tokenController.approveBatch(spender, 50 ether, 100 ether);

    vm.prank(spender);
    vm.expectEmit(true, true, true, true, address(ptToken));
    emit Transfer(owner, recipient, 30 ether);
    vm.expectEmit(true, true, true, true, address(ytToken));
    emit Transfer(owner, recipient, 60 ether);
    bool result = tokenController.transferFromBatch(owner, recipient, 30 ether, 60 ether);
    assertTrue(result);

    assertEq(ptToken.balanceOf(owner), 70 ether);
    assertEq(ytToken.balanceOf(owner), 140 ether);
    assertEq(ptToken.balanceOf(recipient), 30 ether);
    assertEq(ytToken.balanceOf(recipient), 60 ether);
    assertEq(ptToken.allowance(owner, spender), 20 ether);
    assertEq(ytToken.allowance(owner, spender), 40 ether);
  }

  function test_transferFromBatchInsufficientAllowance() public {
    address owner = address(1);
    address spender = address(2);
    address recipient = address(3);

    tokenController.mint(owner, 100 ether, 200 ether);

    vm.prank(owner);
    tokenController.approveBatch(spender, 50 ether, 100 ether);

    // Try to transfer more PT than allowed
    vm.prank(spender);
    vm.expectRevert(TokenController.InsufficientAllowance.selector);
    tokenController.transferFromBatch(owner, recipient, 51 ether, 60 ether);

    // Try to transfer more YT than allowed
    vm.prank(spender);
    vm.expectRevert(TokenController.InsufficientAllowance.selector);
    tokenController.transferFromBatch(owner, recipient, 30 ether, 101 ether);
  }

  function test_transferFromSelf() public {
    address owner = address(1);
    address recipient = address(2);

    tokenController.mint(owner, 100 ether, 200 ether);

    // Transfer from self should not require allowance
    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(ptToken));
    emit Transfer(owner, recipient, 50 ether);
    bool result = ptToken.transferFrom(owner, recipient, 50 ether);
    assertTrue(result);

    assertEq(ptToken.balanceOf(owner), 50 ether);
    assertEq(ptToken.balanceOf(recipient), 50 ether);
  }

  function testFuzz_approveAndTransferFrom(
    address owner,
    address spender,
    address recipient,
    uint128 ptMint,
    uint128 ytMint,
    uint128 ptApprove,
    uint128 ytApprove,
    uint128 ptTransfer,
    uint128 ytTransfer
  ) public {
    vm.assume(owner != address(0));
    vm.assume(spender != address(0));
    vm.assume(recipient != address(0));
    vm.assume(owner != spender);

    tokenController.mint(owner, ptMint, ytMint);

    vm.prank(owner);
    tokenController.approveBatch(spender, ptApprove, ytApprove);

    assertEq(ptToken.allowance(owner, spender), ptApprove < type(uint128).max ? ptApprove : type(uint256).max);
    assertEq(ytToken.allowance(owner, spender), ytApprove < type(uint128).max ? ytApprove : type(uint256).max);

    bool shouldSucceed =
      ptTransfer <= ptMint && ytTransfer <= ytMint && ptTransfer <= ptApprove && ytTransfer <= ytApprove;

    vm.prank(spender);
    if (!shouldSucceed) {
      vm.expectRevert();
      tokenController.transferFromBatch(owner, recipient, ptTransfer, ytTransfer);
    } else {
      bool result = tokenController.transferFromBatch(owner, recipient, ptTransfer, ytTransfer);
      assertTrue(result);

      assertEq(ptToken.balanceOf(owner), ptMint - ptTransfer);
      assertEq(ytToken.balanceOf(owner), ytMint - ytTransfer);
      assertEq(ptToken.balanceOf(recipient), ptTransfer);
      assertEq(ytToken.balanceOf(recipient), ytTransfer);

      // Check allowance reduction (unless max)
      if (ptApprove < type(uint128).max || ytApprove < type(uint128).max) {
        if (ptApprove < type(uint128).max) {
          assertEq(ptToken.allowance(owner, spender), ptApprove - ptTransfer);
        }
        if (ytApprove < type(uint128).max) {
          assertEq(ytToken.allowance(owner, spender), ytApprove - ytTransfer);
        }
      }
    }
  }

  function test_transferToSelf() public {
    address owner = address(1);

    tokenController.mint(owner, 100 ether, 200 ether);

    vm.prank(owner);
    vm.expectRevert(TokenController.TransferToSelf.selector);
    ptToken.transfer(owner, 50 ether);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      WORKFLOW TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_workflow_mintTransferBurn() public {
    address user1 = address(0x1);
    address user2 = address(0x2);

    // Mint tokens to user1
    tokenController.mint(user1, 100 ether, 200 ether);
    assertEq(ptToken.balanceOf(user1), 100 ether);
    assertEq(ytToken.balanceOf(user1), 200 ether);
    assertEq(ptToken.totalSupply(), 100 ether);
    assertEq(ytToken.totalSupply(), 200 ether);

    // Transfer PT to user2
    vm.prank(user1);
    ptToken.transfer(user2, 30 ether);
    assertEq(ptToken.balanceOf(user1), 70 ether);
    assertEq(ptToken.balanceOf(user2), 30 ether);

    // Transfer YT to user2
    vm.prank(user1);
    ytToken.transfer(user2, 50 ether);
    assertEq(ytToken.balanceOf(user1), 150 ether);
    assertEq(ytToken.balanceOf(user2), 50 ether);

    // Burn from both users
    tokenController.burn(user1, 20 ether, 50 ether);
    tokenController.burn(user2, 10 ether, 25 ether);

    assertEq(ptToken.balanceOf(user1), 50 ether);
    assertEq(ptToken.balanceOf(user2), 20 ether);
    assertEq(ytToken.balanceOf(user1), 100 ether);
    assertEq(ytToken.balanceOf(user2), 25 ether);
    assertEq(ptToken.totalSupply(), 70 ether);
    assertEq(ytToken.totalSupply(), 125 ether);
  }

  function test_workflow_approveTransferFromMultipleSpenders() public {
    address owner = address(0x1);
    address spender1 = address(0x2);
    address spender2 = address(0x3);
    address recipient = address(0x4);

    tokenController.mint(owner, 1000 ether, 2000 ether);

    // Approve multiple spenders
    vm.prank(owner);
    tokenController.approveBatch(spender1, 300 ether, 400 ether);
    vm.prank(owner);
    tokenController.approveBatch(spender2, 200 ether, 300 ether);

    // Spender1 transfers some PT
    vm.prank(spender1);
    ptToken.transferFrom(owner, recipient, 100 ether);
    assertEq(ptToken.balanceOf(recipient), 100 ether);
    assertEq(ptToken.allowance(owner, spender1), 200 ether);

    // Spender2 transfers some YT
    vm.prank(spender2);
    ytToken.transferFrom(owner, recipient, 150 ether);
    assertEq(ytToken.balanceOf(recipient), 150 ether);
    assertEq(ytToken.allowance(owner, spender2), 150 ether);

    // Verify owner balances
    assertEq(ptToken.balanceOf(owner), 900 ether);
    assertEq(ytToken.balanceOf(owner), 1850 ether);
  }

  function test_workflow_batchOperations() public {
    address user1 = address(0x1);
    address user2 = address(0x2);
    address user3 = address(0x3);

    // Mint to user1
    tokenController.mint(user1, 500 ether, 1000 ether);

    // User1 approves user2 for batch transfer
    vm.prank(user1);
    tokenController.approveBatch(user2, 200 ether, 400 ether);

    // User2 performs batch transfer from user1 to user3
    vm.prank(user2);
    tokenController.transferFromBatch(user1, user3, 150 ether, 300 ether);

    assertEq(ptToken.balanceOf(user1), 350 ether);
    assertEq(ytToken.balanceOf(user1), 700 ether);
    assertEq(ptToken.balanceOf(user3), 150 ether);
    assertEq(ytToken.balanceOf(user3), 300 ether);
    assertEq(ptToken.allowance(user1, user2), 50 ether);
    assertEq(ytToken.allowance(user1, user2), 100 ether);

    // User1 performs direct batch transfer
    vm.prank(user1);
    tokenController.transferBatch(user3, 100 ether, 200 ether);

    assertEq(ptToken.balanceOf(user1), 250 ether);
    assertEq(ytToken.balanceOf(user1), 500 ether);
    assertEq(ptToken.balanceOf(user3), 250 ether);
    assertEq(ytToken.balanceOf(user3), 500 ether);
  }

  function test_workflow_complexAllowanceScenario() public {
    address owner = address(0x1);
    address spender = address(0x2);
    address recipient1 = address(0x3);
    address recipient2 = address(0x4);

    tokenController.mint(owner, 1000 ether, 2000 ether);

    // Initial approval
    vm.prank(owner);
    tokenController.approveBatch(spender, 500 ether, 1000 ether);

    // First transfer
    vm.prank(spender);
    tokenController.transferFromBatch(owner, recipient1, 100 ether, 200 ether);

    // Increase allowance
    vm.prank(owner);
    tokenController.approveBatch(spender, 600 ether, 1200 ether);

    // Second transfer
    vm.prank(spender);
    tokenController.transferFromBatch(owner, recipient2, 200 ether, 400 ether);

    assertEq(ptToken.balanceOf(owner), 700 ether);
    assertEq(ytToken.balanceOf(owner), 1400 ether);
    assertEq(ptToken.balanceOf(recipient1), 100 ether);
    assertEq(ytToken.balanceOf(recipient1), 200 ether);
    assertEq(ptToken.balanceOf(recipient2), 200 ether);
    assertEq(ytToken.balanceOf(recipient2), 400 ether);
    assertEq(ptToken.allowance(owner, spender), 400 ether);
    assertEq(ytToken.allowance(owner, spender), 800 ether);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   COVERAGE IMPROVEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_emitApproval_unauthorized() public {
    address randomCaller = address(0x999);

    vm.prank(randomCaller);
    vm.expectRevert(ControlledToken.Unauthorized.selector);
    ptToken._emitApproval(address(1), address(2), 100 ether);

    vm.prank(randomCaller);
    vm.expectRevert(ControlledToken.Unauthorized.selector);
    ytToken._emitApproval(address(1), address(2), 100 ether);
  }

  function test_emitTransfer_unauthorized() public {
    address randomCaller = address(0x999);

    vm.prank(randomCaller);
    vm.expectRevert(ControlledToken.Unauthorized.selector);
    ptToken._emitTransfer(address(1), address(2), 100 ether);

    vm.prank(randomCaller);
    vm.expectRevert(ControlledToken.Unauthorized.selector);
    ytToken._emitTransfer(address(1), address(2), 100 ether);
  }

  function test_transfer_unauthorized() public {
    address randomCaller = address(0x999);
    address owner = address(1);
    address recipient = address(2);

    tokenController.mint(owner, 100 ether, 200 ether);

    // Try to call _transfer directly from a non-token contract
    vm.prank(randomCaller);
    vm.expectRevert(TokenController.UnauthorizedTokenContract.selector);
    tokenController._transfer(owner, owner, recipient, 50 ether, false);

    vm.prank(randomCaller);
    vm.expectRevert(TokenController.UnauthorizedTokenContract.selector);
    tokenController._transfer(owner, owner, recipient, 50 ether, true);
  }

  function test_approve_unauthorized() public {
    address randomCaller = address(0x999);
    address owner = address(1);
    address spender = address(2);

    // Try to call _approve directly from a non-token contract
    vm.prank(randomCaller);
    vm.expectRevert(TokenController.UnauthorizedTokenContract.selector);
    tokenController._approve(owner, spender, 100 ether, false);

    vm.prank(randomCaller);
    vm.expectRevert(TokenController.UnauthorizedTokenContract.selector);
    tokenController._approve(owner, spender, 100 ether, true);
  }

  function test_transferZeroAmount() public {
    address owner = address(1);
    address recipient = address(2);

    tokenController.mint(owner, 100 ether, 200 ether);

    // Transfer 0 PT - should succeed without emitting event
    vm.prank(owner);
    bool result = ptToken.transfer(recipient, 0);
    assertTrue(result);
    assertEq(ptToken.balanceOf(owner), 100 ether);
    assertEq(ptToken.balanceOf(recipient), 0);

    // Transfer 0 YT
    vm.prank(owner);
    result = ytToken.transfer(recipient, 0);
    assertTrue(result);
    assertEq(ytToken.balanceOf(owner), 200 ether);
    assertEq(ytToken.balanceOf(recipient), 0);
  }

  function test_mintZeroAmount() public {
    address user = address(1);

    // Mint 0 PT only
    tokenController.mint(user, 0, 100 ether);
    assertEq(ptToken.balanceOf(user), 0);
    assertEq(ytToken.balanceOf(user), 100 ether);

    // Mint 0 YT only
    tokenController.mint(user, 50 ether, 0);
    assertEq(ptToken.balanceOf(user), 50 ether);
    assertEq(ytToken.balanceOf(user), 100 ether);

    // Mint both 0
    tokenController.mint(user, 0, 0);
    assertEq(ptToken.balanceOf(user), 50 ether);
    assertEq(ytToken.balanceOf(user), 100 ether);
  }

  function test_burnZeroAmount() public {
    address user = address(1);
    tokenController.mint(user, 100 ether, 200 ether);

    // Burn 0 PT only
    tokenController.burn(user, 0, 50 ether);
    assertEq(ptToken.balanceOf(user), 100 ether);
    assertEq(ytToken.balanceOf(user), 150 ether);

    // Burn 0 YT only
    tokenController.burn(user, 25 ether, 0);
    assertEq(ptToken.balanceOf(user), 75 ether);
    assertEq(ytToken.balanceOf(user), 150 ether);

    // Burn both 0
    tokenController.burn(user, 0, 0);
    assertEq(ptToken.balanceOf(user), 75 ether);
    assertEq(ytToken.balanceOf(user), 150 ether);
  }

  function test_burnInsufficientSupply() public {
    address user = address(1);
    tokenController.mint(user, 100 ether, 200 ether);

    // Try to burn more PT than supply
    vm.expectRevert(TokenController.InsufficientBalance.selector);
    tokenController.burn(user, 101 ether, 0);

    // Try to burn more YT than supply
    vm.expectRevert(TokenController.InsufficientBalance.selector);
    tokenController.burn(user, 0, 201 ether);
  }

  function test_burnInsufficientBalance() public {
    address user1 = address(1);
    address user2 = address(2);

    tokenController.mint(user1, 50 ether, 100 ether);
    tokenController.mint(user2, 50 ether, 100 ether);

    // Total supply is 100 PT, 200 YT
    // user1 has 50 PT, 100 YT
    // Try to burn more than user1's balance but within supply
    vm.expectRevert(TokenController.InsufficientBalance.selector);
    tokenController.burn(user1, 51 ether, 0);

    vm.expectRevert(TokenController.InsufficientBalance.selector);
    tokenController.burn(user1, 0, 101 ether);
  }

  function test_transferBatchZeroAmounts() public {
    address owner = address(1);
    address recipient = address(2);

    tokenController.mint(owner, 100 ether, 200 ether);

    // Transfer only PT (YT = 0)
    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(ptToken));
    emit Transfer(owner, recipient, 50 ether);
    bool result = tokenController.transferBatch(recipient, 50 ether, 0);
    assertTrue(result);

    // Transfer only YT (PT = 0)
    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(ytToken));
    emit Transfer(owner, recipient, 100 ether);
    result = tokenController.transferBatch(recipient, 0, 100 ether);
    assertTrue(result);
  }

  function test_approveSameAllowance() public {
    address owner = address(1);
    address spender = address(2);

    // First approval
    vm.prank(owner);
    tokenController.approveBatch(spender, 100 ether, 200 ether);

    assertEq(ptToken.allowance(owner, spender), 100 ether);
    assertEq(ytToken.allowance(owner, spender), 200 ether);

    // Approve same amount again - no events should be emitted for unchanged allowances
    vm.prank(owner);
    tokenController.approveBatch(spender, 100 ether, 200 ether);

    assertEq(ptToken.allowance(owner, spender), 100 ether);
    assertEq(ytToken.allowance(owner, spender), 200 ether);
  }

  function test_balancesOf() public {
    address user = address(1);

    tokenController.mint(user, 100 ether, 200 ether);

    (uint128 ptBal, uint128 ytBal) = tokenController.balancesOf(user);
    assertEq(ptBal, 100 ether);
    assertEq(ytBal, 200 ether);
  }

  function test_totalSupplies() public {
    tokenController.mint(address(1), 100 ether, 200 ether);
    tokenController.mint(address(2), 50 ether, 75 ether);

    (uint128 ptSupply, uint128 ytSupply) = tokenController.totalSupplies();
    assertEq(ptSupply, 150 ether);
    assertEq(ytSupply, 275 ether);
  }

  function test_allowancesOf() public {
    address owner = address(1);
    address spender = address(2);

    vm.prank(owner);
    tokenController.approveBatch(spender, 100 ether, 200 ether);

    (uint128 ptAllowance, uint128 ytAllowance) = tokenController.allowancesOf(owner, spender);
    assertEq(ptAllowance, 100 ether);
    assertEq(ytAllowance, 200 ether);
  }

  function test_totalSupplyIndividual() public {
    tokenController.mint(address(1), 100 ether, 200 ether);

    assertEq(tokenController.totalSupply(false), 100 ether); // PT
    assertEq(tokenController.totalSupply(true), 200 ether);  // YT
  }

  function test_balanceOfIndividual() public {
    address user = address(1);
    tokenController.mint(user, 100 ether, 200 ether);

    assertEq(tokenController.balanceOf(user, false), 100 ether); // PT
    assertEq(tokenController.balanceOf(user, true), 200 ether);  // YT
  }

  function test_allowanceWithMaxValue() public {
    address owner = address(1);
    address spender = address(2);

    // Set max allowance
    vm.prank(owner);
    tokenController.approveBatch(spender, type(uint128).max, type(uint128).max);

    // Should return uint256 max when uint128 max is stored
    assertEq(tokenController.allowance(owner, spender, false), type(uint256).max);
    assertEq(tokenController.allowance(owner, spender, true), type(uint256).max);
  }

  function test_transferFromBatchSelf() public {
    address owner = address(1);
    address recipient = address(2);

    tokenController.mint(owner, 100 ether, 200 ether);

    // Transfer from self should not require allowance
    vm.prank(owner);
    vm.expectEmit(true, true, true, true, address(ptToken));
    emit Transfer(owner, recipient, 50 ether);
    vm.expectEmit(true, true, true, true, address(ytToken));
    emit Transfer(owner, recipient, 100 ether);
    bool result = tokenController.transferFromBatch(owner, recipient, 50 ether, 100 ether);
    assertTrue(result);

    assertEq(ptToken.balanceOf(owner), 50 ether);
    assertEq(ytToken.balanceOf(owner), 100 ether);
    assertEq(ptToken.balanceOf(recipient), 50 ether);
    assertEq(ytToken.balanceOf(recipient), 100 ether);
  }
}
