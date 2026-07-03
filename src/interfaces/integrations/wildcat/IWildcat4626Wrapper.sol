// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC4626} from "../IERC4626.sol";

/// @title IWildcat4626Wrapper
/// @author 3F Protocol
/// @notice Interface of Wildcat's official ERC-4626 wrapper over a market token.
/// @dev The wrapper's `asset()` is the (rebasing) market token itself; its shares mirror the
///      market's internal scaled balances, making them non-rebasing and price-appreciating
///      (1 share = `scaleFactor` / 1e27 market tokens). One wrapper exists per market, deployed
///      permissionlessly via the Wildcat4626WrapperFactory.
///      Rounding notes (vs the ERC-4626 spec): `deposit` mints the scaled amount actually
///      received (half-up, matching the market's transfer scaling) and `redeem` sends
///      half-up-rounded market tokens; `convertToShares`/`convertToAssets` round down.
interface IWildcat4626Wrapper is IERC4626 {
  /// @notice The wrapped Wildcat market (which is also the wrapper's ERC-4626 `asset()`).
  function market() external view returns (address);
}
