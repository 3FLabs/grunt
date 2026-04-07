// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {TransferGuard} from "../base/TransferGuard.sol";
import {ISuperstateToken} from "../../interfaces/integrations/superstate/ISuperstateToken.sol";

/// @title SuperstateRestrictedTransferGuard
/// @author 3F Protocol
/// @notice Extends TransferGuard with Superstate allowlist enforcement on both transfer parties.
/// @dev Inherits all TransferGuard functionality (blocklist/whitelist modes, pause, compliance roles)
///      and adds an additional layer: both non-null parties must be on the Superstate allowlist.
///
///      **Validation order:**
///      1. Base TransferGuard checks (pause, address status in blocklist/whitelist mode)
///      2. Superstate allowlist check on sender (skipped for mints)
///      3. Superstate allowlist check on receiver (skipped for burns)
///
///      A transfer that passes the base guard can still be blocked if either party is not on
///      Superstate's allowlist. This ensures regulatory compliance at the transfer guard level.
///
///      The Superstate token reference is stored as an immutable, set at construction time.
///      All proxies deployed from the same beacon share the same Superstate token reference.
contract SuperstateRestrictedTransferGuard is TransferGuard {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Superstate token whose allowlist is enforced.
  /// @dev Set at construction time and shared across all beacon proxies.
  address public immutable SUPERSTATE_TOKEN;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSTRUCTOR                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @param superstateToken_ The Superstate token address (e.g., USCC) for allowlist checks
  constructor(address superstateToken_) {
    SUPERSTATE_TOKEN = superstateToken_;
    _disableInitializers();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Extends the base TransferGuard's canTransfer with Superstate allowlist checks.
  ///      Both non-null parties must be on the Superstate allowlist in addition to passing
  ///      the base guard's checks (pause, blocklist/whitelist address status).
  function canTransfer(address token, address from, address to, uint256 amount) public view override returns (bool) {
    // Base TransferGuard checks (pause, address status)
    if (!super.canTransfer(token, from, to, amount)) return false;

    // Superstate allowlist checks
    if (from != address(0) && !ISuperstateToken(SUPERSTATE_TOKEN).isAllowed(from)) return false;
    if (to != address(0) && !ISuperstateToken(SUPERSTATE_TOKEN).isAllowed(to)) return false;

    return true;
  }
}
