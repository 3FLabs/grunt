// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {RebalancingData, RebalancingOperation} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";

/// @title ReentrantBorrowModule
/// @notice A malicious borrow module that attempts to re-enter rebalance during callback
contract ReentrantBorrowModule is IBorrowPosition {
  PositionManager public positionManager;
  address public rebalancer;
  address public collateralAsset_;
  address public borrowAsset_;
  bool public shouldReenter;
  bool public reentryAttempted;
  bool public reentrySucceeded;

  constructor(address _positionManager, address _rebalancer, address _collateralAsset, address _borrowAsset) {
    positionManager = PositionManager(_positionManager);
    rebalancer = _rebalancer;
    collateralAsset_ = _collateralAsset;
    borrowAsset_ = _borrowAsset;
  }

  function setShouldReenter(bool _shouldReenter) external {
    shouldReenter = _shouldReenter;
  }

  function supplyCollateral(uint256) external override {}

  function withdrawCollateral(uint256) external override {
    if (shouldReenter && !reentryAttempted) {
      reentryAttempted = true;
      // Attempt to re-enter rebalance - this should fail with reentrancy guard
      RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: new RebalancingOperation[](0)});
      try positionManager.rebalance(data, rebalancer) {
        reentrySucceeded = true;
      } catch {
        reentrySucceeded = false;
      }
    }
  }

  function borrow(uint256) external override {}
  function repay(uint256) external override {}

  function owner() external view returns (address) {
    return address(positionManager);
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

  function liquidationLtv() external pure override returns (uint128) {
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

  function collateralForBorrow(uint256, uint256) external pure override returns (uint256) {
    return 0;
  }

  function borrowForCollateral(uint256, uint256) external pure override returns (uint256) {
    return 0;
  }
}
