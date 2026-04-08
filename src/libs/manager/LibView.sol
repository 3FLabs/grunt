// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {PositionManagerStorageData} from "./LibStorage.sol";
import {VIRTUAL_ASSETS} from "./LibConstants.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibView
/// @author 3F Protocol
/// @notice Library for PositionManager view functions and share calculations.
/// @dev Used with `using LibView for PositionManagerStorageData`.
library LibView {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using FixedPointMathLib for uint256;

  /// @dev Returns the total collateral amount across all borrow modules.
  /// @param ps The position manager storage data
  /// @return amount The total collateral amount
  function collateralAmount(PositionManagerStorageData storage ps) internal view returns (uint256 amount) {
    address[] memory modules = ps.borrowModules.values();
    uint256 modulesLength = modules.length;
    for (uint256 i = 0; i < modulesLength; ++i) {
      amount += IBorrowPosition(modules[i]).totalCollateral();
    }
  }

  /// @dev Returns the total quoted collateral amount across all borrow modules.
  /// @param ps The position manager storage data
  /// @return amount The total quoted collateral amount
  function collateralAmountQuoted(PositionManagerStorageData storage ps) internal view returns (uint256 amount) {
    address[] memory modules = ps.borrowModules.values();
    uint256 modulesLength = modules.length;
    for (uint256 i = 0; i < modulesLength; ++i) {
      amount += IBorrowPosition(modules[i]).totalCollateralQuoted();
    }
  }

  /// @dev Returns the total debt amount across all borrow modules.
  /// @param ps The position manager storage data
  /// @return amount The total debt amount
  function debtAmount(PositionManagerStorageData storage ps) internal view returns (uint256 amount) {
    address[] memory modules = ps.borrowModules.values();
    uint256 modulesLength = modules.length;
    for (uint256 i = 0; i < modulesLength; ++i) {
      amount += IBorrowPosition(modules[i]).totalBorrowed();
    }
  }

  /// @dev Returns the total assets as the sum of per-position NAVs, treating bad-debt positions as zero.
  ///      Each position's NAV is computed as collateralQuoted.zeroFloorSub(debt), ensuring positions
  ///      with bad debt do not reduce the overall NAV.
  /// @param ps The position manager storage data
  /// @return amount The total assets value
  function totalAssets(PositionManagerStorageData storage ps) internal view returns (uint256 amount) {
    address[] memory modules = ps.borrowModules.values();
    uint256 modulesLength = modules.length;
    for (uint256 i = 0; i < modulesLength; ++i) {
      uint256 collateral = IBorrowPosition(modules[i]).totalCollateralQuoted();
      uint256 debt = IBorrowPosition(modules[i]).totalBorrowed();
      amount += collateral.zeroFloorSub(debt);
    }
  }

  /// @dev Converts assets to shares using virtual offset for inflation attack protection.
  /// @param assets The amount of assets to convert
  /// @param _totalSupply The current total supply of shares
  /// @param _totalAssets The current total assets
  /// @param virtualShareOffset_ The virtual shares offset (10^(18 - debtAsset.decimals())), stored per-vault
  /// @param roundUp If true, rounds up the result (use when burning shares); if false, rounds down (use when minting)
  /// @return shares The equivalent amount of shares
  function convertToShares(
    uint256 assets,
    uint256 _totalSupply,
    uint256 _totalAssets,
    uint256 virtualShareOffset_,
    bool roundUp
  ) internal pure returns (uint256 shares) {
    if (roundUp) {
      return assets.mulDivUp(_totalSupply + virtualShareOffset_, _totalAssets + VIRTUAL_ASSETS);
    }
    return assets.mulDiv(_totalSupply + virtualShareOffset_, _totalAssets + VIRTUAL_ASSETS);
  }
}
