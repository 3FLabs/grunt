// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {LibTokenBalances} from "src/libs/facility/LibTokenBalances.sol";

/// @dev Harness contract to expose internal library functions for testing
contract LibTokenBalancesHarness {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;

  EnumerableMapLib.AddressToUint256Map internal balances;

  function add(address token, uint256 amount) external {
    balances.add(token, amount);
  }

  function sub(address token, uint256 amount) external {
    balances.sub(token, amount);
  }

  function tryGet(address token) external view returns (bool exists, uint256 amount) {
    return balances.tryGet(token);
  }

  function length() external view returns (uint256) {
    return balances.length();
  }
}
