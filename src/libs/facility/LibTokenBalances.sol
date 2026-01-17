// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";
import {LibErrors} from "./LibErrors.sol";

library LibTokenBalances {
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

  function add(EnumerableMapLib.AddressToUint256Map storage _balances, address token, uint256 amount) internal {
    (, uint256 currentAmount) = _balances.tryGet(token);
    _balances.set(token, currentAmount + amount);
  }

  function sub(EnumerableMapLib.AddressToUint256Map storage _balances, address token, uint256 amount) internal {
    unchecked {
      uint256 currentAmount = _balances.get(token);
      if (currentAmount < amount) revert LibErrors.InsufficientBalance();
      uint256 result = currentAmount - amount;
      if (result == 0) {
        _balances.remove(token);
      } else {
        _balances.set(token, result);
      }
    }
  }
}
