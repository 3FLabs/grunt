// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Lib128Fields} from "./Lib128Fields.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibTokenController
/// @author 3F Protocol
/// @notice Library for gas-efficient storage and manipulation of PT and YT token data.
/// @dev Total supplies, balances, and allowances are packed as [YT (upper 128 bits) | PT (lower
///      128 bits)] in single uint256 slots via {Lib128Fields}. No function here validates its
///      inputs; callers must ensure values fit in uint128.
///
///      Storage layout: the slot constants below (`_TOTAL_SUPPLY_SLOT`, `_BALANCE_SLOT_SEED`,
///      `_ALLOWANCE_SLOT_SEED`) and their derivation are intentionally chosen to be storage-compatible
///      with Solady's `ERC20`. This lets the PT/YT view layer expose Solady-style ERC20 reads against
///      the same underlying slots while keeping the lower-128/upper-128 packed encoding.
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

  /// @dev Computes the slot holding `account`'s packed balances (derivation shown at {_BALANCE_SLOT_SEED}).
  function balanceSlot(address account) internal pure returns (uint256 slot) {
    assembly ("memory-safe") {
      mstore(0x0c, _BALANCE_SLOT_SEED)
      mstore(0x00, account)
      slot := keccak256(0x0c, 0x20)
    }
  }

  /// @dev Computes the slot holding the (`owner`, `spender`) packed allowances (derivation shown at
  ///      {_ALLOWANCE_SLOT_SEED}).
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

  /// @dev Returns the total supply of the selected token (yt true = YT, false = PT).
  function totalSupply(bool yt) internal view returns (uint128 result) {
    unchecked {
      (uint128 ptSupply, uint128 ytSupply) = _TOTAL_SUPPLY_SLOT.fromSlot();
      // casting to 'uint128' is safe because [Both possible values are less than 128 bits]
      // forge-lint: disable-next-line(unsafe-typecast)
      result = uint128(yt.ternary(ytSupply, ptSupply));
    }
  }

  /// @dev Returns both PT and YT total supplies in a single storage read.
  function totalSupplies() internal view returns (uint128 pt, uint128 yt) {
    (pt, yt) = _TOTAL_SUPPLY_SLOT.fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          BALANCES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns `account`'s balance of the selected token (yt true = YT, false = PT).
  function balanceOf(address account, bool yt) internal view returns (uint128 result) {
    unchecked {
      (uint128 ptBalance, uint128 ytBalance) = balanceSlot(account).fromSlot();
      // casting to 'uint128' is safe because [Both possible values are less than 128 bits]
      // forge-lint: disable-next-line(unsafe-typecast)
      result = uint128(yt.ternary(ytBalance, ptBalance));
    }
  }

  /// @dev Returns both PT and YT balances of `account` in a single storage read.
  function balances(address account) internal view returns (uint128 pt, uint128 yt) {
    (pt, yt) = balanceSlot(account).fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ALLOWANCES                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns the (owner, spender) allowance of the selected token (yt true = YT, false = PT).
  function allowance(address owner, address spender, bool yt) internal view returns (uint128 result) {
    unchecked {
      (uint128 ptAllowance, uint128 ytAllowance) = allowanceSlot(owner, spender).fromSlot();
      // casting to 'uint128' is safe because [Both possible values are less than 128 bits]
      // forge-lint: disable-next-line(unsafe-typecast)
      result = uint128(yt.ternary(ytAllowance, ptAllowance));
    }
  }

  /// @dev Returns both PT and YT allowances for (owner, spender) in a single storage read.
  function allowances(address owner, address spender) internal view returns (uint128 pt, uint128 yt) {
    (pt, yt) = allowanceSlot(owner, spender).fromSlot();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UPDATES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Writes both PT and YT total supplies atomically.
  function updateTotalSupply(uint128 pt, uint128 yt) internal {
    _TOTAL_SUPPLY_SLOT.write(pt, yt);
  }

  /// @dev Writes both PT and YT balances of `account` atomically.
  function updateBalances(address account, uint128 pt, uint128 yt) internal {
    balanceSlot(account).write(pt, yt);
  }

  /// @dev Writes both PT and YT allowances for (owner, spender) atomically.
  function updateAllowance(address owner, address spender, uint128 pt, uint128 yt) internal {
    allowanceSlot(owner, spender).write(pt, yt);
  }
}
