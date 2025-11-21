// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title LibTokenController
/// @notice Library for gas-efficient storage and manipulation of PT and YT token data.
/// @dev Implements packed storage where PT and YT values are stored together in single uint256 slots:
///      - Lower 128 bits: PT (Principal Token) values
///      - Upper 128 bits: YT (Yield Token) values
///      This packing reduces storage costs and enables atomic updates of both token types.
///      Used for total supplies, balances, and allowances across the dual-token system.
library LibTokenController {
  /// @dev The storage slot for the total supply of both PT and YT tokens.
  ///      Contains: [YT supply (upper 128 bits) | PT supply (lower 128 bits)]
  uint256 private constant _TOTAL_SUPPLY_SLOT = 0x05345cdf77eb68f44c;

  /// @dev Seed used to derive balance storage slots for each account.
  ///      The balance slot for an `owner` is computed as:
  /// ```
  ///     mstore(0x0c, _BALANCE_SLOT_SEED)
  ///     mstore(0x00, owner)
  ///     let balanceSlot := keccak256(0x0c, 0x20)
  /// ```
  ///      Each slot contains: [YT balance (upper 128 bits) | PT balance (lower 128 bits)]
  uint256 private constant _BALANCE_SLOT_SEED = 0x87a211a2;

  /// @dev Seed used to derive allowance storage slots for each (owner, spender) pair.
  ///      The allowance slot for (`owner`, `spender`) is computed as:
  /// ```
  ///     mstore(0x20, spender)
  ///     mstore(0x0c, _ALLOWANCE_SLOT_SEED)
  ///     mstore(0x00, owner)
  ///     let allowanceSlot := keccak256(0x0c, 0x34)
  /// ```
  ///      Each slot contains: [YT allowance (upper 128 bits) | PT allowance (lower 128 bits)]
  uint256 private constant _ALLOWANCE_SLOT_SEED = 0x7f5e9f20;

  /// @dev Bit mask for extracting the lower 128 bits (type(uint128).max).
  uint256 private constant _128_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

  /// @notice Returns the total supply of either PT or YT tokens.
  /// @dev Reads from packed storage and extracts the requested token supply. No validation is performed;
  ///      the caller must ensure proper usage. Gas-efficient single storage read with bit manipulation.
  /// @param yt True to return YT supply (upper 128 bits), false to return PT supply (lower 128 bits)
  /// @return result The total supply of the specified token type as uint128
  function totalSupply(bool yt) internal view returns (uint128 result) {
    /// @solidity memory-safe-assembly
    assembly {
      result := sload(_TOTAL_SUPPLY_SLOT)
      result := shr(mul(yt, 128), result) // if yt==1: shift right 128; if yt==0: shift right 0
      result := and(result, _128_MASK) // mask to 128 bits
    }
  }

  /// @notice Returns the total supplies of both PT and YT tokens in a single read.
  /// @dev Reads from packed storage and extracts both token supplies. More gas-efficient than calling
  ///      totalSupply() twice. No validation is performed; the caller must ensure proper usage.
  /// @return pt The total PT supply (lower 128 bits) as uint128
  /// @return yt The total YT supply (upper 128 bits) as uint128
  function totalSupplies() internal view returns (uint128 pt, uint128 yt) {
    /// @solidity memory-safe-assembly
    assembly {
      let val := sload(_TOTAL_SUPPLY_SLOT)
      pt := and(val, _128_MASK)
      yt := shr(128, val)
    }
  }

  /// @notice Updates the total supplies of both PT and YT tokens atomically.
  /// @dev Packs both supplies into a single uint256 and writes to storage. More gas-efficient than
  ///      separate writes. No validation is performed; the caller must ensure values fit in uint128.
  /// @param pt The new PT total supply (stored in lower 128 bits)
  /// @param yt The new YT total supply (stored in upper 128 bits)
  function updateTotalSupply(uint128 pt, uint128 yt) internal {
    /// @solidity memory-safe-assembly
    assembly {
      let val := or(pt, shl(128, yt))
      sstore(_TOTAL_SUPPLY_SLOT, val)
    }
  }

  /// @notice Returns the balance of either PT or YT tokens for a given account.
  /// @dev Computes the storage slot using keccak256, reads the packed balance, and extracts the requested
  ///      token balance. No validation is performed; the caller must ensure proper usage.
  /// @param account The address to query the balance for
  /// @param yt True to return YT balance (upper 128 bits), false to return PT balance (lower 128 bits)
  /// @return result The balance of the specified token type as uint128
  function balanceOf(address account, bool yt) internal view returns (uint128 result) {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x0c, _BALANCE_SLOT_SEED)
      mstore(0x00, account)
      let balanceSlot := keccak256(0x0c, 0x20)
      result := sload(balanceSlot)
      result := shr(mul(yt, 128), result) // if yt==1: shift right 128; if yt==0: shift right 0
      result := and(result, _128_MASK) // mask to 128 bits
    }
  }

  /// @notice Returns both PT and YT balances for a given account in a single read.
  /// @dev Computes the storage slot using keccak256 and reads the packed balances. More gas-efficient
  ///      than calling balanceOf() twice. No validation is performed; the caller must ensure proper usage.
  /// @param account The address to query balances for
  /// @return pt The PT balance (lower 128 bits) as uint128
  /// @return yt The YT balance (upper 128 bits) as uint128
  function balances(address account) internal view returns (uint128 pt, uint128 yt) {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x0c, _BALANCE_SLOT_SEED)
      mstore(0x00, account)
      let balanceSlot := keccak256(0x0c, 0x20)
      let val := sload(balanceSlot)
      pt := and(val, _128_MASK)
      yt := shr(128, val)
    }
  }

  /// @notice Returns the allowance of either PT or YT tokens for a given (owner, spender) pair.
  /// @dev Computes the storage slot using keccak256, reads the packed allowance, and extracts the requested
  ///      token allowance. No validation is performed; the caller must ensure proper usage.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @param yt True to return YT allowance (upper 128 bits), false to return PT allowance (lower 128 bits)
  /// @return result The allowance of the specified token type as uint128
  function allowance(address owner, address spender, bool yt) internal view returns (uint128 result) {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x20, spender)
      mstore(0x0c, _ALLOWANCE_SLOT_SEED)
      mstore(0x00, owner)
      let allowanceSlot := keccak256(0x0c, 0x34)
      result := sload(allowanceSlot)
      result := shr(mul(yt, 128), result) // if yt==1: shift right 128; if yt==0: shift right 0
      result := and(result, _128_MASK) // mask to 128 bits
    }
  }

  /// @notice Returns both PT and YT allowances for a given (owner, spender) pair in a single read.
  /// @dev Computes the storage slot using keccak256 and reads the packed allowances. More gas-efficient
  ///      than calling allowance() twice. No validation is performed; the caller must ensure proper usage.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @return pt The PT allowance (lower 128 bits) as uint128
  /// @return yt The YT allowance (upper 128 bits) as uint128
  function allowances(address owner, address spender) internal view returns (uint128 pt, uint128 yt) {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x20, spender)
      mstore(0x0c, _ALLOWANCE_SLOT_SEED)
      mstore(0x00, owner)
      let allowanceSlot := keccak256(0x0c, 0x34)
      let val := sload(allowanceSlot)
      pt := and(val, _128_MASK)
      yt := shr(128, val)
    }
  }

  /// @notice Updates both PT and YT balances for a given account atomically.
  /// @dev Computes the storage slot using keccak256, packs both balances into a single uint256, and writes
  ///      to storage. More gas-efficient than separate writes. No validation is performed; the caller must
  ///      ensure values fit in uint128.
  /// @param account The address whose balances to update
  /// @param pt The new PT balance (stored in lower 128 bits)
  /// @param yt The new YT balance (stored in upper 128 bits)
  function updateBalances(address account, uint128 pt, uint128 yt) internal {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x0c, _BALANCE_SLOT_SEED)
      mstore(0x00, account)
      let balanceSlot := keccak256(0x0c, 0x20)
      let val := or(pt, shl(128, yt))
      sstore(balanceSlot, val)
    }
  }

  /// @notice Updates both PT and YT allowances for a given (owner, spender) pair atomically.
  /// @dev Computes the storage slot using keccak256, packs both allowances into a single uint256, and writes
  ///      to storage. More gas-efficient than separate writes. No validation is performed; the caller must
  ///      ensure values fit in uint128.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @param pt The new PT allowance (stored in lower 128 bits)
  /// @param yt The new YT allowance (stored in upper 128 bits)
  function updateAllowance(address owner, address spender, uint128 pt, uint128 yt) internal {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x20, spender)
      mstore(0x0c, _ALLOWANCE_SLOT_SEED)
      mstore(0x00, owner)
      let allowanceSlot := keccak256(0x0c, 0x34)
      let val := or(pt, shl(128, yt))
      sstore(allowanceSlot, val)
    }
  }
}
