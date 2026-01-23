// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";
import {LibTokenBalancesHarness} from "test/mock/libs/LibTokenBalancesHarness.sol";

/// @title LibTokenBalancesTest
/// @notice Tests for LibTokenBalances library
contract LibTokenBalancesTest is Test {
  LibTokenBalancesHarness harness;

  address constant TOKEN_A = address(0xA);
  address constant TOKEN_B = address(0xB);

  function setUp() public {
    harness = new LibTokenBalancesHarness();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ADD TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_add_newToken() public {
    harness.add(TOKEN_A, 100e18);

    (, uint256 amount) = harness.tryGet(TOKEN_A);
    assertEq(amount, 100e18, "Amount should be 100e18");
    assertEq(harness.length(), 1, "Should have 1 token");
  }

  function test_add_multipleTokens() public {
    harness.add(TOKEN_A, 100e18);
    harness.add(TOKEN_B, 200e18);

    (, uint256 amountA) = harness.tryGet(TOKEN_A);
    (, uint256 amountB) = harness.tryGet(TOKEN_B);

    assertEq(amountA, 100e18);
    assertEq(amountB, 200e18);
    assertEq(harness.length(), 2, "Should have 2 tokens");
  }

  function test_add_zeroAmount() public {
    harness.add(TOKEN_A, 0);

    // Adding zero to non-existent token creates entry with 0
    (bool exists, uint256 amount) = harness.tryGet(TOKEN_A);
    assertTrue(exists, "Token should exist");
    assertEq(amount, 0, "Amount should be 0");
  }

  function testFuzz_add_amounts(address token, uint128 amount1, uint128 amount2) public {
    vm.assume(uint160(token) > type(uint152).max); // Avoid zero sentinel issues

    harness.add(token, amount1);
    harness.add(token, amount2);

    (, uint256 total) = harness.tryGet(token);
    assertEq(total, uint256(amount1) + uint256(amount2), "Total should be sum of amounts");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         SUB TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_sub_revertOnNonExistentToken() public {
    vm.expectRevert(LibCommonErrors.InsufficientBalance.selector);
    harness.sub(TOKEN_A, 1);
  }

  function test_sub_zeroAmount() public {
    harness.add(TOKEN_A, 100e18);
    harness.sub(TOKEN_A, 0);

    (, uint256 amount) = harness.tryGet(TOKEN_A);
    assertEq(amount, 100e18, "Amount should be unchanged");
  }

  function testFuzz_sub_validAmounts(address token, uint128 initial, uint128 subtractAmount) public {
    vm.assume(uint160(token) > type(uint152).max); // Avoid zero sentinel issues
    vm.assume(initial >= subtractAmount);

    harness.add(token, initial);
    harness.sub(token, subtractAmount);

    (, uint256 remaining) = harness.tryGet(token);
    uint256 expected = uint256(initial) - uint256(subtractAmount);
    assertEq(remaining, expected, "Remaining should be initial - subtracted");

    // Verify removal behavior
    if (expected == 0) {
      assertEq(harness.length(), 0, "Should be removed when zero");
    } else {
      assertEq(harness.length(), 1, "Should still exist when non-zero");
    }
  }

  function testFuzz_sub_revertOnInsufficientBalance(address token, uint128 initial, uint128 subtractAmount) public {
    // Filter out addresses that are zero or could be zero sentinels used by EnumerableMapLib
    vm.assume(uint160(token) > type(uint152).max);
    vm.assume(subtractAmount > initial);

    harness.add(token, initial);

    vm.expectRevert(LibCommonErrors.InsufficientBalance.selector);
    harness.sub(token, subtractAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      COMBINED TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_addAndSub_multipleTokens() public {
    harness.add(TOKEN_A, 100e18);
    harness.add(TOKEN_B, 200e18);

    harness.sub(TOKEN_A, 100e18); // Remove TOKEN_A
    harness.sub(TOKEN_B, 50e18); // Partial subtract from TOKEN_B

    (bool existsA,) = harness.tryGet(TOKEN_A);
    (, uint256 amountB) = harness.tryGet(TOKEN_B);

    assertFalse(existsA, "TOKEN_A should be removed");
    assertEq(amountB, 150e18, "TOKEN_B should have 150e18");
    assertEq(harness.length(), 1, "Should have 1 token");
  }

  function testFuzz_addAndSub_roundtrip(address token, uint128 amount) public {
    vm.assume(uint160(token) > type(uint152).max); // Avoid zero sentinel issues
    vm.assume(amount > 0);

    harness.add(token, amount);
    harness.sub(token, amount);

    (bool exists,) = harness.tryGet(token);
    assertFalse(exists, "Token should be removed after full subtraction");
    assertEq(harness.length(), 0, "Map should be empty");
  }
}
