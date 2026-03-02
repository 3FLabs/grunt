// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IIdleCreditVault} from "src/interfaces/integrations/pareto/IIdleCreditVault.sol";

/// @dev Mock IdleCreditVault strategy for testing ParetoFund.
///      Tracks withdrawal requests and epoch numbers.
contract MockIdleCreditVault is IIdleCreditVault {
  mapping(address => uint256) public _withdrawRequests;
  mapping(address => uint256) public _lastWithdrawRequest;
  uint256 public _epochNumber = 1;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    IIdleCreditVault VIEWS                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function withdrawsRequests(address account) external view override returns (uint256) {
    return _withdrawRequests[account];
  }

  function lastWithdrawRequest(address account) external view override returns (uint256) {
    return _lastWithdrawRequest[account];
  }

  function epochNumber() external view override returns (uint256) {
    return _epochNumber;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       MOCK INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function registerWithdraw(address account, uint256 amount, uint256 epoch) external {
    _withdrawRequests[account] += amount;
    _lastWithdrawRequest[account] = epoch;
  }

  function clearWithdraw(address account) external {
    _withdrawRequests[account] = 0;
  }

  function advanceEpoch() external {
    _epochNumber++;
  }

  function setEpochNumber(uint256 epoch) external {
    _epochNumber = epoch;
  }
}
