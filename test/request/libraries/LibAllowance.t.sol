// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAllowance} from "../../../src/libs/request/LibAllowance.sol";

contract LibAllowanceTest is Test {
  using LibAllowance for uint128;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FIXTURES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // Fixtures for consume function - allowance parameter
  uint128[] public fixtureAllowance = [
    0, // Zero allowance
    1000, // Normal allowance
    1e30, // Large value
    type(uint128).max - 1, // Almost max
    type(uint128).max // Max (infinite approval)
  ];

  // Fixtures for consume function - amount parameter
  uint128[] public fixtureAmount = [
    0, // Zero amount
    100, // Small amount
    500, // Medium amount
    1000, // Exact match with normal allowance
    type(uint128).max // Max amount
  ];

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSUME TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_consume(uint128 allowance, uint128 amount) public pure {
    vm.assume(allowance >= amount); // Assume valid consumption (as per the library comment)

    uint128 result = LibAllowance.consume(allowance, amount);

    if (allowance == type(uint128).max) {
      // Max allowance should never be consumed (infinite approval)
      assertEq(result, type(uint128).max, "Max allowance should not be consumed");
    } else {
      // Normal allowance should be consumed
      assertEq(result, allowance - amount, "Allowance should be consumed by amount");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      NORMALIZE TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_normalize(uint128 allowance) public pure {
    uint256 result = LibAllowance.normalize(allowance);

    if (allowance == type(uint128).max) {
      // Max uint128 should become max uint256 (infinite approval)
      assertEq(result, type(uint256).max, "Max allowance should normalize to max uint256");
    } else {
      // Other values should remain unchanged (just cast to uint256)
      assertEq(result, uint256(allowance), "Normal allowance should remain unchanged");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTEGRATION TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_consumeAndNormalize(uint128 allowance, uint128 amount) public pure {
    vm.assume(allowance >= amount);

    uint128 consumed = LibAllowance.consume(allowance, amount);
    uint256 normalized = LibAllowance.normalize(consumed);

    if (allowance == type(uint128).max) {
      assertEq(consumed, type(uint128).max);
      assertEq(normalized, type(uint256).max);
    } else {
      assertEq(consumed, allowance - amount);
      assertEq(normalized, uint256(allowance - amount));
    }
  }

  function testFuzz_multipleConsumes(uint128 initialAllowance, uint128 amount1, uint128 amount2, uint128 amount3)
    public
    pure
  {
    vm.assume(initialAllowance >= amount1);

    uint128 allowance = initialAllowance;
    bool isMaxAllowance = (allowance == type(uint128).max);

    // First consumption
    allowance = LibAllowance.consume(allowance, amount1);
    if (isMaxAllowance) {
      assertEq(allowance, type(uint128).max);
    } else {
      assertEq(allowance, initialAllowance - amount1);
      vm.assume(allowance >= amount2);
    }

    // Second consumption
    uint128 beforeSecond = allowance;
    allowance = LibAllowance.consume(allowance, amount2);
    if (isMaxAllowance) {
      assertEq(allowance, type(uint128).max);
    } else {
      assertEq(allowance, beforeSecond - amount2);
      vm.assume(allowance >= amount3);
    }

    // Third consumption
    uint128 beforeThird = allowance;
    allowance = LibAllowance.consume(allowance, amount3);
    if (isMaxAllowance) {
      assertEq(allowance, type(uint128).max);
    } else {
      assertEq(allowance, beforeThird - amount3);
    }
  }
}
