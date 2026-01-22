// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibTokenController} from "../../../src/libs/request/LibTokenController.sol";

contract LibTokenControllerTest is Test {
  using LibTokenController for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    TOTAL SUPPLY TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_totalSupply(uint128 pt, uint128 yt) public {
    // Update total supply
    LibTokenController.updateTotalSupply(pt, yt);

    // Read back individual values
    uint128 ptResult = LibTokenController.totalSupply(false);
    uint128 ytResult = LibTokenController.totalSupply(true);

    assertEq(ptResult, pt, "PT total supply should match");
    assertEq(ytResult, yt, "YT total supply should match");
  }

  function testFuzz_totalSupplies(uint128 pt, uint128 yt) public {
    // Update total supply
    LibTokenController.updateTotalSupply(pt, yt);

    // Read back both values at once
    (uint128 ptResult, uint128 ytResult) = LibTokenController.totalSupplies();

    assertEq(ptResult, pt, "PT total supply should match");
    assertEq(ytResult, yt, "YT total supply should match");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      BALANCE TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_balances(address account, uint128 pt, uint128 yt) public {
    vm.assume(account != address(0));

    // Update balance
    account.updateBalances(pt, yt);

    // Read back individual values
    uint128 ptResult = account.balanceOf(false);
    uint128 ytResult = account.balanceOf(true);

    assertEq(ptResult, pt, "PT balance should match");
    assertEq(ytResult, yt, "YT balance should match");

    // Read back both values at once
    (uint128 ptBoth, uint128 ytBoth) = account.balances();
    assertEq(ptBoth, pt, "PT balance (batch) should match");
    assertEq(ytBoth, yt, "YT balance (batch) should match");
  }

  function testFuzz_balances_overwrite(address account, uint128 pt1, uint128 yt1, uint128 pt2, uint128 yt2) public {
    vm.assume(account != address(0));

    // Set initial balance
    account.updateBalances(pt1, yt1);
    (uint128 ptRead, uint128 ytRead) = account.balances();
    assertEq(ptRead, pt1);
    assertEq(ytRead, yt1);

    // Overwrite with new balance
    account.updateBalances(pt2, yt2);
    (ptRead, ytRead) = account.balances();
    assertEq(ptRead, pt2);
    assertEq(ytRead, yt2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     ALLOWANCE TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_allowances(address owner, address spender, uint128 pt, uint128 yt) public {
    vm.assume(owner != address(0));
    vm.assume(spender != address(0));

    // Update allowance
    owner.updateAllowance(spender, pt, yt);

    // Read back individual values
    uint128 ptResult = owner.allowance(spender, false);
    uint128 ytResult = owner.allowance(spender, true);

    assertEq(ptResult, pt, "PT allowance should match");
    assertEq(ytResult, yt, "YT allowance should match");

    // Read back both values at once
    (uint128 ptBoth, uint128 ytBoth) = owner.allowances(spender);
    assertEq(ptBoth, pt, "PT allowance (batch) should match");
    assertEq(ytBoth, yt, "YT allowance (batch) should match");
  }

  function testFuzz_allowances_overwrite(
    address owner,
    address spender,
    uint128 pt1,
    uint128 yt1,
    uint128 pt2,
    uint128 yt2
  ) public {
    vm.assume(owner != address(0));
    vm.assume(spender != address(0));

    // Set initial allowance
    owner.updateAllowance(spender, pt1, yt1);
    (uint128 ptRead, uint128 ytRead) = owner.allowances(spender);
    assertEq(ptRead, pt1);
    assertEq(ytRead, yt1);

    // Overwrite with new allowance
    owner.updateAllowance(spender, pt2, yt2);
    (ptRead, ytRead) = owner.allowances(spender);
    assertEq(ptRead, pt2);
    assertEq(ytRead, yt2);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTEGRATION TESTS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_isolatedStorage_totalSupplyAndBalances(
    address account1,
    address account2,
    uint128 totalPt,
    uint128 totalYt,
    uint128 balance1Pt,
    uint128 balance1Yt,
    uint128 balance2Pt,
    uint128 balance2Yt
  ) public {
    vm.assume(account1 != address(0) && account2 != address(0));
    vm.assume(account1 != account2);

    // Set total supply
    LibTokenController.updateTotalSupply(totalPt, totalYt);

    // Set balances for two accounts
    account1.updateBalances(balance1Pt, balance1Yt);
    account2.updateBalances(balance2Pt, balance2Yt);

    // Verify all values are independent and correct
    (uint128 totalPtRead, uint128 totalYtRead) = LibTokenController.totalSupplies();
    assertEq(totalPtRead, totalPt, "Total PT should match");
    assertEq(totalYtRead, totalYt, "Total YT should match");

    (uint128 bal1Pt, uint128 bal1Yt) = account1.balances();
    assertEq(bal1Pt, balance1Pt, "Account1 PT balance should match");
    assertEq(bal1Yt, balance1Yt, "Account1 YT balance should match");

    (uint128 bal2Pt, uint128 bal2Yt) = account2.balances();
    assertEq(bal2Pt, balance2Pt, "Account2 PT balance should match");
    assertEq(bal2Yt, balance2Yt, "Account2 YT balance should match");
  }

  function testFuzz_isolatedStorage_allowances(
    address owner,
    address spender1,
    address spender2,
    uint128 allow1Pt,
    uint128 allow1Yt,
    uint128 allow2Pt,
    uint128 allow2Yt
  ) public {
    vm.assume(owner != address(0));
    vm.assume(spender1 != address(0) && spender2 != address(0));
    vm.assume(spender1 != spender2);

    // Set allowances
    owner.updateAllowance(spender1, allow1Pt, allow1Yt);
    owner.updateAllowance(spender2, allow2Pt, allow2Yt);

    // Verify allowances are independent
    (uint128 allow1PtRead, uint128 allow1YtRead) = owner.allowances(spender1);
    assertEq(allow1PtRead, allow1Pt, "Spender1 PT allowance should match");
    assertEq(allow1YtRead, allow1Yt, "Spender1 YT allowance should match");

    (uint128 allow2PtRead, uint128 allow2YtRead) = owner.allowances(spender2);
    assertEq(allow2PtRead, allow2Pt, "Spender2 PT allowance should match");
    assertEq(allow2YtRead, allow2Yt, "Spender2 YT allowance should match");
  }

  function test_edgeCases_zeroAddress() public {
    // Test that zero address can be used (library doesn't validate)
    address zero = address(0);

    zero.updateBalances(100, 200);
    (uint128 pt, uint128 yt) = zero.balances();
    assertEq(pt, 100);
    assertEq(yt, 200);

    zero.updateAllowance(address(0x1), 300, 400);
    (pt, yt) = zero.allowances(address(0x1));
    assertEq(pt, 300);
    assertEq(yt, 400);
  }
}
