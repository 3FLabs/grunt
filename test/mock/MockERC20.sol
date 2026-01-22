// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
  string internal _name;
  string internal _symbol;
  uint8 internal immutable DECIMALS;

  constructor(string memory name_, string memory symbol_, uint8 decimals_) {
    _name = name_;
    _symbol = symbol_;
    DECIMALS = decimals_;
  }

  function name() public view override returns (string memory) {
    return _name;
  }

  function symbol() public view override returns (string memory) {
    return _symbol;
  }

  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) public {
    _burn(from, amount);
  }

  function setBalance(address account, uint256 amount) public {
    uint256 currentBalance = balanceOf(account);
    if (amount > currentBalance) {
      _mint(account, amount - currentBalance);
    } else if (amount < currentBalance) {
      _burn(account, currentBalance - amount);
    }
  }
}

