// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibErrors} from "./LibErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibChecks
/// @author 3F Protocol
/// @notice Common validation utilities shared across all modules.
library LibChecks {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      GENERAL CHECKS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts if the address is the zero address.
  /// @param addr The address to check.
  function checkNotZero(address addr) internal pure {
    if (addr == address(0)) revert LibErrors.AddressZero();
  }

  /// @dev Reverts if the address is not a contract.
  /// @param addr The address to check.
  function checkContract(address addr) internal view {
    if (addr.code.length == 0) revert LibErrors.InvalidContract(addr);
  }

  /// @dev Reverts if the amount is zero.
  /// @param amount The amount to check.
  function checkNotZero(uint256 amount) internal pure {
    if (amount == 0) revert LibErrors.AmountZero();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       LLTV CHECKS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts if the LLTV is invalid (zero or greater than WAD).
  /// @param lltv The LLTV value to check (WAD precision).
  function checkValidLltv(uint256 lltv) internal pure {
    if (lltv == 0 || lltv > FixedPointMathLib.WAD) revert LibErrors.InvalidLltv();
  }
}
