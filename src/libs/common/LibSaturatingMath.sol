// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibSaturatingMath
/// @author 3F Protocol
/// @notice Arithmetic that saturates at type(uint256).max instead of reverting.
library LibSaturatingMath {
  using FixedPointMathLib for uint256;

  /// @notice Returns `x * y / d` rounded down, or type(uint256).max when the result overflows.
  /// @dev Splits `x` into `q * d + r` so only `q * y` can overflow; `r < d` keeps `r * y / d`
  ///      below `y` (computed in 512 bits). Reverts on `d == 0`.
  function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
    uint256 q = x / d;
    uint256 r = x % d;
    if (y != 0 && q > type(uint256).max / y) return type(uint256).max;
    return (q * y).saturatingAdd(r.fullMulDiv(y, d));
  }
}
