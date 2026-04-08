// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Lib128Fields} from "./Lib128Fields.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibTokenController
/// @author 3F Protocol
/// @notice Library for gas-efficient storage and manipulation of PT and YT token data.
/// @dev Implements packed storage where PT and YT values are stored together in single uint256 slots:
///      - Lower 128 bits: PT (Principal Token) values
///      - Upper 128 bits: YT (Yield Token) values
///      This packing reduces storage costs and enables atomic updates of both token types.
///      The actual bit manipulation and storage operations are delegated to {Lib128Fields},
///      which provides gas-optimized assembly implementations for reading and writing packed uint128 fields.
///      Used for total supplies, balances, and allowances across the dual-token system.
library LibTokenController {
  using Lib128Fields for uint256;
  using FixedPointMathLib for bool;

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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SLOT COMPUTATION                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Computes the storage slot for an account's PT and YT balances.
  ///      Uses keccak256 to derive a unique storage slot from the balance seed and account address.
  ///      The resulting slot contains packed PT (lower 128 bits) and YT (upper 128 bits) balances.
  ///
  ///      Slot Derivation:
  ///      1. Place _BALANCE_SLOT_SEED at memory position 0x0c
  ///      2. Place account address at memory position 0x00
  ///      3. Hash 0x20 bytes starting from 0x0c
  ///
  ///      This approach ensures deterministic, collision-resistant storage locations for each account.
  /// @param account The address to compute the balance slot for
  /// @return slot The storage slot containing the packed PT and YT balances
  function balanceSlot(address account) internal pure returns (uint256 slot) {
    assembly ("memory-safe") {
      mstore(0x0c, _BALANCE_SLOT_SEED)
      mstore(0x00, account)
      slot := keccak256(0x0c, 0x20)
    }
  }

  /// @dev Computes the storage slot for PT and YT allowances between an owner and spender.
  ///      Uses keccak256 to derive a unique storage slot from the allowance seed, owner, and spender addresses.
  ///      The resulting slot contains packed PT (lower 128 bits) and YT (upper 128 bits) allowances.
  ///
  ///      Slot Derivation:
  ///      1. Place spender address at memory position 0x20
  ///      2. Place _ALLOWANCE_SLOT_SEED at memory position 0x0c
  ///      3. Place owner address at memory position 0x00
  ///      4. Hash 0x34 bytes starting from 0x0c
  ///
  ///      This approach ensures deterministic, collision-resistant storage locations for each (owner, spender) pair.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @return slot The storage slot containing the packed PT and YT allowances
  function allowanceSlot(address owner, address spender) internal pure returns (uint256 slot) {
    assembly ("memory-safe") {
      mstore(0x20, spender)
      mstore(0x0c, _ALLOWANCE_SLOT_SEED)
      mstore(0x00, owner)
      slot := keccak256(0x0c, 0x34)
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TOTAL SUPPLY                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the total supply of either PT or YT tokens.
  ///      Reads from packed storage using {Lib128Fields.fromSlot} and extracts the requested token supply.
  ///      No validation is performed; the caller must ensure proper usage. Gas-efficient single storage read.
  /// @param yt True to return YT supply (upper 128 bits), false to return PT supply (lower 128 bits)
  /// @return result The total supply of the specified token type as uint128
  function totalSupply(bool yt) internal view returns (uint128 result) {
    unchecked {
      (uint128 ptSupply, uint128 ytSupply) = _TOTAL_SUPPLY_SLOT.fromSlot();
      // casting to 'uint128' is safe because [Both possible values are less than 128 bits]
      // forge-lint: disable-next-line(unsafe-typecast)
      result = uint128(yt.ternary(ytSupply, ptSupply));
    }
  }

  /// @dev Returns the total supplies of both PT and YT tokens in a single read.
  ///      Reads from packed storage using {Lib128Fields.fromSlot} and extracts both token supplies.
  ///      More gas-efficient than calling totalSupply() twice. No validation is performed;
  ///      the caller must ensure proper usage.
  /// @return pt The total PT supply (lower 128 bits) as uint128
  /// @return yt The total YT supply (upper 128 bits) as uint128
  function totalSupplies() internal view returns (uint128 pt, uint128 yt) {
    (pt, yt) = _TOTAL_SUPPLY_SLOT.fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          BALANCES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the balance of either PT or YT tokens for a given account.
  ///      Computes the storage slot using keccak256, reads the packed balance using {Lib128Fields.fromSlot},
  ///      and extracts the requested token balance. No validation is performed; the caller must ensure proper usage.
  /// @param account The address to query the balance for
  /// @param yt True to return YT balance (upper 128 bits), false to return PT balance (lower 128 bits)
  /// @return result The balance of the specified token type as uint128
  function balanceOf(address account, bool yt) internal view returns (uint128 result) {
    unchecked {
      (uint128 ptBalance, uint128 ytBalance) = balanceSlot(account).fromSlot();
      // casting to 'uint128' is safe because [Both possible values are less than 128 bits]
      // forge-lint: disable-next-line(unsafe-typecast)
      result = uint128(yt.ternary(ytBalance, ptBalance));
    }
  }

  /// @dev Returns both PT and YT balances for a given account in a single read.
  ///      Computes the storage slot using keccak256 and reads the packed balances using {Lib128Fields.fromSlot}.
  ///      More gas-efficient than calling balanceOf() twice. No validation is performed;
  ///      the caller must ensure proper usage.
  /// @param account The address to query balances for
  /// @return pt The PT balance (lower 128 bits) as uint128
  /// @return yt The YT balance (upper 128 bits) as uint128
  function balances(address account) internal view returns (uint128 pt, uint128 yt) {
    (pt, yt) = balanceSlot(account).fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ALLOWANCES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the allowance of either PT or YT tokens for a given (owner, spender) pair.
  ///      Computes the storage slot using keccak256, reads the packed allowance using {Lib128Fields.fromSlot},
  ///      and extracts the requested token allowance. No validation is performed; the caller must ensure proper usage.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @param yt True to return YT allowance (upper 128 bits), false to return PT allowance (lower 128 bits)
  /// @return result The allowance of the specified token type as uint128
  function allowance(address owner, address spender, bool yt) internal view returns (uint128 result) {
    unchecked {
      (uint128 ptAllowance, uint128 ytAllowance) = allowanceSlot(owner, spender).fromSlot();
      // casting to 'uint128' is safe because [Both possible values are less than 128 bits]
      // forge-lint: disable-next-line(unsafe-typecast)
      result = uint128(yt.ternary(ytAllowance, ptAllowance));
    }
  }

  /// @dev Returns both PT and YT allowances for a given (owner, spender) pair in a single read.
  ///      Computes the storage slot using keccak256 and reads the packed allowances using {Lib128Fields.fromSlot}.
  ///      More gas-efficient than calling allowance() twice. No validation is performed;
  ///      the caller must ensure proper usage.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @return pt The PT allowance (lower 128 bits) as uint128
  /// @return yt The YT allowance (upper 128 bits) as uint128
  function allowances(address owner, address spender) internal view returns (uint128 pt, uint128 yt) {
    (pt, yt) = allowanceSlot(owner, spender).fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UPDATES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Updates the total supplies of both PT and YT tokens atomically.
  ///      Packs both supplies into a single uint256 using {Lib128Fields.write} and writes to storage.
  ///      More gas-efficient than separate writes. No validation is performed; the caller must ensure
  ///      values fit in uint128.
  /// @param pt The new PT total supply (stored in lower 128 bits)
  /// @param yt The new YT total supply (stored in upper 128 bits)
  function updateTotalSupply(uint128 pt, uint128 yt) internal {
    _TOTAL_SUPPLY_SLOT.write(pt, yt);
  }

  /// @dev Updates both PT and YT balances for a given account atomically.
  ///      Computes the storage slot using keccak256, packs both balances into a single uint256 using
  ///      {Lib128Fields.write}, and writes to storage. More gas-efficient than separate writes.
  ///      No validation is performed; the caller must ensure values fit in uint128.
  /// @param account The address whose balances to update
  /// @param pt The new PT balance (stored in lower 128 bits)
  /// @param yt The new YT balance (stored in upper 128 bits)
  function updateBalances(address account, uint128 pt, uint128 yt) internal {
    balanceSlot(account).write(pt, yt);
  }

  /// @dev Updates both PT and YT allowances for a given (owner, spender) pair atomically.
  ///      Computes the storage slot using keccak256, packs both allowances into a single uint256 using
  ///      {Lib128Fields.write}, and writes to storage. More gas-efficient than separate writes.
  ///      No validation is performed; the caller must ensure values fit in uint128.
  /// @param owner The address that owns the tokens
  /// @param spender The address authorized to spend the tokens
  /// @param pt The new PT allowance (stored in lower 128 bits)
  /// @param yt The new YT allowance (stored in upper 128 bits)
  function updateAllowance(address owner, address spender, uint128 pt, uint128 yt) internal {
    allowanceSlot(owner, spender).write(pt, yt);
  }
}
