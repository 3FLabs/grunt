// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";
import {IAllowlist} from "src/interfaces/integrations/superstate/IAllowlist.sol";

contract MockSuperstateToken is ERC20 {
  string internal _name;
  string internal _symbol;
  uint8 internal constant _DECIMALS = 6;

  address public allowlist;
  IERC20 public usdc;

  uint256 public lastOffchainRedeemAmount;
  address public lastOffchainRedeemer;

  bool internal _accountingPaused;

  constructor(string memory name_, string memory symbol_, address allowlist_, address usdc_) {
    _name = name_;
    _symbol = symbol_;
    allowlist = allowlist_;
    usdc = IERC20(usdc_);
  }

  function name() public view override returns (string memory) {
    return _name;
  }

  function symbol() public view override returns (string memory) {
    return _symbol;
  }

  function decimals() public pure override returns (uint8) {
    return _DECIMALS;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function allowlistV2() external view returns (address) {
    return allowlist;
  }

  function offchainRedeem(uint256 amount) external {
    require(!_accountingPaused, "AccountingIsPaused");
    lastOffchainRedeemAmount = amount;
    lastOffchainRedeemer = msg.sender;
    _burn(msg.sender, amount);
  }

  function accountingPaused() external view returns (bool) {
    return _accountingPaused;
  }

  function setAccountingPaused(bool paused) external {
    _accountingPaused = paused;
  }

  function isAllowed(address addr) public view returns (bool) {
    return IAllowlist(allowlist).isAddressAllowedForPrivateInstrument(addr, "USCC");
  }

  /// @dev Mirrors production USCC: transfers revert when sender or recipient is not on the allowlist.
  function _beforeTokenTransfer(address from, address to, uint256) internal view override {
    if (from != address(0) && !isAllowed(from)) revert("MockSuperstateToken: sender not allowed");
    if (to != address(0) && !isAllowed(to)) revert("MockSuperstateToken: recipient not allowed");
  }

  function simulateRedemptionComplete(address recipient, uint256 usdcAmount) external {
    usdc.transfer(recipient, usdcAmount);
  }
}
