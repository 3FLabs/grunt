// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibFacilityErrors} from "./LibFacilityErrors.sol";
import {IFacilityCaps} from "../../interfaces/facility/IFacilityCaps.sol";
import {IFacilityCapsWhitelist} from "../../interfaces/facility/IFacilityCapsWhitelist.sol";

/// @dev Deposit cap types, encoded in the top byte of a cap word.
/// @param ABSOLUTE The word is a plain amount (see LibCaps for how each consumer reads it).
/// @param EXTERNAL The word references a cap in an IFacilityCaps contract.
enum CapType {
  ABSOLUTE,
  EXTERNAL
}

/// @title LibCaps
/// @author 3F Protocol
/// @notice Encoding, consumption and release of intent deposit caps.
/// @dev A deposit cap is a single uint256 word whose top byte selects the cap type:
///      - ABSOLUTE (0): the word is a plain amount. Intents read it as their max total supply
///        (LibIntent checks it and never writes it), so caps deployed before cap types existed
///        keep their meaning. consume() reads it as a remaining budget and decrements it.
///      - EXTERNAL (1): the word points at a cap in an IFacilityCaps contract that deposits
///        consume and releases give back (FacilityAbsoluteCaps) or ignore (FacilityDynamicCaps).
///
///      EXTERNAL word layout (msb -> lsb):
///      | 8 bits type | 24 bits multiplier | 64 bits id | 160 bits caps address |
///
///      The 64-bit id is passed to the caps contract as is and each implementation reads it its
///      own way (FacilityAbsoluteCaps splits it into four 16-bit pool IDs) and validates it.
///
///      The multiplier is a signed Q12.12 fixed-point value applied to deposited amounts
///      (typically leverage - 1). Withdrawal-side intents encode a negative multiplier so their
///      deposits take the release direction and their withdrawals the consume direction.
///
///      consume() and release() return the new word for the caller to store, so the library
///      stays free of storage references.
///
///      Known limitation: with an EXTERNAL word, releases (withdraw, revertDeposit) are
///      state-changing calls into the caps contract and revert when it does: pool at its hard
///      cap, cap drained under a negative multiplier, or consumer role revoked. The facilitator
///      can change the word in any intent state and the caps manager can adjust the cap, either
///      of which unblocks them.
library LibCaps {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Bit offset of the cap type.
  uint256 internal constant TYPE_OFFSET = 248;
  /// @notice Bit offset of the signed Q12.12 multiplier.
  uint256 internal constant MULTIPLIER_OFFSET = 224;
  /// @notice Bit offset of the cap ID.
  uint256 internal constant ID_OFFSET = 160;

  /// @notice Mask of the 24-bit signed Q12.12 multiplier field.
  uint256 internal constant MULTIPLIER_MASK = (1 << 24) - 1;
  /// @notice Mask of the 64-bit cap ID field.
  uint256 internal constant ID_MASK = (1 << 64) - 1;
  /// @notice Mask of the 160-bit caps address field.
  uint256 internal constant ADDRESS_MASK = (1 << 160) - 1;
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

  /// @notice Encodes a EXTERNAL deposit cap word.
  /// @param caps The IFacilityCaps contract holding the cap.
  /// @param id The cap ID in the caps contract.
  /// @param multiplier The signed Q12.12 multiplier applied to deposited amounts.
  /// @return word The encoded deposit cap word.
  function encodeExternal(address caps, uint64 id, int24 multiplier) internal pure returns (uint256 word) {
    uint256 _type = uint256(CapType.EXTERNAL);
    assembly ("memory-safe") {
      word := or(
        or(shl(TYPE_OFFSET, _type), shl(MULTIPLIER_OFFSET, and(multiplier, MULTIPLIER_MASK))),
        or(shl(ID_OFFSET, and(id, ID_MASK)), and(caps, ADDRESS_MASK))
      )
    }
  }

  /// @notice Decodes the cap reference of a EXTERNAL deposit cap word.
  /// @param self The encoded deposit cap word.
  /// @return caps The IFacilityCaps contract holding the cap.
  /// @return id The cap ID in the caps contract.
  /// @return multiplier The signed Q12.12 multiplier applied to deposited amounts.
  function decodeExternal(uint256 self) internal pure returns (IFacilityCaps caps, uint64 id, int24 multiplier) {
    assembly ("memory-safe") {
      caps := and(self, ADDRESS_MASK)
      id := and(shr(ID_OFFSET, self), ID_MASK)
      // sign-extend from byte index 2 to recover the 24-bit signed multiplier
      multiplier := signextend(2, shr(MULTIPLIER_OFFSET, self))
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the amount consume() can absorb right now.
  /// @dev ABSOLUTE: the word itself. EXTERNAL: the caps contract's quote under the word's
  ///      multiplier (type(uint256).max when that direction is unbounded). Assumes a validated word.
  /// @param self The encoded deposit cap word.
  /// @return amount The maximum consumable amount.
  function available(uint256 self) internal view returns (uint256 amount) {
    if (capType(self) == CapType.EXTERNAL) {
      (IFacilityCaps caps, uint64 id, int24 multiplier) = decodeExternal(self);
      return caps.available(id, multiplier);
    }
    return self;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        VALIDATION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Validates a deposit cap word before it is stored.
  /// @dev Reverts with InvalidDepositCap if the type byte is unknown. Reverts with CapsNotAllowed
  ///      if an EXTERNAL word points at a caps contract the whitelist does not allow: consume()
  ///      returns no data, so a call to an arbitrary address would silently succeed and disable
  ///      the cap. The id and multiplier are then checked by the caps contract itself
  ///      (IFacilityCaps.validate).
  /// @param self The encoded deposit cap word.
  /// @param whitelist The registry of allowed caps contracts.
  function validate(uint256 self, IFacilityCapsWhitelist whitelist) internal view {
    // compare the raw byte: an unknown type must be rejected before it can be read as a CapType
    uint256 rawType = self >> TYPE_OFFSET;
    if (rawType > uint256(CapType.EXTERNAL)) revert LibFacilityErrors.InvalidDepositCap(self);
    if (rawType == uint256(CapType.EXTERNAL)) {
      (IFacilityCaps caps, uint64 id, int24 multiplier) = decodeExternal(self);
      if (!whitelist.isAllowed(address(caps))) revert LibFacilityErrors.CapsNotAllowed(address(caps));
      caps.validate(id, multiplier);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSUMPTION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Consumes the deposit cap for a deposit of `amount`.
  /// @dev ABSOLUTE: reverts with CapExceeded if the amount exceeds the remaining budget, and
  ///      returns the decremented word. EXTERNAL: consumes amount x multiplier
  ///      from the caps contract (a negative multiplier takes the release direction instead)
  ///      and returns the word unchanged.
  /// @param self The encoded deposit cap word.
  /// @param capId The consumer's cap ID (used for error reporting).
  /// @param amount The amount being deposited.
  /// @return newCap The new cap word to store.
  function consume(uint256 self, uint256 capId, uint256 amount) internal returns (uint256 newCap) {
    if (capType(self) == CapType.EXTERNAL) return _poolConsume(self, amount, false);
    if (amount > self) revert LibFacilityErrors.CapExceeded(capId, self, amount);
    unchecked {
      return self - amount;
    }
  }

  /// @notice Releases the cap consumption of a deposit of `amount` being undone.
  /// @dev ABSOLUTE: no-op, the word is never restored. EXTERNAL: consumes with the opposite
  ///      multiplier, reversing the direction the deposit took in the caps contract. The word
  ///      never changes, so there is nothing to store.
  /// @param self The encoded deposit cap word.
  /// @param amount The deposited amount being undone.
  function release(uint256 self, uint256 amount) internal {
    if (capType(self) == CapType.EXTERNAL) _poolConsume(self, amount, true);
  }

  /// @dev Consumes `amount` from a EXTERNAL word's caps contract with the word's multiplier
  ///      (`negate = false`) or its opposite (`negate = true`, the release direction). One call
  ///      site for both directions keeps the external-call encoding out of every consumer twice.
  /// @param self The encoded EXTERNAL deposit cap word.
  /// @param amount The amount being consumed or released.
  /// @param negate Whether to flip the multiplier's direction.
  /// @return The word, unchanged (cap state lives in the caps contract).
  function _poolConsume(uint256 self, uint256 amount, bool negate) private returns (uint256) {
    (IFacilityCaps caps, uint64 id, int24 multiplier) = decodeExternal(self);
    // validate() rejects type(int24).min, so the negation cannot overflow
    unchecked {
      caps.consume(id, amount, negate ? -multiplier : multiplier);
    }
    return self;
  }
}
