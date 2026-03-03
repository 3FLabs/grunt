// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ITransferGuard, AddressStatus} from "../interfaces/guard/ITransferGuard.sol";
import {LibPause} from "../libs/common/LibPause.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @notice Per-token configuration packed into a single storage slot.
/// @param pausedUntil Pause-until timestamp (0 = not paused, type(uint40).max = permanent pause).
/// @param whitelist If true, token uses whitelist mode (only WHITELIST allowed). If false, blocklist mode (only BLOCKLIST blocked).
/// @dev Layout: pausedUntil (40 bits) + whitelist (8 bits) = 48 bits (fits in single slot)
struct TokenConfig {
  uint40 pausedUntil;
  bool whitelist;
}

/// @title TransferGuard
/// @author 3F Protocol
/// @notice Gas-optimized transfer validation with single mapping for address status.
/// @dev Uses a single mapping with enum status instead of separate blocklist/allowlist mappings.
///      Token config (paused, whitelist mode) is packed into a single slot per token.
///      Deployable via beacon proxy pattern for upgradeability.
///
///      **Storage:** Uses ERC-7201 namespaced storage layout for proxy safety.
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
///      - _COMPLIANCE_ROLE: Manage address statuses
///      - _PAUSER_ROLE: Pause/unpause tokens
contract TransferGuard is ITransferGuard, OwnableRoles, Initializable {
  using LibPause for uint40;
  using FixedPointMathLib for bool;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Role for managing address statuses.
  uint256 internal constant _COMPLIANCE_ROLE = _ROLE_0;

  /// @dev Role for pausing/unpausing tokens.
  uint256 internal constant _PAUSER_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ERC-7201 STORAGE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @custom:storage-location erc7201:transferguard.main
  struct TransferGuardStorage {
    /// @notice Status of each address (NONE, WHITELIST, or BLOCKLIST).
    mapping(address account => AddressStatus status) addressStatus;
    /// @notice Per-token configuration (paused, whitelist mode) packed in one slot.
    mapping(address token => TokenConfig config) tokenConfig;
  }

  /// @dev Storage slot for TransferGuard.
  ///      keccak256(abi.encode(uint256(keccak256("transferguard.main")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _STORAGE_SLOT = 0xc6c8482afc451e8caac0099c996ccfb351ca947c4bbb65e7d1fc5f0e82e91c00;

  /// @dev Returns a pointer to the ERC-7201 namespaced storage struct.
  function _storage() private pure returns (TransferGuardStorage storage $) {
    assembly ("memory-safe") {
      $.slot := _STORAGE_SLOT
    }
  }

  constructor() {
    _disableInitializers();
  }

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

  /// @notice Returns the status of an address.
  /// @param account The address to query
  /// @return The address status (NONE, WHITELIST, or BLOCKLIST)
  function addressStatus(address account) external view returns (AddressStatus) {
    return _storage().addressStatus[account];
  }

  /// @notice Returns the per-token configuration.
  /// @param token The token address to query
  /// @return pausedUntil The pause-until timestamp
  /// @return whitelist Whether the token is in whitelist mode
  function tokenConfig(address token) external view returns (uint40 pausedUntil, bool whitelist) {
    TokenConfig memory config = _storage().tokenConfig[token];
    return (config.pausedUntil, config.whitelist);
  }

  /// @inheritdoc ITransferGuard
  function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool) {
    TransferGuardStorage storage $ = _storage();
    TokenConfig memory config = $.tokenConfig[token];

    // Check pause status using LibPause
    if (config.pausedUntil.paused()) return false;

    // Check sender (skip for mints)
    if (from != address(0) && !_isAllowed($, from, config.whitelist)) {
      return false;
    }

    // Check recipient (skip for burns)
    if (to != address(0) && !_isAllowed($, to, config.whitelist)) {
      return false;
    }

    return true;
  }

  /// @inheritdoc ITransferGuard
  function paused(address token) external view returns (bool) {
    return _storage().tokenConfig[token].pausedUntil.paused();
  }

  /// @notice Returns whether a token is in whitelist mode.
  /// @param token The token address
  /// @return True if whitelist mode, false if blocklist mode
  function isWhitelistMode(address token) external view returns (bool) {
    return _storage().tokenConfig[token].whitelist;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL FUNCTIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Checks if an address is allowed based on its status and token mode.
  /// @param $ The namespaced storage pointer
  /// @param account The address to check
  /// @param whitelistMode Whether the token is in whitelist mode
  /// @return True if allowed, false otherwise
  function _isAllowed(TransferGuardStorage storage $, address account, bool whitelistMode)
    internal
    view
    returns (bool)
  {
    AddressStatus status = $.addressStatus[account];

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
  function setAddressStatus(address account, AddressStatus status) external onlyOwnerOrRoles(_COMPLIANCE_ROLE) {
    _storage().addressStatus[account] = status;
    emit AddressStatusSet(account, status);
  }

  /// @notice Batch update address statuses.
  /// @param accounts The addresses to update
  /// @param status The new status for all addresses
  function setAddressStatusBatch(address[] calldata accounts, AddressStatus status)
    external
    onlyOwnerOrRoles(_COMPLIANCE_ROLE)
  {
    TransferGuardStorage storage $ = _storage();
    for (uint256 i = 0; i < accounts.length; ++i) {
      $.addressStatus[accounts[i]] = status;
      emit AddressStatusSet(accounts[i], status);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pauses all transfers for a token indefinitely.
  /// @param token The token to pause
  function pause(address token) external onlyOwnerOrRoles(_PAUSER_ROLE) {
    _storage().tokenConfig[token].pausedUntil = LibPause.PERMANENT_PAUSE;
    emit TokenPausedSet(token, LibPause.PERMANENT_PAUSE);
  }

  /// @notice Pauses all transfers for a token for a specified duration.
  /// @param token The token to pause
  /// @param duration The duration to pause for (in seconds)
  function pauseFor(address token, uint256 duration) external onlyOwnerOrRoles(_PAUSER_ROLE) {
    uint40 pauseUntil = LibPause.pauseFor(duration);
    _storage().tokenConfig[token].pausedUntil = pauseUntil;
    emit TokenPausedSet(token, pauseUntil);
  }

  /// @notice Unpauses transfers for a token.
  /// @param token The token to unpause
  function unpause(address token) external onlyOwnerOrRoles(_PAUSER_ROLE) {
    _storage().tokenConfig[token].pausedUntil = LibPause.NOT_PAUSED;
    emit TokenPausedSet(token, LibPause.NOT_PAUSED);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      ADMIN FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the full configuration for a token.
  /// @param token The token to configure
  /// @param paused_ Whether transfers should be paused (true = permanent pause, false = not paused)
  /// @param whitelist_ Whether to use whitelist mode (true) or blocklist mode (false)
  function setTokenConfig(address token, bool paused_, bool whitelist_) external onlyOwner {
    // converting to uint40 is safe because the result is less than 2^40
    // forge-lint: disable-next-line(unsafe-typecast)
    uint40 pausedUntil = uint40(paused_.ternary(LibPause.PERMANENT_PAUSE, LibPause.NOT_PAUSED));
    _storage().tokenConfig[token] = TokenConfig({pausedUntil: pausedUntil, whitelist: whitelist_});
    emit TokenConfigSet(token, pausedUntil, whitelist_);
  }
}
