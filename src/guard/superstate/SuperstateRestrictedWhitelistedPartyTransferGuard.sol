// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {WhitelistedPartyTransferGuard} from "../whitelisted-party/WhitelistedPartyTransferGuard.sol";
import {ISuperstateToken} from "../../interfaces/integrations/superstate/ISuperstateToken.sol";

/// @title SuperstateRestrictedWhitelistedPartyTransferGuard
/// @author 3F Protocol
/// @notice Extends WhitelistedPartyTransferGuard with Superstate allowlist enforcement.
/// @dev Combines two layers of transfer validation:
///      1. **WhitelistedPartyTransferGuard**: At least one non-null party must be on the guard's whitelist
///         (e.g., the Facility), with pause support. Mints/burns always pass.
///      2. **Superstate allowlist**: Both non-null parties must be on Superstate's allowlist.
///
///      **Example flow (Facility whitelisted, user deposits PM shares):**
///      - User → Facility transfer: Facility is whitelisted (layer 1 passes), both parties
///        must be on Superstate's allowlist (layer 2).
///      - User → User transfer: Blocked by layer 1 (neither is on guard whitelist).
///      - Mint to user: Passes layer 1 (mint always allowed), user must be on Superstate (layer 2).
///
///      The Superstate token reference is stored as an immutable, set at construction time.
contract SuperstateRestrictedWhitelistedPartyTransferGuard is WhitelistedPartyTransferGuard {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         IMMUTABLES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice The Superstate token whose allowlist is enforced.
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

  /// @dev Extends WhitelistedPartyTransferGuard's canTransfer with Superstate allowlist checks.
  ///      Both non-null parties must be on the Superstate allowlist in addition to passing
  ///      the whitelisted-party check (at least one party whitelisted in the guard).
  function canTransfer(address token, address from, address to, uint256 amount) public view override returns (bool) {
    // WhitelistedPartyTransferGuard checks (pause, one-party-whitelisted)
    if (!super.canTransfer(token, from, to, amount)) return false;

    // Superstate allowlist checks
    if (from != address(0) && !ISuperstateToken(SUPERSTATE_TOKEN).isAllowed(from)) return false;
    if (to != address(0) && !ISuperstateToken(SUPERSTATE_TOKEN).isAllowed(to)) return false;

    return true;
  }
}
