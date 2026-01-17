// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityRoles} from "./FacilityRoles.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {IFund} from "src/interfaces/funds/IFund.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {IVaultController} from "src/interfaces/request/IVaultController.sol";
import {IRequestInteractions} from "src/interfaces/request/IRequestInteractions.sol";
import {LibIntent, Intent, IntentProperties, Asset} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {LibAddress} from "src/libs/facility/LibAddress.sol";

/// @title FacilityIntents
/// @notice Abstract contract implementing intent management operations.
/// @dev Allows creating intents and updating their configuration.
abstract contract FacilityIntents is IFacilityIntents, FacilityRoles {
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;
  using LibAddress for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityIntents
  /// @dev Creates a new intent with the given properties. The resolve start must be in the future.
  ///      At least one of deposit or target asset must be a position manager.
  function createIntent(IntentProperties calldata params) external override onlyOwner returns (uint256 id) {
    if (params.resolveStart <= block.timestamp) {
      revert LibErrors.InvalidResolveStart(params.resolveStart, uint40(block.timestamp));
    }

    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent;
    (_intent, id) = _facilityStorage.createIntent(params.depositAsset, params.quorum);

    _intent.updateTargetAsset(id, params.targetAsset, params.guardKey);
    _intent.updateDepositCap(id, params.depositCap);
    _intent.updateResolveStart(id, params.resolveStart);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Updates the target asset and guard key for an intent.
  ///      The new configuration must be compatible with the deposit asset.
  function updateTarget(uint256 id, Asset calldata newTargetAsset, address newGuardKey) external override onlyOwner {
    LibStorage.facilityStorage().getIntent(id).updateTargetAsset(id, newTargetAsset, newGuardKey);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Locks the intent by setting resolve start to current timestamp.
  ///      The intent must not already be resolving or resolved.
  function lock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    LibStorage.facilityStorage().getDepositingIntent(id).updateResolveStart(id, uint40(block.timestamp));
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Resolves the intent, enabling claims for users.
  ///      The intent must be in resolving state with no active order.
  ///      If a request is set, it must be repaid.
  function resolve(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // checks that the request is repaid
    _intent.checkRequestRepaid();

    // checks that the intent has no pending order
    _intent.checkNoPendingOrder(id);

    // update the intent's resolved state
    _intent.resolved = true;
    emit IntentResolved(id);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Sets a new deposit cap for the intent.
  ///      The intent must be in the depositing state.
  function setDepositCap(uint256 id, uint256 newDepositCap) external override onlyRoles(FACILITATOR_ROLE) {
    LibStorage.facilityStorage().getDepositingIntent(id).updateDepositCap(id, newDepositCap);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Sets a new fund address for the intent.
  ///      The fund's asset and share must match the position manager's assets.
  ///      The intent must not have an active order and must not be resolved.
  function setFund(uint256 id, address newFund) external override onlyRoles(FACILITATOR_ROLE) {
    // ensure the fund is a contract
    newFund.checkContract();

    Intent storage _intent = LibStorage.facilityStorage().getUnresolvedIntent(id);

    // ensure the intent has no pensing order
    _intent.checkNoPendingOrder(id);

    // ensure the fund's assets match the position manager's assets
    (address _pmCollateral, address _pmDebt) = IPositionManager(_intent.properties.guardKey).assets();
    IFund(newFund).asset().checkAssetsMatch(_pmDebt);
    IFund(newFund).share().checkAssetsMatch(_pmCollateral);

    // update the intent's fund
    _intent.fund = newFund;
    emit FundUpdated(id, newFund);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Sets a new request address for the intent.
  ///      The request's asset must match the position manager's debt asset.
  ///      If a previous request exists, it must be repaid.
  function setRequest(uint256 id, address newRequest) external override onlyRoles(FACILITATOR_ROLE) {
    // ensure the request is a contract
    newRequest.checkContract();
    Intent storage _intent = LibStorage.facilityStorage().getUnresolvedIntent(id);

    // ensure that there is no unpaid request bound to the intent
    _intent.checkRequestRepaid();

    // ensure the request's asset matches the position manager's debt asset
    (, address _pmDebt) = IPositionManager(_intent.properties.guardKey).assets();
    IRequestInteractions(newRequest).asset().checkAssetsMatch(_pmDebt);

    // update the intent's request
    _intent.request = newRequest;
    emit RequestUpdated(id, newRequest);
  }
}
