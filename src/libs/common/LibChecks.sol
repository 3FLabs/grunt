// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibCommonErrors} from "./LibCommonErrors.sol";
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
    if (addr == address(0)) revert LibCommonErrors.AddressZero();
  }

  /// @dev Reverts if the address is not a contract.
  /// @param addr The address to check.
  function checkContract(address addr) internal view {
    if (addr.code.length == 0) revert LibCommonErrors.InvalidContract(addr);
  }

  /// @dev Reverts if the amount is zero.
  /// @param amount The amount to check.
  function checkNotZero(uint256 amount) internal pure {
    if (amount == 0) revert LibCommonErrors.AmountZero();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        LTV CHECKS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Reverts if the LTV is invalid (zero or greater than WAD).
  /// @param ltv The LTV value to check (WAD precision).
  function checkValidLtv(uint256 ltv) internal pure {
    if (ltv == 0 || ltv > FixedPointMathLib.WAD) revert LibCommonErrors.InvalidLtv();
  }
}
