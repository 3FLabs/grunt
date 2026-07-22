// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {WrappedAsset} from "../WrappedAsset.sol";
import {ISuperstateToken} from "../../interfaces/integrations/superstate/ISuperstateToken.sol";

/// @title SuperstateRestrictedWrappedAsset
/// @author 3F Protocol
/// @notice Extends WrappedAsset with Superstate allowlist enforcement on wrapper-share holders.
/// @dev The underlying asset IS the Superstate token (e.g. USCC): overriding `isAllowed` makes the base
///      `_beforeTokenTransfer` hook enforce the Superstate allowlist on wrapper-token transfers, mints,
///      and burns, while the underlying token independently enforces its own allowlist on the asset legs.
contract SuperstateRestrictedWrappedAsset is WrappedAsset {
  /// @dev Delegates to the Superstate token's allowlist check.
  ///      The `amount` parameter is unused; Superstate's allowlist is binary per address.
  function isAllowed(address account, uint256) public view override returns (bool) {
    return ISuperstateToken(_wrappedAssetStorage().underlying).isAllowed(account);
  }
}
