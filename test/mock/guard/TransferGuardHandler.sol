// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransferGuard, TokenConfig} from "src/guard/TransferGuard.sol";
import {AddressStatus} from "src/interfaces/guard/ITransferGuard.sol";

/// @title TransferGuardHandler
/// @notice Invariant-test handler that drives state transitions on a TransferGuard
///         instance and maintains ghost state for verification.
contract TransferGuardHandler is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  TransferGuard public guard;
  address public owner;

  bool public initialized;

  /// @notice Fixed set of addresses used across all handler actions.
  address[] public accounts;

  /// @notice Fixed set of token addresses used across all handler actions.
  address[] public tokens;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        GHOST STATE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mirror of the on-chain address status for each account.
  mapping(address => AddressStatus) public ghostStatus;

  /// @notice Mirror of whether a token is currently paused.
  mapping(address => bool) public ghostPaused;

  /// @notice Mirror of whether a token is in whitelist mode.
  mapping(address => bool) public ghostWhitelist;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Initializes the handler with a guard instance and its owner.
  /// @param guard_ The TransferGuard contract under test.
  /// @param owner_ The owner address that will execute privileged calls.
  function initialize(TransferGuard guard_, address owner_) external {
    require(!initialized, "already initialized");
    initialized = true;

    guard = guard_;
    owner = owner_;

    // 5 fixed accounts
    accounts.push(makeAddr("account0"));
    accounts.push(makeAddr("account1"));
    accounts.push(makeAddr("account2"));
    accounts.push(makeAddr("account3"));
    accounts.push(makeAddr("account4"));

    // 3 fixed token addresses
    tokens.push(makeAddr("token0"));
    tokens.push(makeAddr("token1"));
    tokens.push(makeAddr("token2"));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the full array of test accounts.
  function getAccounts() external view returns (address[] memory) {
    return accounts;
  }

  /// @notice Returns the full array of test tokens.
  function getTokens() external view returns (address[] memory) {
    return tokens;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      HANDLER ACTIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Sets the address status of a randomly-selected account.
  /// @param accountSeed Seed used to pick an account from the fixed set.
  /// @param statusSeed Seed used to pick a status (NONE=0, WHITELIST=1, BLOCKLIST=2).
  function act_setAddressStatus(uint256 accountSeed, uint256 statusSeed) external {
    address account = accounts[accountSeed % accounts.length];
    AddressStatus status = AddressStatus(statusSeed % 3);

    vm.prank(owner);
    guard.setAddressStatus(account, status);

    ghostStatus[account] = status;
  }

  /// @notice Sets the full token configuration for a randomly-selected token.
  /// @param tokenSeed Seed used to pick a token from the fixed set.
  /// @param paused_ Whether the token should be paused (permanent pause when true).
  /// @param whitelist_ Whether the token should use whitelist mode.
  function act_setTokenConfig(uint256 tokenSeed, bool paused_, bool whitelist_) external {
    address token = tokens[tokenSeed % tokens.length];

    vm.prank(owner);
    guard.setTokenConfig(token, paused_, whitelist_);

    ghostPaused[token] = paused_;
    ghostWhitelist[token] = whitelist_;
  }

  /// @notice Pauses a randomly-selected token for a bounded duration.
  /// @param tokenSeed Seed used to pick a token from the fixed set.
  /// @param duration Raw duration value, bounded to [1, 365 days].
  function act_pauseFor(uint256 tokenSeed, uint256 duration) external {
    address token = tokens[tokenSeed % tokens.length];
    duration = _bound(duration, 1, 365 days);

    vm.prank(owner);
    guard.pauseFor(token, duration);

    ghostPaused[token] = true;
  }

  /// @notice Unpauses a randomly-selected token.
  /// @param tokenSeed Seed used to pick a token from the fixed set.
  function act_unpause(uint256 tokenSeed) external {
    address token = tokens[tokenSeed % tokens.length];

    vm.prank(owner);
    guard.unpause(token);

    ghostPaused[token] = false;
  }

  /// @notice Warps block.timestamp forward and updates ghost pause state for any expired pauses.
  /// @param seconds_ Raw warp value, bounded to [1, 365 days].
  function act_warpTime(uint256 seconds_) external {
    seconds_ = _bound(seconds_, 1, 365 days);
    vm.warp(block.timestamp + seconds_);

    // Reconcile ghost pause state: any timed pause that has expired should be marked unpaused.
    for (uint256 i = 0; i < tokens.length; i++) {
      (uint40 pausedUntil,) = guard.tokenConfig(tokens[i]);
      if (pausedUntil != 0 && pausedUntil != type(uint40).max && block.timestamp > pausedUntil) {
        ghostPaused[tokens[i]] = false;
      }
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 DEPENDENCY-GRAPH ACTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Permanently pauses a randomly-selected token.
  /// @dev Unlike act_pauseFor (timed), this sets pausedUntil = type(uint40).max
  ///      which cannot be recovered by time warping.
  /// @param tokenSeed Seed used to pick a token from the fixed set.
  function act_permanentPause(uint256 tokenSeed) external {
    address token = tokens[tokenSeed % tokens.length];

    vm.prank(owner);
    guard.pause(token);

    ghostPaused[token] = true;
  }

  /// @notice Sets address status in batch for multiple accounts.
  /// @dev Exercises the setAddressStatusBatch code path rather than single-address updates.
  /// @param statusSeed Seed for status selection.
  /// @param countSeed Seed for choosing how many accounts to update (2-3).
  function act_setAddressStatusBatch(uint256 statusSeed, uint256 countSeed) external {
    AddressStatus status = AddressStatus(statusSeed % 3);
    uint256 count = _bound(countSeed, 2, 3);
    if (count > accounts.length) count = accounts.length;

    address[] memory batch = new address[](count);
    for (uint256 i = 0; i < count; i++) {
      batch[i] = accounts[(statusSeed + i) % accounts.length];
    }

    vm.prank(owner);
    guard.setAddressStatusBatch(batch, status);

    for (uint256 i = 0; i < count; i++) {
      ghostStatus[batch[i]] = status;
    }
  }

  /// @notice Toggles whitelist mode for a randomly-selected token without changing pause state.
  /// @dev Flips the whitelist flag via setTokenConfig, preserving the current pausedUntil.
  /// @param tokenSeed Seed used to pick a token from the fixed set.
  function act_toggleWhitelistMode(uint256 tokenSeed) external {
    address token = tokens[tokenSeed % tokens.length];

    (uint40 pausedUntil, bool currentWhitelist) = guard.tokenConfig(token);

    // Determine if currently paused for setTokenConfig's bool param
    bool isPaused = pausedUntil != 0 && (pausedUntil == type(uint40).max || block.timestamp <= pausedUntil);

    vm.prank(owner);
    guard.setTokenConfig(token, isPaused, !currentWhitelist);

    ghostWhitelist[token] = !currentWhitelist;
  }
}
