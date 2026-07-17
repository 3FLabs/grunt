// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @dev Mock borrow position for testing manager libraries.
///      Uses a 1:1 collateral-to-borrow price for simplicity.
contract MockBorrowPosition is IBorrowPosition {
  using SafeTransferLib for address;
  using FixedPointMathLib for uint256;

  address public override collateralAsset;
  address public override borrowAsset;

  uint256 public override totalCollateral;
  uint256 public override totalCollateralQuoted;
  uint256 public override totalBorrowed;
  uint256 public override availableLiquidity;
  uint128 public override safeLtv;
  uint128 public override liquidationLtv;

  bool public healthy = true;

  constructor(address _collateralAsset, address _borrowAsset) {
    collateralAsset = _collateralAsset;
    borrowAsset = _borrowAsset;
  }

  function supplyCollateral(uint256 amount) external override {
    collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
    totalCollateral += amount;
    totalCollateralQuoted += amount; // 1:1 for simplicity
  }

  function withdrawCollateral(uint256 amount) external override {
    totalCollateral -= amount;
    totalCollateralQuoted -= amount;
    collateralAsset.safeTransfer(msg.sender, amount);
  }

  function borrow(uint256 amount) external override {
    totalBorrowed += amount;
    borrowAsset.safeTransfer(msg.sender, amount);
  }

  function repay(uint256 amount) external override {
    borrowAsset.safeTransferFrom(msg.sender, address(this), amount);
    totalBorrowed -= amount;
  }

  function isHealthy(uint256) external view override returns (bool) {
    return healthy;
  }

  function maxBorrow(uint256) external view override returns (uint256) {
    return availableLiquidity;
  }

  function availableCollateral(uint256 ltv) external view override returns (uint256) {
    if (ltv == 0 || totalBorrowed == 0) return totalCollateral;
    uint256 requiredCollateral = totalBorrowed.divWadUp(ltv);
    if (requiredCollateral >= totalCollateral) return 0;
    return totalCollateral - requiredCollateral;
  }

  /// @dev Returns additional collateral needed to borrow `borrowAmount` at `ltv` (1:1 price).
  ///      Formula: ceil((totalBorrowed + borrowAmount) / ltv) - totalCollateral, floored at 0.
  function collateralForBorrow(uint256 borrowAmount, uint256 ltv) external view override returns (uint256) {
    uint256 requiredCollateral = (totalBorrowed + borrowAmount).divWadUp(ltv);
    if (requiredCollateral <= totalCollateral) return 0;
    return requiredCollateral - totalCollateral;
  }

  /// @dev Returns additional borrow capacity from supplying `collateralAmount` at `ltv` (1:1 price).
  ///      Formula: min((totalCollateral + collateralAmount) * ltv - totalBorrowed, availableLiquidity), floored at 0.
  function borrowForCollateral(uint256 collateralAmount, uint256 ltv) external view override returns (uint256) {
    uint256 maxDebt = (totalCollateral + collateralAmount).mulWad(ltv);
    if (maxDebt <= totalBorrowed) return 0;
    uint256 capacity = maxDebt - totalBorrowed;
    return capacity < availableLiquidity ? capacity : availableLiquidity;
  }

  // Test helpers
  function setTotalCollateral(uint256 _totalCollateral) external {
    totalCollateral = _totalCollateral;
  }

  function setTotalCollateralQuoted(uint256 _totalCollateralQuoted) external {
    totalCollateralQuoted = _totalCollateralQuoted;
  }

  function setTotalBorrowed(uint256 _totalBorrowed) external {
    totalBorrowed = _totalBorrowed;
  }

  function setAvailableLiquidity(uint256 _availableLiquidity) external {
    availableLiquidity = _availableLiquidity;
  }

  function setHealthy(bool _healthy) external {
    healthy = _healthy;
  }

  function setSafeLtv(uint128 _safeLtv) external {
    safeLtv = _safeLtv;
  }

  // Allow receiving borrow assets
  function fund(address token, uint256 amount) external {
    token.safeTransferFrom(msg.sender, address(this), amount);
  }
}
