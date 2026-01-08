// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ITransferGuard} from "../interfaces/guard/ITransferGuard.sol";
import {ITransferGuardValidator} from "../interfaces/guard/ITransferGuardValidator.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {SafeCastLib} from "lib/solady/src/utils/SafeCastLib.sol";

/// @notice Status of an address in the transfer guard.
/// @dev NONE must be 0 so unset mappings default to checking the validator.
enum AddressStatus {
  /// @notice Not explicitly set - delegate to validator contract (or allow if no validator).
  NONE,
  /// @notice Whitelisted for transfers below threshold only.
  WHITELIST,
  /// @notice Blocked from all transfers.
  BLOCKLIST,
  /// @notice Whitelisted for all transfers regardless of amount.
  WHITELIST_ALL_AMOUNTS
}

/// @notice Per-token configuration packed into a single storage slot.
/// @dev Layout: paused (8 bits) + scaledThreshold (88 bits) + validator (160 bits) = 256 bits
///      The threshold is stored scaled down by THRESHOLD_SCALE (1e6) to fit in 88 bits.
///      Max representable threshold = 2^88 * 1e6 ≈ 3.09e32, which supports any realistic token amount.
struct TokenConfig {
  /// @notice Whether transfers are paused for this token.
  bool paused;
  /// @notice Transfer threshold scaled down by THRESHOLD_SCALE. Actual threshold = scaledThreshold * THRESHOLD_SCALE.
  uint88 scaledThreshold;
  /// @notice Validator contract for NONE status addresses. address(0) = allow by default.
  address validator;
}

/// @title TransferGuard
/// @notice Gas-optimized transfer validation with single mapping for address status.
/// @dev Uses a single mapping with enum status instead of separate blocklist/allowlist mappings.
///      Token config (paused, threshold, validator) is packed into a single slot per token.
///      Deployable via beacon proxy pattern for upgradeability.
///
///      **Threshold scaling:**
///      The threshold is stored scaled down by THRESHOLD_SCALE (1e6) to maximize the range
///      of representable values in 88 bits. This means:
///      - Minimum granularity: 1e6 (1 token for 6-decimal tokens, 0.000001 for 18-decimal)
///      - Maximum threshold: ~3.09e32 (more than enough for any token)
///      - When setting threshold, pass the actual threshold value; it will be divided by 1e6
///      - Thresholds are rounded down to the nearest 1e6
///      - IMPORTANT: Thresholds below THRESHOLD_SCALE (1e6) round down to 0, effectively disabling
///        large transfer restrictions. To enforce a threshold, use values >= 1e6.
///
///      **Address status behavior:**
///      - NONE: Check validator contract. If validator is address(0), allow transfer.
///      - WHITELIST: Allowed for amounts below threshold. Blocked if amount >= threshold.
///      - BLOCKLIST: Always blocked.
///      - WHITELIST_ALL_AMOUNTS: Always allowed (for large transfers).
///
///      **Validation logic:**
///      1. If token is paused → block all transfers
///      2. Check `from` status (skip for mints where from == address(0))
///      3. Check `to` status (skip for burns where to == address(0))
///      4. For threshold checks: amount >= threshold AND threshold > 0 requires WHITELIST_ALL_AMOUNTS
///
///      **Roles:**
///      - Owner: Full control (set token config, manage roles)
///      - COMPLIANCE_ROLE: Manage address statuses
///      - PAUSER_ROLE: Pause/unpause tokens
contract TransferGuard is ITransferGuard, OwnableRoles, Initializable {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Scale factor for threshold storage.
  /// @dev Threshold is stored as (actualThreshold / THRESHOLD_SCALE) to fit in 88 bits.
  ///      This gives us 1e6 granularity, which is sufficient since no common token has
  ///      less than 6 decimals. For 18-decimal tokens, minimum threshold granularity is 0.000001 tokens.
  ///      Maximum representable threshold: 2^88 * 1e6 ≈ 3.09e32
  uint256 public constant THRESHOLD_SCALE = 1e6;

  /// @dev Role for managing address statuses.
  uint256 public constant COMPLIANCE_ROLE = _ROLE_0;

  /// @dev Role for pausing/unpausing tokens.
  uint256 public constant PAUSER_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Status of each address (blocklist, whitelist, or delegate to validator).
  mapping(address account => AddressStatus status) public addressStatus;

  /// @notice Per-token configuration (paused, scaledThreshold, validator) packed in one slot.
  /// @dev Use getThreshold() to get the actual (unscaled) threshold value.
  mapping(address token => TokenConfig config) public tokenConfig;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when an address status is updated.
  event AddressStatusSet(address indexed account, AddressStatus status);

  /// @notice Emitted when a token's configuration is updated.
  /// @param token The token address
  /// @param paused Whether the token is paused
  /// @param threshold The actual (unscaled) threshold value
  /// @param validator The validator contract address
  event TokenConfigSet(address indexed token, bool paused, uint256 threshold, address validator);

  /// @notice Emitted when a token is paused.
  /// @param token The token that was paused
  event TokenPaused(address indexed token);

  /// @notice Emitted when a token is unpaused.
  /// @param token The token that was unpaused
  event TokenUnpaused(address indexed token);

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

    // Scale up threshold for comparison
    uint256 actualThreshold = uint256(config.scaledThreshold) * THRESHOLD_SCALE;
    bool isLargeTransfer = actualThreshold > 0 && amount >= actualThreshold;

    // Check sender (skip for mints)
    if (from != address(0) && !_isAllowed(from, isLargeTransfer, config.validator)) {
      return false;
    }

    // Check recipient (skip for burns)
    if (to != address(0) && !_isAllowed(to, isLargeTransfer, config.validator)) {
      return false;
    }

    return true;
  }

  /// @inheritdoc ITransferGuard
  function paused(address token) external view returns (bool) {
    return tokenConfig[token].paused;
  }

  /// @notice Returns the actual (unscaled) threshold for a token.
  /// @param token The token address
  /// @return The actual threshold value (scaledThreshold * THRESHOLD_SCALE)
  function getThreshold(address token) external view returns (uint256) {
    return uint256(tokenConfig[token].scaledThreshold) * THRESHOLD_SCALE;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    INTERNAL FUNCTIONS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Checks if an address is allowed based on its status and transfer size.
  /// @param account The address to check
  /// @param isLargeTransfer Whether this is a large transfer (>= threshold)
  /// @param validator The validator contract for this token
  /// @return True if allowed, false otherwise
  function _isAllowed(address account, bool isLargeTransfer, address validator) internal view returns (bool) {
    AddressStatus status = addressStatus[account];

    if (status == AddressStatus.BLOCKLIST) {
      return false;
    }

    if (status == AddressStatus.WHITELIST_ALL_AMOUNTS) {
      return true;
    }

    if (status == AddressStatus.WHITELIST) {
      // Whitelisted but only for small transfers
      return !isLargeTransfer;
    }

    // status == AddressStatus.NONE: delegate to validator
    if (validator == address(0)) {
      // No validator set - allow by default but block large transfers
      return !isLargeTransfer;
    }

    // Check validator - if authorized, treat as WHITELIST (small transfers only)
    // Large transfers still require explicit WHITELIST_ALL_AMOUNTS
    if (!ITransferGuardValidator(validator).isAuthorized(account)) {
      return false;
    }
    return !isLargeTransfer;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     COMPLIANCE FUNCTIONS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the status of an address.
  /// @param account The address to update
  /// @param status The new status
  function setAddressStatus(address account, AddressStatus status) external onlyOwnerOrRoles(COMPLIANCE_ROLE) {
    addressStatus[account] = status;
    emit AddressStatusSet(account, status);
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
      emit AddressStatusSet(accounts[i], status);
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
  /// @dev The threshold is scaled down by THRESHOLD_SCALE (1e6) for storage.
  ///      Effective threshold will be rounded down to the nearest multiple of THRESHOLD_SCALE.
  ///      WARNING: Values below THRESHOLD_SCALE (1e6) will round to 0, disabling large transfer restrictions.
  /// @param token The token to configure
  /// @param paused_ Whether transfers should be paused
  /// @param threshold_ Actual transfer threshold (0 to disable). Will be divided by THRESHOLD_SCALE for storage.
  ///                   Must be >= THRESHOLD_SCALE (1e6) to take effect, or 0 to disable.
  /// @param validator_ Validator contract for NONE status addresses (address(0) to allow by default)
  function setTokenConfig(address token, bool paused_, uint256 threshold_, address validator_) external onlyOwner {
    // Scale down threshold for storage (rounds down, reverts on overflow)
    uint88 scaledThreshold = SafeCastLib.toUint88(threshold_ / THRESHOLD_SCALE);
    tokenConfig[token] = TokenConfig({paused: paused_, scaledThreshold: scaledThreshold, validator: validator_});
    // Emit actual threshold (may be slightly less than input due to rounding)
    emit TokenConfigSet(token, paused_, uint256(scaledThreshold) * THRESHOLD_SCALE, validator_);
  }
}
