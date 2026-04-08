// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {LibCommonErrors as CommonErrors} from "../common/LibCommonErrors.sol";

/// @title LibTokenBalances
/// @author 3F Protocol
/// @notice Library for managing token balance mappings with automatic cleanup.
/// @dev Provides add and subtract operations on an AddressToUint256Map, automatically
///      removing entries when balances reach zero to keep storage clean.
library LibTokenBalances {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

  /// @notice Adds an amount to a token's balance in the map.
  /// @dev If the token doesn't exist in the map, it will be added with the given amount.
  ///      If it exists, the amount is added to the current balance.
  ///      Uses direct mapping access instead of tryGet to avoid an unnecessary contains() check.
  /// @param _balances The storage reference to the balance map.
  /// @param token The token address to add balance for.
  /// @param amount The amount to add to the balance.
  function add(EnumerableMapLib.AddressToUint256Map storage _balances, address token, uint256 amount) internal {
    _balances.set(token, _balances._values[token] + amount);
  }

  /// @notice Subtracts an amount from a token's balance in the map.
  /// @dev Reverts with InsufficientBalance if the current balance is less than the amount.
  ///      Automatically removes the token entry from the map if the resulting balance is zero.
  ///      Uses direct mapping access instead of tryGet to avoid an unnecessary contains() check.
  /// @param _balances The storage reference to the balance map.
  /// @param token The token address to subtract balance from.
  /// @param amount The amount to subtract from the balance.
  function sub(EnumerableMapLib.AddressToUint256Map storage _balances, address token, uint256 amount) internal {
    unchecked {
      uint256 currentAmount = _balances._values[token];
      if (currentAmount < amount) revert CommonErrors.InsufficientBalance();
      uint256 result = currentAmount - amount;
      if (result == 0) {
        _balances.remove(token);
      } else {
        _balances.set(token, result);
      }
    }
  }
}
