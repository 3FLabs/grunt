// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
  string internal _name;
  string internal _symbol;
  uint8 internal immutable _decimals;

  constructor(string memory name_, string memory symbol_, uint8 decimals_) {
    _name = name_;
    _symbol = symbol_;
    _decimals = decimals_;
  }

  function name() public view override returns (string memory) {
    return _name;
  }

  function symbol() public view override returns (string memory) {
    return _symbol;
  }

  function decimals() public view override returns (uint8) {
    return _decimals;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) external {
    _burn(from, amount);
  }

  function offchainRedeem(uint256) external pure {
    // No-op for tests. USCCFund only checks that this call does not revert.
  }
}
