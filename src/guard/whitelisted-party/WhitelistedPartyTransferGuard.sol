// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ITransferGuard} from "../../interfaces/guard/ITransferGuard.sol";
import {LibPause} from "../../libs/common/LibPause.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {Initializable} from "lib/solady/src/utils/Initializable.sol";

/// @title WhitelistedPartyTransferGuard
/// @author 3F Protocol
/// @notice Transfer guard that allows transfers when at least one party is whitelisted.
/// @dev Designed for scenarios where a trusted protocol contract (e.g., the Facility) needs to
///      interact with any user. The Facility is whitelisted, so any transfer involving the Facility
///      as sender or receiver is permitted. Transfers between two non-whitelisted parties are blocked.
///
///      **Storage:** Uses ERC-7201 namespaced storage layout for proxy safety.
///
///      **Transfer validation logic:**
///      1. If token is paused → block all transfers
///      2. If either party is address(0) (mint or burn) → allow
///      3. If at least one party is whitelisted → allow
///      4. Otherwise → block
///
///      **Roles:**
///      - Owner: Full control (manage roles)
///      - _COMPLIANCE_ROLE: Manage whitelist entries
///      - _PAUSER_ROLE: Pause/unpause tokens
contract WhitelistedPartyTransferGuard is ITransferGuard, OwnableRoles, Initializable {
  using LibPause for uint40;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Role for managing whitelist entries.
  uint256 internal constant _COMPLIANCE_ROLE = _ROLE_0;

  /// @dev Role for pausing/unpausing tokens.
  uint256 internal constant _PAUSER_ROLE = _ROLE_1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a whitelist entry is updated.
  /// @param account The address whose whitelist status changed
  /// @param status Whether the address is now whitelisted
  event WhitelistedSet(address indexed account, bool status);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    ERC-7201 STORAGE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @custom:storage-location erc7201:whitelistedparty.transferguard.main
  struct WhitelistedPartyTransferGuardStorage {
    /// @notice Whether each address is whitelisted (can be one side of any transfer).
    mapping(address account => bool whitelisted) whitelisted;
    /// @notice Per-token pause timestamp.
    mapping(address token => uint40 pausedUntil) tokenPausedUntil;
  }

  /// @dev Storage slot for WhitelistedPartyTransferGuard.
  ///      keccak256(abi.encode(uint256(keccak256("whitelistedparty.transferguard.main")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _STORAGE_SLOT = 0x2c950b63c02b0e786e55b7b98d39e2c7dbd41fda0fb1cb0bf98b78f32b04a400;

  /// @dev Returns a pointer to the ERC-7201 namespaced storage struct.
  function _storage() internal pure returns (WhitelistedPartyTransferGuardStorage storage $) {
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

  /// @notice Returns whether an address is whitelisted.
  /// @param account The address to check
  /// @return True if whitelisted
  function isWhitelisted(address account) external view returns (bool) {
    return _storage().whitelisted[account];
  }

  /// @inheritdoc ITransferGuard
  /// @dev Allows a transfer if at least one non-null party is whitelisted.
  ///      Mints (from == address(0)) and burns (to == address(0)) are always allowed
  ///      (only pause can block them) since they are protocol operations, not peer-to-peer transfers.
  ///      For transfers between two non-null addresses, at least one must be whitelisted.
  function canTransfer(address token, address from, address to, uint256 amount) public view virtual returns (bool) {
    WhitelistedPartyTransferGuardStorage storage $ = _storage();

    // Check pause status
    if ($.tokenPausedUntil[token].paused()) return false;

    // Mints and burns are always allowed (not restricted by whitelist)
    if (from == address(0) || to == address(0)) return true;

    // For transfers between two real addresses, at least one must be whitelisted
    return $.whitelisted[from] || $.whitelisted[to];
  }

  /// @inheritdoc ITransferGuard
  function paused(address token) external view returns (bool) {
    return _storage().tokenPausedUntil[token].paused();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     COMPLIANCE FUNCTIONS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the whitelist status of an address.
  /// @param account The address to update
  /// @param status Whether the address should be whitelisted
  function setWhitelisted(address account, bool status) external onlyOwnerOrRoles(_COMPLIANCE_ROLE) {
    _storage().whitelisted[account] = status;
    emit WhitelistedSet(account, status);
  }

  /// @notice Batch update whitelist entries.
  /// @param accounts The addresses to update
  /// @param status Whether the addresses should be whitelisted
  function setWhitelistedBatch(address[] calldata accounts, bool status) external onlyOwnerOrRoles(_COMPLIANCE_ROLE) {
    WhitelistedPartyTransferGuardStorage storage $ = _storage();
    for (uint256 i = 0; i < accounts.length; ++i) {
      $.whitelisted[accounts[i]] = status;
      emit WhitelistedSet(accounts[i], status);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      PAUSE FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pauses all transfers for a token indefinitely.
  /// @param token The token to pause
  function pause(address token) external onlyOwnerOrRoles(_PAUSER_ROLE) {
    _storage().tokenPausedUntil[token] = LibPause.PERMANENT_PAUSE;
    emit TokenPausedSet(token, LibPause.PERMANENT_PAUSE);
  }

  /// @notice Pauses all transfers for a token for a specified duration.
  /// @param token The token to pause
  /// @param duration The duration to pause for (in seconds)
  function pauseFor(address token, uint256 duration) external onlyOwnerOrRoles(_PAUSER_ROLE) {
    uint40 pauseUntil = LibPause.pauseFor(duration);
    _storage().tokenPausedUntil[token] = pauseUntil;
    emit TokenPausedSet(token, pauseUntil);
  }

  /// @notice Unpauses transfers for a token.
  /// @param token The token to unpause
  function unpause(address token) external onlyOwnerOrRoles(_PAUSER_ROLE) {
    _storage().tokenPausedUntil[token] = LibPause.NOT_PAUSED;
    emit TokenPausedSet(token, LibPause.NOT_PAUSED);
  }
}
