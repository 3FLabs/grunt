// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IFacilityFunds} from "../../interfaces/facility/base/IFacilityFunds.sol";
import {IFacilityPositionManager} from "../../interfaces/facility/base/IFacilityPositionManager.sol";
import {WithdrawalStrategy} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";

/// @title SyncMidasWithdrawal
/// @notice Stateless script designed to be delegatecalled from MorphoFlashLoanRequest.
///         Executes the remaining Midas redemption flow: withdrawManager → commit → unlock.
/// @dev Must NOT have any storage variables. The redeem order must already exist, its bond
///      leg must be complete, and instant redemption must be unlocked before execute().
/// @author 3F Protocol
contract SyncMidasWithdrawal {
  /// @notice Settles the remaining Midas redemption for a facility intent.
  /// @param facility The facility contract address.
  /// @param intentId The intent ID on the facility.
  /// @param withdrawAmount The remaining collateral required by the Midas redemption.
  /// @param repayAmount The amount of debt to repay to the position manager.
  /// @param useTarget Whether to use the target asset for the position manager withdrawal.
  /// @param strategy The withdrawal strategy (SEQUENTIAL or PROPORTIONAL).
  function run(
    address facility,
    uint256 intentId,
    uint256 withdrawAmount,
    uint256 repayAmount,
    bool useTarget,
    WithdrawalStrategy strategy
  ) external {
    // 1. Withdraw collateral from position manager (repay debt, get collateral back)
    IFacilityPositionManager(facility).withdrawManager(intentId, withdrawAmount, repayAmount, useTarget, strategy);

    // 2. Commit the remaining redemption collateral
    IFacilityFunds(facility).commit(intentId);

    // 3. Unlock the redemption proceeds
    IFacilityFunds(facility).unlock(intentId);
  }
}
