// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {PositionManagerStorageData} from "./LibStorage.sol";
import {VIRTUAL_SHARES, VIRTUAL_ASSETS} from "./LibConstants.sol";
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
    for (uint256 i = 0; i < modulesLength;) {
      amount += IBorrowPosition(modules[i]).totalCollateral();
      unchecked {
        ++i;
      }
    }
  }

  /// @dev Returns the total quoted collateral amount across all borrow modules.
  /// @param ps The position manager storage data
  /// @return amount The total quoted collateral amount
  function collateralAmountQuoted(PositionManagerStorageData storage ps) internal view returns (uint256 amount) {
    address[] memory modules = ps.borrowModules.values();
    uint256 modulesLength = modules.length;
    for (uint256 i = 0; i < modulesLength;) {
      amount += IBorrowPosition(modules[i]).totalCollateralQuoted();
      unchecked {
        ++i;
      }
    }
  }

  /// @dev Returns the total debt amount across all borrow modules.
  /// @param ps The position manager storage data
  /// @return amount The total debt amount
  function debtAmount(PositionManagerStorageData storage ps) internal view returns (uint256 amount) {
    address[] memory modules = ps.borrowModules.values();
    uint256 modulesLength = modules.length;
    for (uint256 i = 0; i < modulesLength;) {
      amount += IBorrowPosition(modules[i]).totalBorrowed();
      unchecked {
        ++i;
      }
    }
  }

  /// @dev Returns the total assets (quoted collateral minus debt).
  /// @param ps The position manager storage data
  /// @return The total assets value
  function totalAssets(PositionManagerStorageData storage ps) internal view returns (uint256) {
    return collateralAmountQuoted(ps).zeroFloorSub(debtAmount(ps));
  }

  /// @dev Converts assets to shares using virtual offset for inflation attack protection.
  /// @param assets The amount of assets to convert
  /// @param _totalSupply The current total supply of shares
  /// @param _totalAssets The current total assets
  /// @return shares The equivalent amount of shares
  function convertToShares(uint256 assets, uint256 _totalSupply, uint256 _totalAssets)
    internal
    pure
    returns (uint256 shares)
  {
    return assets.mulDiv(_totalSupply + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS);
  }
}
