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
///      **Transfer validation (in addition to parent's SENDER_ROLE / RECEIVER_ROLE checks):**
///      - For non-mint transfers (from != address(0)): sender must be on Superstate's allowlist
///      - For non-burn transfers (to != address(0)): receiver must be on Superstate's allowlist
///      - Mints and burns only check the non-zero address party
///
///      This ensures that no address outside Superstate's compliance perimeter can hold or transfer
///      the wrapped token, even if granted SENDER_ROLE or RECEIVER_ROLE.
contract SuperstateRestrictedWrappedAsset is WrappedAsset {
  /// @dev Enforces transfer restrictions from the parent (SENDER_ROLE / RECEIVER_ROLE), then
  ///      additionally requires that both non-null parties are on Superstate's allowlist.
  ///      - Mints (from == address(0)): only `to` is checked against the allowlist
  ///      - Burns (to == address(0)): only `from` is checked against the allowlist
  ///      - Transfers: both `from` and `to` must be on the allowlist
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
    super._beforeTokenTransfer(from, to, amount);

    address superstateToken_ = _wrappedAssetStorage().underlying;

    if (from != address(0) && !ISuperstateToken(superstateToken_).isAllowed(from)) {
      revert Unauthorized();
    }
    if (to != address(0) && !ISuperstateToken(superstateToken_).isAllowed(to)) {
      revert Unauthorized();
    }
  }
}
