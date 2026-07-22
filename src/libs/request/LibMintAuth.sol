// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Lib128Fields} from "./Lib128Fields.sol";

/// @title LibMintAuth
/// @author 3F Protocol
/// @notice Library for gas-efficient storage and manipulation of PT and YT mint authorization data.
/// @dev Mint authorizations are packed as [YT (upper 128 bits) | PT (lower 128 bits)] in a single
///      uint256 slot per minter via {Lib128Fields}.
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

  /// @dev Computes the slot holding `minter`'s packed mint authorizations (derivation shown at
  ///      {_MINT_AUTH_SLOT_SEED}).
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

  /// @dev Returns both PT and YT mint authorizations of `minter` in a single storage read.
  function mintAuth(address minter) internal view returns (uint128 ptMintAuth, uint128 ytMintAuth) {
    (ptMintAuth, ytMintAuth) = mintAuthSlot(minter).fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UPDATES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Writes both PT and YT mint authorizations of `minter` atomically.
  ///      No validation is performed; the caller must ensure values fit in uint128.
  function updateMintAuth(address minter, uint128 ptMintAuth, uint128 ytMintAuth) internal {
    mintAuthSlot(minter).write(ptMintAuth, ytMintAuth);
  }
}
