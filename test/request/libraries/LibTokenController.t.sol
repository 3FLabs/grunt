// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibTokenController} from "../../../src/request/libraries/LibTokenController.sol";

contract LibTokenControllerTest is Test {
  using LibTokenController for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FIXTURES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // Fixtures for uint128 values (pt and yt amounts)
  uint128[] public fixturePt = [
    0, // Zero
    1, // Minimum non-zero
    1000 ether, // Normal value
    1e30, // Large value
    type(uint128).max - 1, // Almost max
    type(uint128).max // Max value
  ];

  uint128[] public fixtureYt = [
    0, // Zero
    1, // Minimum non-zero
    2000 ether, // Normal value
    2e30, // Large value
    type(uint128).max - 1, // Almost max
    type(uint128).max // Max value
  ];

  // Fixtures for addresses
  address[] public fixtureAccount =
    [address(0x1), address(0x2), address(0x123456789), address(0xdEaD), address(type(uint160).max)];

  address[] public fixtureOwner = [address(0x1), address(0x2), address(0x999)];

  address[] public fixtureSpender = [address(0x3), address(0x4), address(0x888)];

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

  function test_totalSupply_storageLayout() public {
    // Test that PT is in lower 128 bits and YT is in upper 128 bits
    uint128 pt = 12345;
    uint128 yt = 67890;

    LibTokenController.updateTotalSupply(pt, yt);

    (uint128 ptRead, uint128 ytRead) = LibTokenController.totalSupplies();
    assertEq(ptRead, pt);
    assertEq(ytRead, yt);

    // Update with max values to ensure no overflow
    LibTokenController.updateTotalSupply(type(uint128).max, type(uint128).max);
    (ptRead, ytRead) = LibTokenController.totalSupplies();
    assertEq(ptRead, type(uint128).max);
    assertEq(ytRead, type(uint128).max);
  }

  function test_totalSupply_independentUpdates() public {
    // Set initial values
    LibTokenController.updateTotalSupply(1000, 2000);

    // Update to new values
    LibTokenController.updateTotalSupply(3000, 4000);

    assertEq(LibTokenController.totalSupply(false), 3000);
    assertEq(LibTokenController.totalSupply(true), 4000);
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

  function test_balances_multipleAccounts() public {
    address account1 = address(0x1);
    address account2 = address(0x2);
    address account3 = address(0x3);

    // Set different balances for each account
    account1.updateBalances(100, 200);
    account2.updateBalances(300, 400);
    account3.updateBalances(500, 600);

    // Verify each account has correct balance
    (uint128 pt1, uint128 yt1) = account1.balances();
    assertEq(pt1, 100);
    assertEq(yt1, 200);

    (uint128 pt2, uint128 yt2) = account2.balances();
    assertEq(pt2, 300);
    assertEq(yt2, 400);

    (uint128 pt3, uint128 yt3) = account3.balances();
    assertEq(pt3, 500);
    assertEq(yt3, 600);
  }

  function test_balances_storageLayout() public {
    address account = address(0x123);

    // Test PT and YT are stored independently
    account.updateBalances(type(uint128).max, 0);
    assertEq(account.balanceOf(false), type(uint128).max);
    assertEq(account.balanceOf(true), 0);

    account.updateBalances(0, type(uint128).max);
    assertEq(account.balanceOf(false), 0);
    assertEq(account.balanceOf(true), type(uint128).max);

    account.updateBalances(type(uint128).max, type(uint128).max);
    assertEq(account.balanceOf(false), type(uint128).max);
    assertEq(account.balanceOf(true), type(uint128).max);
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

  function test_allowances_multipleSpenders() public {
    address owner = address(0x1);
    address spender1 = address(0x2);
    address spender2 = address(0x3);
    address spender3 = address(0x4);

    // Set different allowances for each spender
    owner.updateAllowance(spender1, 100, 200);
    owner.updateAllowance(spender2, 300, 400);
    owner.updateAllowance(spender3, 500, 600);

    // Verify each spender has correct allowance
    (uint128 pt1, uint128 yt1) = owner.allowances(spender1);
    assertEq(pt1, 100);
    assertEq(yt1, 200);

    (uint128 pt2, uint128 yt2) = owner.allowances(spender2);
    assertEq(pt2, 300);
    assertEq(yt2, 400);

    (uint128 pt3, uint128 yt3) = owner.allowances(spender3);
    assertEq(pt3, 500);
    assertEq(yt3, 600);
  }

  function test_allowances_multipleOwners() public {
    address owner1 = address(0x1);
    address owner2 = address(0x2);
    address spender = address(0x3);

    // Set different allowances from different owners
    owner1.updateAllowance(spender, 100, 200);
    owner2.updateAllowance(spender, 300, 400);

    // Verify each owner's allowance is independent
    (uint128 pt1, uint128 yt1) = owner1.allowances(spender);
    assertEq(pt1, 100);
    assertEq(yt1, 200);

    (uint128 pt2, uint128 yt2) = owner2.allowances(spender);
    assertEq(pt2, 300);
    assertEq(yt2, 400);
  }

  function test_allowances_storageLayout() public {
    address owner = address(0x111);
    address spender = address(0x222);

    // Test PT and YT are stored independently
    owner.updateAllowance(spender, type(uint128).max, 0);
    assertEq(owner.allowance(spender, false), type(uint128).max);
    assertEq(owner.allowance(spender, true), 0);

    owner.updateAllowance(spender, 0, type(uint128).max);
    assertEq(owner.allowance(spender, false), 0);
    assertEq(owner.allowance(spender, true), type(uint128).max);

    owner.updateAllowance(spender, type(uint128).max, type(uint128).max);
    assertEq(owner.allowance(spender, false), type(uint128).max);
    assertEq(owner.allowance(spender, true), type(uint128).max);
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

