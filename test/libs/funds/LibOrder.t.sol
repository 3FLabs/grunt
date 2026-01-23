// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Order, Mode, LibOrder} from "src/libs/funds/Order.sol";

/// @title LibOrderTest
/// @notice Fuzz test for LibOrder library
contract LibOrderTest is Test {
  using LibOrder for Order;

  /// @notice Verifies toId returns bytes32(0) for null orders (owner == address(0))
  function test_toId_returnsZeroForNullOrder() public {
    Order memory order = Order({
      mode: Mode.DEPOSIT,
      owner: address(0),
      receiver: address(0x123),
      input: 1000e18,
      output: 900e18,
      salt: bytes32(uint256(1))
    });

    bytes32 orderId = order.toId(address(0x456));
    assertEq(orderId, bytes32(0), "Null order should return zero ID");
  }

  /// @notice Fuzz test: verifies toId returns bytes32(0) for any null order
  function testFuzz_toId_returnsZeroForNullOrder(
    bool isRedeem,
    address receiver,
    uint256 input,
    uint256 output,
    bytes32 salt,
    address fund
  ) public {
    Order memory order = Order({
      mode: isRedeem ? Mode.REDEEM : Mode.DEPOSIT,
      owner: address(0), // null order
      receiver: receiver,
      input: input,
      output: output,
      salt: salt
    });

    bytes32 orderId = order.toId(fund);
    assertEq(orderId, bytes32(0), "Null order should always return zero ID");
  }

  /// @notice Verifies the optimized assembly implementation matches the naive abi.encode approach for non-null orders
  function testFuzz_toId_MatchesNaiveImplementation(
    bool isRedeem,
    address owner,
    address receiver,
    uint256 input,
    uint256 output,
    bytes32 salt,
    address fund
  ) public {
    vm.assume(owner != address(0)); // Skip null orders - they return bytes32(0) directly

    Order memory order = Order({
      mode: isRedeem ? Mode.REDEEM : Mode.DEPOSIT,
      owner: owner,
      receiver: receiver,
      input: input,
      output: output,
      salt: salt
    });

    bytes32 optimizedId = order.toId(fund);
    bytes32 naiveId = keccak256(abi.encode(block.chainid, fund, order));

    assertEq(optimizedId, naiveId);
  }
}
