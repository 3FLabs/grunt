// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Order, Mode, LibOrder} from "src/libs/funds/Order.sol";

/// @title LibOrderTest
/// @notice Fuzz test for LibOrder library
contract LibOrderTest is Test {
  using LibOrder for Order;

  /// @notice Verifies the optimized assembly implementation matches the naive abi.encode approach
  function testFuzz_toId_MatchesNaiveImplementation(
    bool isRedeem,
    address owner,
    address receiver,
    uint256 input,
    uint256 output,
    bytes32 salt,
    address fund
  ) public view {
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
