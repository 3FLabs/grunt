// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TransferGuard, TokenConfig} from "src/guard/TransferGuard.sol";
import {AddressStatus} from "src/interfaces/guard/ITransferGuard.sol";
import {TransferGuardHandler} from "test/mock/guard/TransferGuardHandler.sol";

/// @title TransferGuardInvariantTest
/// @notice Invariant test suite for the TransferGuard contract.
/// @dev Uses a handler-based approach: TransferGuardHandler drives random state
///      transitions (address status changes, token config changes, pause/unpause,
///      time warps) while the invariant functions verify that the guard's
///      canTransfer logic stays consistent with the documented rules.
contract TransferGuardInvariantTest is StdInvariant, Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  TransferGuard public guard;
  TransferGuardHandler public handler;
  address public owner;

  /// @dev A neutral address (NONE status, never modified) used as counterpart
  ///      in single-sided checks. Computed deterministically in setUp.
  address public otherAllowed;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    owner = makeAddr("owner");
    guard = new TransferGuard();
    guard.initialize(owner);

    handler = new TransferGuardHandler();
    handler.initialize(guard, owner);

    otherAllowed = makeAddr("other_allowed");

    // Register only the handler actions as target selectors.
    bytes4[] memory selectors = new bytes4[](5);
    selectors[0] = handler.act_setAddressStatus.selector;
    selectors[1] = handler.act_setTokenConfig.selector;
    selectors[2] = handler.act_pauseFor.selector;
    selectors[3] = handler.act_unpause.selector;
    selectors[4] = handler.act_warpTime.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INVARIANTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice TG-1: BLOCKLIST addresses are always blocked regardless of token mode.
  /// @dev For every account with BLOCKLIST status, `canTransfer` must return false
  ///      for that account as either sender or receiver, across all non-paused tokens.
  ///      Uses a fresh "other" address with default NONE status; in blocklist mode
  ///      NONE is allowed so the only reason for denial is the BLOCKLIST status.
  function invariant_blocklistAlwaysBlocked() public view {
    address[] memory accts = handler.getAccounts();
    address[] memory tkns = handler.getTokens();

    for (uint256 i = 0; i < accts.length; i++) {
      if (guard.addressStatus(accts[i]) != AddressStatus.BLOCKLIST) continue;

      for (uint256 j = 0; j < tkns.length; j++) {
        if (guard.paused(tkns[j])) continue; // skip paused tokens

        // Blocklisted as sender
        assertFalse(guard.canTransfer(tkns[j], accts[i], otherAllowed, 1), "TG-1: BLOCKLIST sender allowed");
        // Blocklisted as receiver
        assertFalse(guard.canTransfer(tkns[j], otherAllowed, accts[i], 1), "TG-1: BLOCKLIST receiver allowed");
      }
    }
  }

  /// @notice TG-2: WHITELIST addresses can always transfer between each other when token is not paused.
  /// @dev For every pair of accounts that both have WHITELIST status, `canTransfer`
  ///      must return true on all non-paused tokens. This holds in both blocklist and
  ///      whitelist token modes.
  function invariant_whitelistAlwaysAllowed() public view {
    address[] memory accts = handler.getAccounts();
    address[] memory tkns = handler.getTokens();

    for (uint256 i = 0; i < accts.length; i++) {
      if (guard.addressStatus(accts[i]) != AddressStatus.WHITELIST) continue;

      for (uint256 j = 0; j < accts.length; j++) {
        if (guard.addressStatus(accts[j]) != AddressStatus.WHITELIST) continue;

        for (uint256 k = 0; k < tkns.length; k++) {
          if (guard.paused(tkns[k])) continue;
          assertTrue(guard.canTransfer(tkns[k], accts[i], accts[j], 1), "TG-2: WHITELIST pair blocked");
        }
      }
    }
  }

  /// @notice TG-3: NONE addresses behave according to the token's mode.
  /// @dev For every pair of NONE-status accounts:
  ///      - In blocklist mode (whitelist=false): canTransfer returns true (NONE is allowed).
  ///      - In whitelist mode (whitelist=true): canTransfer returns false (NONE is blocked).
  function invariant_noneModeDependent() public view {
    address[] memory accts = handler.getAccounts();
    address[] memory tkns = handler.getTokens();

    for (uint256 i = 0; i < accts.length; i++) {
      if (guard.addressStatus(accts[i]) != AddressStatus.NONE) continue;

      for (uint256 j = 0; j < accts.length; j++) {
        if (guard.addressStatus(accts[j]) != AddressStatus.NONE) continue;

        for (uint256 k = 0; k < tkns.length; k++) {
          if (guard.paused(tkns[k])) continue;

          (, bool isWhitelist) = guard.tokenConfig(tkns[k]);
          bool result = guard.canTransfer(tkns[k], accts[i], accts[j], 1);

          if (isWhitelist) {
            assertFalse(result, "TG-3: NONE allowed in whitelist mode");
          } else {
            assertTrue(result, "TG-3: NONE blocked in blocklist mode");
          }
        }
      }
    }
  }

  /// @notice TG-4: A paused token blocks ALL transfers regardless of address status.
  /// @dev When `guard.paused(token)` is true, every combination of sender and
  ///      receiver from the test set must be denied.
  function invariant_pausedBlocksAll() public view {
    address[] memory accts = handler.getAccounts();
    address[] memory tkns = handler.getTokens();

    for (uint256 k = 0; k < tkns.length; k++) {
      if (!guard.paused(tkns[k])) continue;

      for (uint256 i = 0; i < accts.length; i++) {
        for (uint256 j = 0; j < accts.length; j++) {
          assertFalse(guard.canTransfer(tkns[k], accts[i], accts[j], 1), "TG-4: paused token allows transfer");
        }
      }
    }
  }

  /// @notice TG-5: Pause expiry is consistent with the pausedUntil timestamp.
  /// @dev Verifies three sub-properties:
  ///      - pausedUntil == 0 implies paused() is false.
  ///      - pausedUntil != 0, != max, and block.timestamp > pausedUntil implies paused() is false.
  ///      - pausedUntil == type(uint40).max implies paused() is true (permanent pause).
  function invariant_pauseExpiry() public view {
    address[] memory tkns = handler.getTokens();

    for (uint256 k = 0; k < tkns.length; k++) {
      (uint40 pausedUntil,) = guard.tokenConfig(tkns[k]);

      if (pausedUntil == 0) {
        assertFalse(guard.paused(tkns[k]), "TG-5: NOT_PAUSED but paused() returns true");
      }

      if (pausedUntil != 0 && pausedUntil != type(uint40).max && block.timestamp > pausedUntil) {
        assertFalse(guard.paused(tkns[k]), "TG-5: past pausedUntil but still paused");
      }

      if (pausedUntil == type(uint40).max) {
        assertTrue(guard.paused(tkns[k]), "TG-5: PERMANENT_PAUSE but not paused");
      }
    }
  }
}
