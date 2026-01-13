// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

library TokenBalancesLib {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

  error InsufficientBalance();

  function add(EnumerableMapLib.AddressToUint256Map storage _balances, address token, uint256 amount) internal {
    _balances.set(token, _balances.get(token) + amount);
  }

  function sub(EnumerableMapLib.AddressToUint256Map storage _balances, address token, uint256 amount) internal {
    unchecked {
      uint256 currentAmount = _balances.get(token);
      if (currentAmount < amount) revert InsufficientBalance();
      uint256 result = currentAmount - amount;
      if (result == 0) {
        _balances.remove(token);
      } else {
        _balances.set(token, result);
      }
    }
  }
}
