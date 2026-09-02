// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibChecks} from "../common/LibChecks.sol";
import {LibFacilityErrors} from "./LibFacilityErrors.sol";
import {IFacilityCaps} from "../../interfaces/facility/IFacilityCaps.sol";

/// @dev Deposit cap types, encoded in the top byte of a cap word.
/// @param ABSOLUTE The word is the remaining deposit capacity of the intent.
/// @param DYNAMIC The word encodes a shared IFacilityCaps pool.
enum CapType {
  ABSOLUTE,
  DYNAMIC
}

/// @title LibCaps
/// @author 3F Protocol
/// @notice Encoding, consumption and release of intent deposit caps.
/// @dev A deposit cap is a single uint256 word whose top byte selects the cap type:
///      - ABSOLUTE (0): the word is the remaining deposit capacity of the intent, decremented
///        by deposits and restored by releases. Caps deployed before cap types existed have a
///        zero top byte, so they read as ABSOLUTE.
///      - DYNAMIC (1): the word points at a shared pool in an IFacilityCaps contract that
///        deposits consume and releases give back.
///
///      DYNAMIC word layout (msb -> lsb):
///      | 8 bits type | 32 bits unused | 24 bits multiplier | 32 bits id | 160 bits caps address |
///
///      The multiplier is a signed Q12.12 fixed-point value applied to deposited amounts
///      (typically leverage - 1). Withdrawal-side intents encode a negative multiplier so their
///      deposits release capacity into the pool instead of consuming it.
///
///      consume() and release() return the new word for the caller to store, so the library
///      stays free of storage references.
library LibCaps {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Bit offset of the cap type.
  uint256 internal constant TYPE_OFFSET = 248;
  /// @notice Bit offset of the signed Q12.12 multiplier.
  uint256 internal constant MULTIPLIER_OFFSET = 192;
  /// @notice Bit offset of the pool ID.
  uint256 internal constant ID_OFFSET = 160;

  /// @notice Mask of the 24-bit signed Q12.12 multiplier field.
  uint256 internal constant MULTIPLIER_MASK = (1 << 24) - 1;
  /// @notice Mask of the 32-bit pool ID field.
  uint256 internal constant ID_MASK = (1 << 32) - 1;
  /// @notice Mask of the 160-bit caps address field.
  uint256 internal constant ADDRESS_MASK = (1 << 160) - 1;
  /// @notice Mask of the unused bits of a DYNAMIC word, between the multiplier and the type
  ///         byte (must be zero).
  uint256 internal constant UNUSED_MASK =
    ((1 << (TYPE_OFFSET - MULTIPLIER_OFFSET - 24)) - 1) << (MULTIPLIER_OFFSET + 24);
  /// @notice Maximum value of an ABSOLUTE cap (all bits below the type byte).
  uint256 internal constant MAX_ABSOLUTE = (1 << TYPE_OFFSET) - 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ENCODING                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the cap type encoded in the top byte of a cap word.
  /// @dev Assumes a validated word: the raw byte is not range-checked, so only call this on
  ///      words that went through validate() (unknown type bytes would yield an out-of-range
  ///      enum value).
  /// @param self The encoded deposit cap word.
  /// @return _type The cap type.
  function capType(uint256 self) internal pure returns (CapType _type) {
    assembly ("memory-safe") {
      _type := shr(TYPE_OFFSET, self)
    }
  }

  /// @notice Encodes a DYNAMIC deposit cap word.
  /// @param caps The IFacilityCaps contract holding the shared pool.
  /// @param id The pool ID in the caps contract.
  /// @param multiplier The signed Q12.12 multiplier applied to deposited amounts.
  /// @return word The encoded deposit cap word.
  function encodeDynamic(address caps, uint32 id, int24 multiplier) internal pure returns (uint256 word) {
    uint256 _type = uint256(CapType.DYNAMIC);
    assembly ("memory-safe") {
      word := or(
        or(shl(TYPE_OFFSET, _type), shl(MULTIPLIER_OFFSET, and(multiplier, MULTIPLIER_MASK))),
        or(shl(ID_OFFSET, and(id, ID_MASK)), and(caps, ADDRESS_MASK))
      )
    }
  }

  /// @notice Decodes the pool reference of a DYNAMIC deposit cap word.
  /// @param self The encoded deposit cap word.
  /// @return caps The IFacilityCaps contract holding the shared pool.
  /// @return id The pool ID in the caps contract.
  /// @return multiplier The signed Q12.12 multiplier applied to deposited amounts.
  function decodeDynamic(uint256 self) internal pure returns (IFacilityCaps caps, uint32 id, int24 multiplier) {
    assembly ("memory-safe") {
      caps := and(self, ADDRESS_MASK)
      id := and(shr(ID_OFFSET, self), ID_MASK)
      // sign-extend from byte index 2 to recover the 24-bit signed multiplier
      multiplier := signextend(2, shr(MULTIPLIER_OFFSET, self))
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        VALIDATION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Validates a deposit cap word before it is stored.
  /// @dev Reverts with InvalidDepositCap if the type byte is unknown, if a DYNAMIC word has
  ///      non-zero unused bits, or if its multiplier is type(int24).min (which has no int24
  ///      negation, so release() could never flip its direction). Reverts with InvalidContract
  ///      if a DYNAMIC word points at a codeless address: consume() returns no data, so a call
  ///      to such an address would silently succeed and disable the cap entirely.
  /// @param self The encoded deposit cap word.
  function validate(uint256 self) internal view {
    // compare the raw byte: an unknown type must be rejected before it can be read as a CapType
    uint256 rawType = self >> TYPE_OFFSET;
    if (rawType > uint256(CapType.DYNAMIC)) revert LibFacilityErrors.InvalidDepositCap(self);
    if (rawType == uint256(CapType.DYNAMIC)) {
      if (self & UNUSED_MASK != 0) revert LibFacilityErrors.InvalidDepositCap(self);
      (IFacilityCaps caps,, int24 multiplier) = decodeDynamic(self);
      if (multiplier == type(int24).min) revert LibFacilityErrors.InvalidDepositCap(self);
      LibChecks.checkContract(address(caps));
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSUMPTION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Consumes the deposit cap for a deposit of `amount`.
  /// @dev ABSOLUTE: reverts with DepositCapExceeded if the amount exceeds the remaining
  ///      capacity, and returns the decremented word. DYNAMIC: consumes amount x multiplier
  ///      from the shared pool (a negative multiplier releases capacity into the pool instead)
  ///      and returns the word unchanged.
  /// @param self The encoded deposit cap word.
  /// @param intentId The intent ID (used for error reporting).
  /// @param amount The amount being deposited.
  /// @return newCap The new cap word to store.
  function consume(uint256 self, uint256 intentId, uint256 amount) internal returns (uint256 newCap) {
    if (capType(self) == CapType.DYNAMIC) return _poolConsume(self, amount, false);
    if (amount > self) revert LibFacilityErrors.DepositCapExceeded(intentId, self, amount);
    unchecked {
      return self - amount;
    }
  }

  /// @notice Releases the cap consumption of a deposit of `amount` being undone.
  /// @dev ABSOLUTE: returns the restored word, saturating at MAX_ABSOLUTE so a release can
  ///      never overflow into the type byte. DYNAMIC: consumes with the opposite multiplier,
  ///      giving back exactly the direction the deposit took from the pool, and returns the
  ///      word unchanged.
  /// @param self The encoded deposit cap word.
  /// @param amount The deposited amount being undone.
  /// @return newCap The new cap word to store.
  function release(uint256 self, uint256 amount) internal returns (uint256 newCap) {
    if (capType(self) == CapType.DYNAMIC) return _poolConsume(self, amount, true);
    unchecked {
      newCap = self + amount;
    }
    if (newCap < self || newCap > MAX_ABSOLUTE) newCap = MAX_ABSOLUTE;
  }

  /// @dev Consumes `amount` from a DYNAMIC word's shared pool with the word's multiplier
  ///      (`negate = false`) or its opposite (`negate = true`, the release direction). One call
  ///      site for both directions keeps the external-call encoding out of every consumer twice.
  /// @param self The encoded DYNAMIC deposit cap word.
  /// @param amount The amount being consumed or released.
  /// @param negate Whether to flip the multiplier's direction.
  /// @return The word, unchanged (pool state lives in the caps contract).
  function _poolConsume(uint256 self, uint256 amount, bool negate) private returns (uint256) {
    (IFacilityCaps caps, uint32 id, int24 multiplier) = decodeDynamic(self);
    caps.consume(id, amount, negate ? -multiplier : multiplier);
    return self;
  }
}
