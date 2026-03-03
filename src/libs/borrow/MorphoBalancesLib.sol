// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";
import {IMorpho, Id, MarketParams, Market} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IIrm} from "lib/morpho-blue/src/interfaces/IIrm.sol";
import {SharesMathLib} from "./SharesMathLib.sol";

/// @title MorphoBalancesLib
/// @notice Helper library exposing getters with the expected value after interest accrual.
/// @dev Rewrite of Morpho Labs' `MorphoBalancesLib` using Solady's `FixedPointMathLib`, `SafeCastLib`,
///      and the project's `SharesMathLib`, following the 3F Protocol codebase conventions.
///      The original implementation can be found at:
///      https://github.com/morpho-org/morpho-blue/blob/main/src/libraries/periphery/MorphoBalancesLib.sol
/// @dev This library is not used in Morpho itself and is intended to be used by integrators.
/// @dev The getter to retrieve the expected total borrow shares is not exposed because interest accrual does not apply
///      to it. The value can be queried directly on Morpho using `totalBorrowShares`.
/// @author 3F Protocol (rewrite of Morpho Labs' MorphoBalancesLib)
library MorphoBalancesLib {
  using FixedPointMathLib for uint256;
  using SafeCastLib for uint256;
  using SharesMathLib for uint256;

  /// @dev WAD constant for fixed-point math (1e18).
  uint256 internal constant WAD = 1e18;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     EXPECTED BALANCES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the expected market balances of a market after having accrued interest.
  /// @param morpho The Morpho protocol contract.
  /// @param marketParams The market parameters (needed to call the IRM).
  /// @param marketId The Morpho market ID.
  /// @return The expected total supply assets.
  /// @return The expected total supply shares.
  /// @return The expected total borrow assets.
  /// @return The expected total borrow shares.
  function expectedMarketBalances(IMorpho morpho, MarketParams memory marketParams, Id marketId)
    internal
    view
    returns (uint256, uint256, uint256, uint256)
  {
    Market memory market = morpho.market(marketId);

    uint256 elapsed = block.timestamp - market.lastUpdate;

    // Skipped if elapsed == 0 or totalBorrowAssets == 0 because interest would be null, or if irm == address(0).
    if (elapsed != 0 && market.totalBorrowAssets != 0 && marketParams.irm != address(0)) {
      uint256 borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, market);
      uint256 interest = uint256(market.totalBorrowAssets).mulWad(_wTaylorCompounded(borrowRate, elapsed));
      market.totalBorrowAssets += interest.toUint128();
      market.totalSupplyAssets += interest.toUint128();

      if (market.fee != 0) {
        uint256 feeAmount = interest.mulWad(market.fee);
        // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
        // that total supply is already updated.
        uint256 feeShares = feeAmount.toSharesDown(market.totalSupplyAssets - feeAmount, market.totalSupplyShares);
        market.totalSupplyShares += feeShares.toUint128();
      }
    }

    return (market.totalSupplyAssets, market.totalSupplyShares, market.totalBorrowAssets, market.totalBorrowShares);
  }

  /// @notice Returns the expected total supply assets of a market after having accrued interest.
  /// @param morpho The Morpho protocol contract.
  /// @param marketParams The market parameters.
  /// @param marketId The Morpho market ID.
  /// @return totalSupplyAssets The expected total supply assets.
  function expectedTotalSupplyAssets(IMorpho morpho, MarketParams memory marketParams, Id marketId)
    internal
    view
    returns (uint256 totalSupplyAssets)
  {
    (totalSupplyAssets,,,) = expectedMarketBalances(morpho, marketParams, marketId);
  }

  /// @notice Returns the expected total borrow assets of a market after having accrued interest.
  /// @param morpho The Morpho protocol contract.
  /// @param marketParams The market parameters.
  /// @param marketId The Morpho market ID.
  /// @return totalBorrowAssets The expected total borrow assets.
  function expectedTotalBorrowAssets(IMorpho morpho, MarketParams memory marketParams, Id marketId)
    internal
    view
    returns (uint256 totalBorrowAssets)
  {
    (,, totalBorrowAssets,) = expectedMarketBalances(morpho, marketParams, marketId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTERNAL HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the first three non-zero terms of a Taylor expansion of e^(nx) - 1,
  ///      used to approximate continuous compound interest.
  ///      This mirrors Morpho Blue's `MathLib.wTaylorCompounded`.
  /// @param x The per-second rate (WAD-scaled).
  /// @param n The number of seconds elapsed.
  /// @return The compounded factor (WAD-scaled).
  function _wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
    uint256 firstTerm = x * n;
    uint256 secondTerm = firstTerm.mulDiv(firstTerm, 2 * WAD);
    uint256 thirdTerm = secondTerm.mulDiv(firstTerm, 3 * WAD);

    return firstTerm + secondTerm + thirdTerm;
  }
}
