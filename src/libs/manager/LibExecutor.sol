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

  /// @notice Internal helper to safely approve a position contract for a token transfer before an operation.
  /// @dev This function is defined to reduce contract code size by centralizing approval logic, as SafeTransferLib.safeApproveWithRetry can be verbose if inlined multiple times.
  /// @param position The address of the contract that will be approved to spend the token.
  /// @param token The address of the ERC20 token to be approved.
  /// @param amount The amount of tokens to approve.
  function _approvesBefore(address position, address token, uint256 amount) private {
    token.safeApproveWithRetry(position, amount);
  }

  /// @notice Internal helper to reset approval to zero for a position contract after an operation.
  /// @dev This function is defined to reduce contract code size by centralizing de-approval logic, as SafeTransferLib.safeApprove can be verbose if inlined multiple times.
  /// @param position The address of the contract whose approval is being reset.
  /// @param token The address of the ERC20 token whose approval is to be reset.
  function _approvesAfter(address position, address token) private {
    token.safeApprove(position, 0);
  }

  /// @notice Modifier that safely approves a position contract to transfer a specific amount of a token, and resets approval to zero afterward.
  /// @dev This modifier ensures that the `token` is approved for `amount` for the given `position` only during the execution of the function.
  ///      After the function executes, approval is reset to zero to minimize risk of unintended token transfers.
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
