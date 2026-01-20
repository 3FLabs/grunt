// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ITransferGuard} from "../interfaces/guard/ITransferGuard.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

/// @notice Status of an address in the transfer guard.
/// @dev NONE must be 0 so unset mappings default to the token's mode behavior.
enum AddressStatus {
  /// @notice Not explicitly set - behavior depends on token mode (blocklist vs whitelist).
  NONE,
  /// @notice Explicitly whitelisted - allowed in whitelist mode, also allowed in blocklist mode.
  WHITELIST,
  /// @notice Explicitly blocklisted - blocked in both modes.
  BLOCKLIST
}

/// @notice Per-token configuration packed into a single storage slot.
/// @param paused Whether transfers are paused for this token.
/// @param whitelist If true, token uses whitelist mode (only WHITELIST allowed). If false, blocklist mode (only BLOCKLIST blocked).
/// @dev Layout: paused (8 bits) + whitelist (8 bits) = 16 bits (fits in single slot)
struct TokenConfig {
  bool paused;
  bool whitelist;
}

/// @title TransferGuard
/// @author 3F Protocol
/// @notice Gas-optimized transfer validation with single mapping for address status.
/// @dev Uses a single mapping with enum status instead of separate blocklist/allowlist mappings.
///      Token config (paused, whitelist mode) is packed into a single slot per token.
///      Deployable via beacon proxy pattern for upgradeability.
///
///      **Token modes:**
///      Each token can be configured in one of two modes:
///      - Blocklist mode (default): All addresses allowed EXCEPT those with BLOCKLIST status
///      - Whitelist mode: ONLY addresses with WHITELIST status are allowed
///
///      **Address status behavior:**
///      - NONE: Behavior depends on token mode (allowed in blocklist mode, blocked in whitelist mode)
///      - WHITELIST: Always allowed (in both modes)
///      - BLOCKLIST: Always blocked (in both modes)
///
///      **Validation logic:**
///      1. If token is paused → block all transfers
///      2. Check `from` status (skip for mints where from == address(0))
///      3. Check `to` status (skip for burns where to == address(0))
///
///      **Roles:**
///      - Owner: Full control (set token config, manage roles)
///      - COMPLIANCE_ROLE: Manage address statuses
///      - PAUSER_ROLE: Pause/unpause tokens
contract TransferGuard is ITransferGuard, OwnableRoles, Initializable {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Role for managing address statuses.
  uint256 public constant COMPLIANCE_ROLE = _ROLE_0;

  /// @dev Role for pausing/unpausing tokens.
  uint256 public constant PAUSER_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Status of each address (NONE, WHITELIST, or BLOCKLIST).
  mapping(address account => AddressStatus status) public addressStatus;

  /// @notice Per-token configuration (paused, whitelist mode) packed in one slot.
  mapping(address token => TokenConfig config) public tokenConfig;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the transfer guard with an owner.
  /// @dev Can only be called once due to the initializer modifier.
  /// @param owner_ The initial owner of the guard
  function initialize(address owner_) external initializer {
    _initializeOwner(owner_);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc ITransferGuard
  function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool) {
    TokenConfig memory config = tokenConfig[token];

    // Check pause status
    if (config.paused) return false;

    // Check sender (skip for mints)
    if (from != address(0) && !_isAllowed(from, config.whitelist)) {
      return false;
    }

    // Check recipient (skip for burns)
    if (to != address(0) && !_isAllowed(to, config.whitelist)) {
      return false;
    }

    return true;
  }

  /// @inheritdoc ITransferGuard
  function paused(address token) external view returns (bool) {
    return tokenConfig[token].paused;
  }

  /// @notice Returns whether a token is in whitelist mode.
  /// @param token The token address
  /// @return True if whitelist mode, false if blocklist mode
  function isWhitelistMode(address token) external view returns (bool) {
    return tokenConfig[token].whitelist;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL FUNCTIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Checks if an address is allowed based on its status and token mode.
  /// @param account The address to check
  /// @param whitelistMode Whether the token is in whitelist mode
  /// @return True if allowed, false otherwise
  function _isAllowed(address account, bool whitelistMode) internal view returns (bool) {
    AddressStatus status = addressStatus[account];

    // BLOCKLIST is always blocked in both modes
    if (status == AddressStatus.BLOCKLIST) {
      return false;
    }

    // WHITELIST is always allowed in both modes
    if (status == AddressStatus.WHITELIST) {
      return true;
    }

    // status == AddressStatus.NONE: depends on token mode
    // In blocklist mode (default): NONE is allowed
    // In whitelist mode: NONE is blocked
    return !whitelistMode;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     COMPLIANCE FUNCTIONS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the status of an address.
  /// @param account The address to update
  /// @param status The new status
  function setAddressStatus(address account, AddressStatus status) external onlyOwnerOrRoles(COMPLIANCE_ROLE) {
    addressStatus[account] = status;
    emit AddressStatusSet(account, uint8(status));
  }

  /// @notice Batch update address statuses.
  /// @param accounts The addresses to update
  /// @param status The new status for all addresses
  function setAddressStatusBatch(address[] calldata accounts, AddressStatus status)
    external
    onlyOwnerOrRoles(COMPLIANCE_ROLE)
  {
    for (uint256 i = 0; i < accounts.length; ++i) {
      addressStatus[accounts[i]] = status;
      emit AddressStatusSet(accounts[i], uint8(status));
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pauses all transfers for a token.
  /// @param token The token to pause
  function pause(address token) external onlyOwnerOrRoles(PAUSER_ROLE) {
    tokenConfig[token].paused = true;
    emit TokenPaused(token);
  }

  /// @notice Unpauses transfers for a token.
  /// @param token The token to unpause
  function unpause(address token) external onlyOwnerOrRoles(PAUSER_ROLE) {
    tokenConfig[token].paused = false;
    emit TokenUnpaused(token);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      ADMIN FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the full configuration for a token.
  /// @param token The token to configure
  /// @param paused_ Whether transfers should be paused
  /// @param whitelist_ Whether to use whitelist mode (true) or blocklist mode (false)
  function setTokenConfig(address token, bool paused_, bool whitelist_) external onlyOwner {
    tokenConfig[token] = TokenConfig({paused: paused_, whitelist: whitelist_});
    emit TokenConfigSet(token, paused_, whitelist_);
  }
}
