// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {TransferGuard} from "src/guard/TransferGuard.sol";

/// @title MaliciousBorrowModule
/// @notice A malicious borrow module that pauses the guard during withdrawCollateral
/// @dev This demonstrates the reentrancy edge case in rebalance pause checks
///      In this PoC, the module has PAUSER_ROLE granted to it, simulating a scenario where:
///      - A trusted module becomes compromised
///      - Or a module was incorrectly granted pause privileges
contract MaliciousBorrowModule is IBorrowPosition {
  TransferGuard public guard;
  address public token;
  address public collateralAsset_;
  address public borrowAsset_;
  address public owner_;
  bool public shouldPause;

  constructor(address _guard, address _token, address _collateralAsset, address _borrowAsset, address _owner) {
    guard = TransferGuard(_guard);
    token = _token;
    collateralAsset_ = _collateralAsset;
    borrowAsset_ = _borrowAsset;
    owner_ = _owner;
  }

  function setShouldPause(bool _shouldPause) external {
    shouldPause = _shouldPause;
  }

  // Operation functions
  function supplyCollateral(uint256) external override {
    // No-op for this test
  }

  function withdrawCollateral(uint256) external override {
    // Malicious callback: pause the guard mid-rebalance
    // This module has PAUSER_ROLE, simulating a compromised trusted module
    if (shouldPause && !guard.paused(token)) {
      guard.pause(token);
    }
  }

  function borrow(uint256) external override {
    // No-op for this test
  }

  function repay(uint256) external override {
    // No-op for this test
  }

  // View functions
  function owner() external view returns (address) {
    return owner_;
  }

  function borrowAsset() external view override returns (address) {
    return borrowAsset_;
  }

  function collateralAsset() external view override returns (address) {
    return collateralAsset_;
  }

  function safeLtv() external pure override returns (uint128) {
    return uint128(1e18);
  }

  function totalBorrowed() external pure override returns (uint256) {
    return 0;
  }

  function totalCollateral() external pure override returns (uint256) {
    return 0;
  }

  function totalCollateralQuoted() external pure override returns (uint256) {
    return 0;
  }

  function isHealthy(uint256) external pure override returns (bool) {
    return true;
  }

  function maxBorrow(uint256) external pure override returns (uint256) {
    return 0;
  }

  function availableLiquidity() external pure override returns (uint256) {
    return 0;
  }

  function availableCollateral(uint256) external pure override returns (uint256) {
    return 0;
  }
}
