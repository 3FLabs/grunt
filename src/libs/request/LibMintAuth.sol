// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Lib128Fields} from "./Lib128Fields.sol";

/// @title LibMintAuth
/// @author 3F Protocol
/// @notice Library for gas-efficient storage and manipulation of PT and YT mint authorization data.
/// @dev Implements packed storage where PT and YT mint authorization values are stored together in single uint256 slots:
///      - Lower 128 bits: PT (Principal Token) mint authorization
///      - Upper 128 bits: YT (Yield Token) mint authorization
///      This packing reduces storage costs and enables atomic updates of both authorization values.
///      The actual bit manipulation and storage operations are delegated to {Lib128Fields},
///      which provides gas-optimized assembly implementations for reading and writing packed uint128 fields.
///      Used to track minting authorizations for addresses across the dual-token system.
library LibMintAuth {
  using Lib128Fields for uint256;

  /// @dev Seed used to derive mint authorization storage slots for each minter address.
  ///      The mint auth slot for a `minter` is computed as:
  /// ```
  ///     mstore(0x0c, _MINT_AUTH_SLOT_SEED)
  ///     mstore(0x00, minter)
  ///     let mintAuthSlot := keccak256(0x0c, 0x20)
  /// ```
  ///      Each slot contains: [YT mint auth (upper 128 bits) | PT mint auth (lower 128 bits)]
  uint256 internal constant _MINT_AUTH_SLOT_SEED = 0x08395086;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SLOT COMPUTATION                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Computes the storage slot for a minter's PT and YT mint authorizations.
  ///      Uses keccak256 to derive a unique storage slot from the mint auth seed and minter address.
  ///      The resulting slot contains packed PT (lower 128 bits) and YT (upper 128 bits) mint authorizations.
  ///
  ///      Slot Derivation:
  ///      1. Place _MINT_AUTH_SLOT_SEED at memory position 0x0c
  ///      2. Place minter address at memory position 0x00
  ///      3. Hash 0x20 bytes starting from 0x0c
  ///
  ///      This approach ensures deterministic, collision-resistant storage locations for each minter.
  /// @param minter The address to compute the mint authorization slot for
  /// @return slot The storage slot containing the packed PT and YT mint authorizations
  function mintAuthSlot(address minter) internal pure returns (uint256 slot) {
    assembly ("memory-safe") {
      mstore(0x0c, _MINT_AUTH_SLOT_SEED)
      mstore(0x00, minter)
      slot := keccak256(0x0c, 0x20)
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      MINT AUTHORIZATION                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns both PT and YT mint authorizations for a given minter in a single read.
  ///      Computes the storage slot using keccak256 and reads the packed mint authorizations using {Lib128Fields.fromSlot}.
  ///      Gas-efficient single storage read. No validation is performed; the caller must ensure proper usage.
  /// @param minter The address to query mint authorizations for
  /// @return ptMintAuth The PT mint authorization (lower 128 bits) as uint128
  /// @return ytMintAuth The YT mint authorization (upper 128 bits) as uint128
  function mintAuth(address minter) internal view returns (uint128 ptMintAuth, uint128 ytMintAuth) {
    (ptMintAuth, ytMintAuth) = mintAuthSlot(minter).fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UPDATES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Updates both PT and YT mint authorizations for a given minter atomically.
  ///      Computes the storage slot using keccak256, packs both authorizations into a single uint256 using
  ///      {Lib128Fields.write}, and writes to storage. More gas-efficient than separate writes.
  ///      No validation is performed; the caller must ensure values fit in uint128.
  /// @param minter The address whose mint authorizations to update
  /// @param ptMintAuth The new PT mint authorization (stored in lower 128 bits)
  /// @param ytMintAuth The new YT mint authorization (stored in upper 128 bits)
  function updateMintAuth(address minter, uint128 ptMintAuth, uint128 ytMintAuth) internal {
    mintAuthSlot(minter).write(ptMintAuth, ytMintAuth);
  }
}
