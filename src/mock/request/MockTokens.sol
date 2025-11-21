// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ControlledToken} from "../../request/tokens/ControlledToken.sol";
import {TokenController} from "../../request/tokens/TokenController.sol";

contract MockControlledToken is ControlledToken {
  bool internal immutable IS_YT;
  address internal immutable CONTROLLER;

  constructor(address controller, bool isYt) {
    IS_YT = isYt;
    CONTROLLER = controller;
  }

  function _isYtToken() internal view override returns (bool) {
    return IS_YT;
  }

  function _controller() internal view override returns (address) {
    return CONTROLLER;
  }
}

contract MockTokenController is TokenController {
  address internal immutable PT_TOKEN;
  address internal immutable YT_TOKEN;

  string internal _name;
  string internal _symbol;
  uint8 internal immutable DECIMALS;

  constructor(string memory name_, string memory symbol_, uint8 decimals_) {
    PT_TOKEN = address(new MockControlledToken(address(this), false));
    YT_TOKEN = address(new MockControlledToken(address(this), true));
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

  function ptToken() public view override returns (address) {
    return PT_TOKEN;
  }

  function ytToken() public view override returns (address) {
    return YT_TOKEN;
  }

  function mint(address to, uint256 pt, uint256 yt) public {
    _mint(to, pt, yt);
  }

  function burn(address from, uint256 pt, uint256 yt) public {
    _burn(from, pt, yt);
  }
}
