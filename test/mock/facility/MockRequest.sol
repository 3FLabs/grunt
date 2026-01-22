// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IRequestInteractions} from "src/interfaces/request/IRequestInteractions.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title MockRequest
/// @notice Mock request contract for testing Facility request operations
/// @dev Implements IRequestInteractions for pull/repay testing
contract MockRequest is IRequestInteractions {
  using SafeTransferLib for address;

  address public asset_;
  bool public repaid;

  bool public shouldRevert;
  string public revertMessage;

  // Track calls for verification
  uint256 public pullFundsCallCount;
  uint256 public repayCallCount;
  uint256 public lastPullAmount;
  uint256 public lastRepayAmount;

  constructor(address asset__) {
    asset_ = asset__;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       TEST HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setRepaid(bool repaid_) external {
    repaid = repaid_;
  }

  function setShouldRevert(bool should, string memory message) external {
    shouldRevert = should;
    revertMessage = message;
  }

  function resetCallCounts() external {
    pullFundsCallCount = 0;
    repayCallCount = 0;
    lastPullAmount = 0;
    lastRepayAmount = 0;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                IRequestInteractions IMPL                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function isRepaid() external view override returns (bool) {
    return repaid;
  }

  function pullFunds(uint256 amount, bytes calldata) external override {
    if (shouldRevert) revert(revertMessage);

    pullFundsCallCount++;
    lastPullAmount = amount;

    // Transfer tokens to the caller
    asset_.safeTransfer(msg.sender, amount);
  }

  function repay(uint256 amount) external override {
    if (shouldRevert) revert(revertMessage);

    repayCallCount++;
    lastRepayAmount = amount;

    // Pull tokens from the caller
    asset_.safeTransferFrom(msg.sender, address(this), amount);
  }

  function asset() external view override returns (address) {
    return asset_;
  }

  // Mock implementation of syncRepaidStatus (from IRequest)
  function syncRepaidStatus() external view returns (bool) {
    return repaid;
  }
}
