// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibExecutor} from "src/libs/manager/LibExecutor.sol";

/// @dev Harness contract to expose internal LibExecutor functions for testing
contract LibExecutorHarness {
  using LibExecutor for address;

  /// @dev Expose supply
  function supply(address position, address token, uint256 amount) external {
    position.supply(token, amount);
  }

  /// @dev Expose withdraw
  function withdraw(address position, uint256 amount) external {
    position.withdraw(amount);
  }

  /// @dev Expose borrow
  function borrow(address position, uint256 amount) external {
    position.borrow(amount);
  }

  /// @dev Expose repay
  function repay(address position, address token, uint256 amount) external {
    position.repay(token, amount);
  }
}
