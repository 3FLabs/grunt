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

  /// @dev Returns the total assets (sum of per-position NAVs), the aggregate debt, and the
  ///      aggregate collateral of the non-bad-debt positions in a single iteration. Bad-debt
  ///      positions — those where the debt value exceeds the collateral value — contribute zero
  ///      to all three, so `totalCollateral == amount + totalDebt` and represents the collateral
  ///      of the "good" positions only. `totalCollateral` is consumed directly by the management
  ///      fee basis and feeds the performance-fee basis as `currentCollat`.
  ///
  ///      Inclusion cliff: the `collateral >= debt` filter is binary. At exactly 100% LTV a module
  ///      is still included and its full collateral feeds the management-fee basis; one wei of debt
  ///      higher and the module is excluded entirely, contributing zero collateral. This is an edge
  ///      case in practice (liquidation is expected long before LTV reaches 100%), but worth noting.
  ///
  ///      Debt rounding: each module's `totalBorrowed()` returns `toAssetsDown(borrowShares)`,
  ///      which is the same rounding Morpho applies internally when converting borrow shares to
  ///      debt assets. The value is therefore the exact debt the underlying market recognises in
  ///      asset terms, not a 1-wei understatement, so `collateral - debt` here matches the NAV
  ///      Morpho itself attributes to the position. The sub-1-wei share residual left by the
  ///      conversion is not separately enforceable as additional asset debt.
  /// @param ps The position manager storage data
  /// @return amount The total assets value (sum of `collateral - debt` for non-bad-debt positions)
  /// @return totalDebt The aggregate debt of non-bad-debt positions only
  /// @return totalCollateral The aggregate quoted collateral of non-bad-debt positions only
  function totalAssets(PositionManagerStorageData storage ps)
    internal
    view
    returns (uint256 amount, uint256 totalDebt, uint256 totalCollateral)
  {
    address[] memory modules = ps.borrowModules.values();
    uint256 modulesLength = modules.length;
    for (uint256 i = 0; i < modulesLength; ++i) {
      uint256 collateral = IBorrowPosition(modules[i]).totalCollateralQuoted();
      uint256 debt = IBorrowPosition(modules[i]).totalBorrowed();
      if (collateral >= debt) {
        amount += collateral - debt;
        totalDebt += debt;
        totalCollateral += collateral;
      }
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
