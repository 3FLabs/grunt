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

  /// @notice Adds an amount to a token's balance in the map, inserting the key if missing.
  /// @dev Reads `_values` directly instead of tryGet to avoid an unnecessary contains() check.
  function add(EnumerableMapLib.AddressToUint256Map storage _balances, address token, uint256 amount) internal {
    _balances.set(token, _balances._values[token] + amount);
  }

  /// @notice Subtracts an amount from a token's balance in the map.
  /// @dev Reverts with InsufficientBalance if the current balance is less than the amount.
  ///      Removes the token entry from the map when the resulting balance is zero (callers
  ///      reading `_values` directly rely on a removed key returning 0).
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
