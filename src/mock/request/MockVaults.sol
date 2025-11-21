// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ControlledVault} from "../../request/vault/ControlledVault.sol";
import {VaultController} from "../../request/vault/VaultController.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IERC20} from "../../integrations/interfaces/IERC20.sol";

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

  string internal _name;
  string internal _symbol;
  uint8 internal immutable DECIMALS;

  bool internal _canWithdraw;

  constructor(address asset_, string memory name_, string memory symbol_) {
    ASSET = asset_;
    PT_VAULT = address(new MockControlledVault(address(this), false));
    YT_VAULT = address(new MockControlledVault(address(this), true));
    _name = name_;
    _symbol = symbol_;
    DECIMALS = IERC20(asset_).decimals();
    _canWithdraw = true; // Allow withdrawals by default
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
    return PT_VAULT;
  }

  function ytToken() public view override returns (address) {
    return YT_VAULT;
  }

  function asset() public view override returns (address) {
    return ASSET;
  }

  function canWithdraw() public view override returns (bool) {
    return _canWithdraw;
  }

  // Test helper functions
  function setCanWithdraw(bool canWithdraw_) public {
    _canWithdraw = canWithdraw_;
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

    // Emit deposit events
    if (ptShares > 0) {
      ControlledVault(PT_VAULT)._emitDeposit(msg.sender, to, ptShares, ptShares);
    }
    if (ytShares > 0) {
      ControlledVault(YT_VAULT)._emitDeposit(msg.sender, to, 0, ytShares);
    }
  }
}

