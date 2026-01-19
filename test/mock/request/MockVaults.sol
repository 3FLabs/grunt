// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ControlledVault} from "../../../src/request/abstract/vault/ControlledVault.sol";
import {VaultController} from "../../../src/request/abstract/vault/VaultController.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IERC20} from "../../../src/interfaces/integrations/IERC20.sol";

contract MockControlledVault is ControlledVault {
  using SafeTransferLib for address;

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

contract MockVaultController is VaultController {
  using SafeTransferLib for address;

  address internal immutable PT_VAULT;
  address internal immutable YT_VAULT;
  address internal immutable ASSET;

  string internal __name;
  string internal __symbol;
  uint8 internal immutable DECIMALS;

  bool internal __canWithdraw;

  constructor(address asset_, string memory name_, string memory symbol_) {
    ASSET = asset_;
    PT_VAULT = address(new MockControlledVault(address(this), false));
    YT_VAULT = address(new MockControlledVault(address(this), true));
    __name = name_;
    __symbol = symbol_;
    DECIMALS = IERC20(asset_).decimals();
    __canWithdraw = true; // Allow withdrawals by default
  }

  function name() external view returns (string memory) {
    return __name;
  }

  function symbol() external view returns (string memory) {
    return __symbol;
  }

  function decimals() external view returns (uint8) {
    return DECIMALS;
  }

  function _ptToken() internal view override returns (address) {
    return PT_VAULT;
  }

  function _ytToken() internal view override returns (address) {
    return YT_VAULT;
  }

  function _asset() internal view override returns (address) {
    return ASSET;
  }

  function _canWithdraw() internal view override returns (bool) {
    return __canWithdraw;
  }

  function _syncWithdrawalStatus() internal override returns (bool) {
    return __canWithdraw;
  }

  // Test helper functions
  function setCanWithdraw(bool canWithdraw_) public {
    __canWithdraw = canWithdraw_;
  }

  function deposit(address to, uint256 ptShares, uint256 ytShares) public {
    // Transfer assets from sender
    // Only transfer the principal assets
    uint256 totalAssets = ptShares;
    if (totalAssets > 0) {
      ASSET.safeTransferFrom(msg.sender, address(this), totalAssets);
    }

    // Mint PT and YT shares (1:1 for simplicity in tests)
    _mint(to, ptShares, ytShares);
  }
}

