// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {WrappedAsset} from "../WrappedAsset.sol";
import {ISuperstateToken} from "../../interfaces/integrations/superstate/ISuperstateToken.sol";

/// @title SuperstateRestrictedWrappedAsset
/// @author 3F Protocol
/// @notice Extends WrappedAsset with Superstate allowlist enforcement on all transfers.
/// @dev The underlying asset IS the Superstate token (e.g., USCC), so `isAllowed()` is called
///      directly on `underlying()`. No additional storage is needed beyond what WrappedAsset provides.
///
///      Overrides `isAllowed` so the base `_beforeTokenTransfer` hook automatically enforces
///      the Superstate allowlist for both non-null parties on every transfer, mint, and burn.
contract SuperstateRestrictedWrappedAsset is WrappedAsset {
  /// @dev Delegates to the Superstate token's allowlist check.
  ///      The `amount` parameter is unused — Superstate's allowlist is binary per address.
  function isAllowed(address account, uint256) external view override returns (bool) {
    return ISuperstateToken(_wrappedAssetStorage().underlying).isAllowed(account);
  }
}
