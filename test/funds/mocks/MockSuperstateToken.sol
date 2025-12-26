// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {IERC20} from "src/interfaces/integrations/IERC20.sol";

contract MockSuperstateToken is ERC20 {
  string internal _name;
  string internal _symbol;
  uint8 internal constant _DECIMALS = 6;

  address public allowlist;
  IERC20 public usdc;

  uint256 public lastOffchainRedeemAmount;
  address public lastOffchainRedeemer;

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
    lastOffchainRedeemAmount = amount;
    lastOffchainRedeemer = msg.sender;
    _burn(msg.sender, amount);
  }

  function simulateRedemptionComplete(address recipient, uint256 usdcAmount) external {
    usdc.transfer(recipient, usdcAmount);
  }
}
