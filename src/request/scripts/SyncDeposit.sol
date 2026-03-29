// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IFacilityFunds} from "../../interfaces/facility/base/IFacilityFunds.sol";
import {IFacilityIntents} from "../../interfaces/facility/base/IFacilityIntents.sol";
import {IFacilityPositionManager} from "../../interfaces/facility/base/IFacilityPositionManager.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {Mode} from "../../libs/funds/Order.sol";
import {IERC20} from "../../interfaces/integrations/IERC20.sol";

/// @title SyncDeposit
/// @notice Stateless script designed to be delegatecalled from MorphoFlashLoanRequest.
///         Executes a synchronous deposit flow: create → commit → unlock → depositManager.
/// @dev Must NOT have any storage variables. The fund must be set on the intent before execute().
///      The share token is queried on-chain from the intent's fund.
/// @author 3F Protocol
contract SyncDeposit {
  /// @notice Executes the synchronous deposit flow for a facility intent.
  /// @param facility The facility contract address.
  /// @param intentId The intent ID on the facility.
  /// @param depositAmount The amount to deposit into the fund order.
  /// @param minSharesOut The minimum shares expected from the deposit.
  /// @param borrowAmount The amount to borrow via the position manager.
  /// @param useTarget Whether to use the target asset for the position manager deposit.
  function run(
    address facility,
    uint256 intentId,
    uint256 depositAmount,
    uint256 minSharesOut,
    uint256 borrowAmount,
    bool useTarget
  ) external {
    // 1. Create deposit order on fund
    IFacilityFunds(facility).create(intentId, depositAmount, minSharesOut, Mode.DEPOSIT);

    // 2. Commit order (facility sends tokens to fund)
    IFacilityFunds(facility).commit(intentId);

    // 3. Get share token from the intent's fund
    (, address fund,,) = IFacilityIntents(facility).getIntent(intentId);
    address shareToken = IFund(fund).share();

    // 4. Track shares before unlock
    uint256 sharesBefore = IERC20(shareToken).balanceOf(facility);

    // 5. Unlock order (facility receives shares from fund)
    IFacilityFunds(facility).unlock(intentId);

    // 6. Deposit received shares into position manager
    uint256 sharesReceived = IERC20(shareToken).balanceOf(facility) - sharesBefore;
    IFacilityPositionManager(facility).depositManager(intentId, sharesReceived, borrowAmount, useTarget);
  }
}
