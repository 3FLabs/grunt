// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IFacilityFunds} from "../../interfaces/facility/base/IFacilityFunds.sol";
import {IFacilityIntents} from "../../interfaces/facility/base/IFacilityIntents.sol";
import {IFacilityPositionManager} from "../../interfaces/facility/base/IFacilityPositionManager.sol";
import {IFund} from "../../interfaces/funds/IFund.sol";
import {Order, Mode} from "../../libs/funds/Order.sol";
import {IERC20} from "../../interfaces/integrations/IERC20.sol";
import {WithdrawalStrategy} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";

/// @title SyncWithdrawal
/// @notice Stateless script designed to be delegatecalled from MorphoFlashLoanRequest.
///         Executes a synchronous withdrawal flow: withdrawManager → create → commit → unlock.
///         If the intent already has an order (e.g. Midas, created ahead of time), create is skipped.
/// @dev Must NOT have any storage variables. The fund must be set on the intent before execute().
///      The share token is queried on-chain from the intent's fund to measure actual collateral received.
/// @author 3F Protocol
contract SyncWithdrawal {
  /// @notice Thrown when the intent's existing order is not a redeem.
  /// @param intentId The intent ID.
  error NotRedeemOrder(uint256 intentId);

  /// @notice Executes the synchronous withdrawal flow for a facility intent.
  /// @param facility The facility contract address.
  /// @param intentId The intent ID on the facility.
  /// @param withdrawAmount The amount of collateral to withdraw from the position manager.
  /// @param repayAmount The amount of debt to repay to the position manager.
  /// @param useTarget Whether to use the target asset for the position manager withdrawal.
  /// @param strategy The withdrawal strategy (SEQUENTIAL or PROPORTIONAL).
  /// @param minAssetsOut The minimum amount of assets expected from the redemption (ignored if the order exists).
  function run(
    address facility,
    uint256 intentId,
    uint256 withdrawAmount,
    uint256 repayAmount,
    bool useTarget,
    WithdrawalStrategy strategy,
    uint256 minAssetsOut
  ) external {
    // Query fund tokens (must happen BEFORE unlock clears the fund)
    (, address fund,,) = IFacilityIntents(facility).getIntent(intentId);
    address shareToken = IFund(fund).share();

    // 1. Track collateral before withdrawal
    uint256 collateralBefore = IERC20(shareToken).balanceOf(facility);

    // 2. Withdraw collateral from position manager (repay debt, get collateral back)
    IFacilityPositionManager(facility).withdrawManager(intentId, withdrawAmount, repayAmount, useTarget, strategy);

    // 3. Measure actual collateral received
    uint256 collateralReceived = IERC20(shareToken).balanceOf(facility) - collateralBefore;

    // 4. Create redeem order using actual received collateral, unless one already exists (e.g. Midas)
    (Order memory order,) = IFacilityFunds(facility).getOrder(intentId);
    if (order.owner == address(0)) {
      IFacilityFunds(facility).create(intentId, collateralReceived, minAssetsOut, Mode.REDEEM);
    } else if (order.mode != Mode.REDEEM) {
      revert NotRedeemOrder(intentId);
    }

    // 5. Commit order (facility sends shares/collateral to fund)
    IFacilityFunds(facility).commit(intentId);

    // 6. Unlock order (facility receives debt tokens from fund)
    IFacilityFunds(facility).unlock(intentId);
  }
}
