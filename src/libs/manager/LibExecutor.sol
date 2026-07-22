// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IBorrowPosition} from "../../interfaces/borrow/IBorrowPosition.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title LibExecutor
/// @author 3F Protocol
/// @notice Library providing low-level position interaction helpers.
/// @dev Handles supply, withdraw, borrow, and repay operations on IBorrowPosition contracts.
///      Use with `using LibExecutor for address;`
library LibExecutor {
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       MODIFIERS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Approval leg of the {approves} modifier; kept as a helper to reduce contract code size
  ///      (SafeTransferLib calls are verbose if inlined multiple times).
  function _approvesBefore(address position, address token, uint256 amount) private {
    token.safeApproveWithRetry(position, amount);
  }

  /// @dev Reset leg of the {approves} modifier.
  function _approvesAfter(address position, address token) private {
    token.safeApprove(position, 0);
  }

  /// @dev Approves `position` for `amount` of `token` during the wrapped call, then resets the
  ///      approval to zero.
  /// @param position The address of the IBorrowPosition contract to approve
  /// @param token The ERC20 token address to approve
  /// @param amount The amount of tokens to approve for transfer
  modifier approves(address position, address token, uint256 amount) {
    _approvesBefore(position, token, amount);
    _;
    _approvesAfter(position, token);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       EXECUTORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Supplies collateral to a borrow position.
  /// @param position The address of the IBorrowPosition contract
  /// @param token The collateral token address
  /// @param amount The amount of collateral to supply
  function supply(address position, address token, uint256 amount) internal approves(position, token, amount) {
    IBorrowPosition(position).supplyCollateral(amount);
  }

  /// @dev Withdraws collateral from a borrow position.
  /// @param position The address of the IBorrowPosition contract
  /// @param amount The amount of collateral to withdraw
  function withdraw(address position, uint256 amount) internal {
    IBorrowPosition(position).withdrawCollateral(amount);
  }

  /// @dev Borrows debt from a borrow position.
  /// @param position The address of the IBorrowPosition contract
  /// @param amount The amount of debt to borrow
  function borrow(address position, uint256 amount) internal {
    IBorrowPosition(position).borrow(amount);
  }

  /// @dev Repays debt on a borrow position.
  /// @param position The address of the IBorrowPosition contract
  /// @param token The debt token address
  /// @param amount The amount of debt to repay
  function repay(address position, address token, uint256 amount) internal approves(position, token, amount) {
    IBorrowPosition(position).repay(amount);
  }
}
