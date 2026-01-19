// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {FacilityRoles} from "./FacilityRoles.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {IFund} from "src/interfaces/funds/IFund.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {IRequestInteractions} from "src/interfaces/request/IRequestInteractions.sol";
import {LibIntent, Intent, IntentProperties, Asset} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {LibAddress} from "src/libs/facility/LibAddress.sol";

/// @title FacilityIntents
/// @author 3F Protocol
/// @notice Abstract contract implementing intent management operations.
/// @dev Allows creating intents and updating their configuration.
abstract contract FacilityIntents is IFacilityIntents, FacilityRoles {
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;
  using LibAddress for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityIntents
  function getIntent(uint256 id)
    external
    view
    override
    returns (IntentProperties memory properties, address fund, address request, bool resolved)
  {
    Intent storage _intent = LibStorage.facilityStorage().getIntent(id);
    properties = _intent.properties;
    fund = _intent.fund;
    request = _intent.request;
    resolved = _intent.resolved;
  }

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
  ///      The intent must not have an active order.
  ///      If the fund is address(0), the fund is removed from the intent.
  function setFund(uint256 id, address newFund) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    // ensure the intent has no pending order
    _intent.checkNoPendingOrder(id);

    if (newFund == address(0)) {
      // if the fund is address(0), remove the fund
      _intent.removeOrderAndFund(id);
      return;
    }

    // ensure the fund is not already in use
    _facilityStorage.checkFundIntent(newFund, id);

    // ensure the fund is a contract
    newFund.checkContract();

    // ensure the fund's assets match the position manager's assets
    (address _pmCollateral, address _pmDebt) = IPositionManager(_intent.properties.guardKey).assets();
    IFund(newFund).asset().checkAssetsMatch(_pmDebt);
    IFund(newFund).share().checkAssetsMatch(_pmCollateral);

    // abandon the old fund if it exists
    _facilityStorage.abandonFund(_intent.fund);

    // update the intent's fund
    _intent.fund = newFund;
    emit FundUpdated(id, newFund);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Sets a new request address for the intent.
  ///      The request's asset must match the position manager's debt asset.
  ///      If a previous request exists, it must be repaid.
  ///      If the request is address(0), the request is removed from the intent.
  function setRequest(uint256 id, address newRequest) external override onlyRoles(FACILITATOR_ROLE) {
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    // ensure that there is no unpaid request bound to the intent
    _intent.checkRequestRepaid();

    if (newRequest != address(0)) {
      // ensure the request is a contract
      newRequest.checkContract();

      // ensure the request is not already in use
      _facilityStorage.checkRequestIntent(newRequest, id);

      // ensure the request's asset matches the position manager's debt asset
      (, address _pmDebt) = IPositionManager(_intent.properties.guardKey).assets();
      IRequestInteractions(newRequest).asset().checkAssetsMatch(_pmDebt);
    }

    // abandon the old request if it exists
    _facilityStorage.abandonRequest(_intent.request);

    // update the intent's request
    _intent.request = newRequest;
    emit RequestUpdated(id, newRequest);
  }
}
