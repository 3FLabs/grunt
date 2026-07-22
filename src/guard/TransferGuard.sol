// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ITransferGuard, AddressStatus, TokenMode} from "../interfaces/guard/ITransferGuard.sol";
import {IPositionManager} from "../interfaces/manager/IPositionManager.sol";
import {IWrappedAsset} from "../interfaces/funds/IWrappedAsset.sol";
import {LibPause} from "../libs/common/LibPause.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @notice Per-token configuration packed into a single storage slot.
/// @param pausedUntil Pause-until timestamp (0 = not paused, type(uint40).max = permanent pause).
/// @param mode The token transfer mode (BLOCKLIST, WHITELIST, NATIVE_ONLY, NATIVE_WHITELIST).
/// @param checkCollateralAllowed If true, check the collateral asset's isAllowed for both parties.
/// @dev Layout: pausedUntil (40 bits) + mode (8 bits) + checkCollateralAllowed (8 bits) = 56 bits (fits in single slot)
struct TokenConfig {
  uint40 pausedUntil;
  TokenMode mode;
  bool checkCollateralAllowed;
}

/// @title TransferGuard
/// @author 3F Protocol
/// @notice Transfer validation with a single per-address status mapping and a per-token
///         configuration packed into one slot.
/// @dev Uses ERC-7201 namespaced storage; deployable behind a beacon proxy. Mode and status
///      semantics are documented on the {ITransferGuard} enums. See docs/transfer-guard.md#modes.
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
    /// @notice Status of each address (NONE, WHITELIST, BLOCKLIST, or NATIVE).
    mapping(address account => AddressStatus status) addressStatus;
    /// @notice Per-token configuration (paused, mode, collateral check) packed in one slot.
    mapping(address token => TokenConfig config) tokenConfig;
  }

  /// @dev Storage slot for TransferGuard.
  ///      keccak256(abi.encode(uint256(keccak256("transferguard.main")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _STORAGE_SLOT = 0xc6c8482afc451e8caac0099c996ccfb351ca947c4bbb65e7d1fc5f0e82e91c00;

  /// @dev Returns a pointer to the ERC-7201 namespaced storage struct.
  function _storage() internal pure returns (TransferGuardStorage storage $) {
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
  /// @return The address status (NONE, WHITELIST, BLOCKLIST, or NATIVE)
  function addressStatus(address account) external view returns (AddressStatus) {
    return _storage().addressStatus[account];
  }

  /// @notice Returns the per-token configuration.
  /// @param token The token address to query
  /// @return pausedUntil The pause-until timestamp
  /// @return mode The token's transfer mode
  /// @return checkCollateralAllowed Whether collateral isAllowed is checked
  function tokenConfig(address token)
    external
    view
    returns (uint40 pausedUntil, TokenMode mode, bool checkCollateralAllowed)
  {
    TokenConfig memory config = _storage().tokenConfig[token];
    return (config.pausedUntil, config.mode, config.checkCollateralAllowed);
  }

  /// @inheritdoc ITransferGuard
  function canTransfer(address token, address from, address to, uint256 amount) public view virtual returns (bool) {
    TransferGuardStorage storage $ = _storage();
    TokenConfig memory config = $.tokenConfig[token];

    if (config.pausedUntil.paused()) return false;

    // Read each status at most once (skip storage read for address(0))
    AddressStatus fromStatus = from != address(0) ? $.addressStatus[from] : AddressStatus.NONE;
    AddressStatus toStatus = to != address(0) ? $.addressStatus[to] : AddressStatus.NONE;

    // BLOCKLIST is always blocked in all modes
    if (fromStatus == AddressStatus.BLOCKLIST || toStatus == AddressStatus.BLOCKLIST) return false;

    // Each mode is a combination of two properties:
    //   noneBlocked:    WHITELIST, NATIVE_WHITELIST (NONE status addresses are blocked)
    //   nativeRequired: NATIVE_ONLY, NATIVE_WHITELIST (regular transfers need at least one NATIVE party)
    TokenMode mode = config.mode;
    bool noneBlocked = mode == TokenMode.WHITELIST || mode == TokenMode.NATIVE_WHITELIST;
    bool nativeRequired = mode >= TokenMode.NATIVE_ONLY;

    if (noneBlocked) {
      if (from != address(0) && fromStatus == AddressStatus.NONE) return false;
      if (to != address(0) && toStatus == AddressStatus.NONE) return false;
    }

    // Mints/burns bypass the NATIVE requirement (address(0) party is exempt)
    if (
      nativeRequired && from != address(0) && to != address(0) && fromStatus != AddressStatus.NATIVE
        && toStatus != AddressStatus.NATIVE
    ) {
      return false;
    }

    // Collateral asset isAllowed check
    if (config.checkCollateralAllowed) {
      (address collateral,) = IPositionManager(token).assets();
      if (from != address(0) && !IWrappedAsset(collateral).isAllowed(from, amount)) return false;
      if (to != address(0) && !IWrappedAsset(collateral).isAllowed(to, amount)) return false;
    }

    return true;
  }

  /// @inheritdoc ITransferGuard
  function paused(address token) external view returns (bool) {
    return _storage().tokenConfig[token].pausedUntil.paused();
  }

  /// @notice Returns the transfer mode for a token.
  /// @param token The token address
  /// @return The token's transfer mode
  function tokenMode(address token) external view returns (TokenMode) {
    return _storage().tokenConfig[token].mode;
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
  /// @param mode The transfer mode for this token
  /// @param checkCollateralAllowed Whether to check collateral asset's isAllowed
  function setTokenConfig(address token, bool paused_, TokenMode mode, bool checkCollateralAllowed) external onlyOwner {
    // converting to uint40 is safe because the result is less than 2^40
    // forge-lint: disable-next-line(unsafe-typecast)
    uint40 pausedUntil = uint40(paused_.ternary(LibPause.PERMANENT_PAUSE, LibPause.NOT_PAUSED));
    _storage().tokenConfig[token] =
      TokenConfig({pausedUntil: pausedUntil, mode: mode, checkCollateralAllowed: checkCollateralAllowed});
    emit TokenConfigSet(token, pausedUntil, mode, checkCollateralAllowed);
  }
}
