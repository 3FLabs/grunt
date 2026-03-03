// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title MockMaliciousPositionManager
/// @notice Minimal mock that returns configurable assets from assets().
/// @dev Used to test the InvalidPositionManagerAssets validation in FacilityPositionManager.
contract MockMaliciousPositionManager {
  address public immutable collateralAsset;
  address public immutable debtAsset;

  constructor(address _collateralAsset, address _debtAsset) {
    collateralAsset = _collateralAsset;
    debtAsset = _debtAsset;
  }

  function assets() external view returns (address, address) {
    return (collateralAsset, debtAsset);
  }

  /// @dev Needed so the mock passes ERC20 balanceOf calls from snapshot logic.
  function balanceOf(address) external pure returns (uint256) {
    return 0;
  }
}
