// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilityRequests} from "src/interfaces/facility/base/IFacilityRequests.sol";
import {IRequestInteractions} from "src/interfaces/request/IRequestInteractions.sol";
import {LibIntent, Intent, BalanceSnapshot} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";

/// @title FacilityRequests
/// @author 3F Protocol
/// @notice Abstract contract implementing request operations for intents.
/// @dev Allows pulling funds from and repaying to request contracts.
abstract contract FacilityRequests is IFacilityRequests, ReentrancyGuardTransient, FacilityRoles {
  using SafeTransferLib for address;
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityRequests
  /// @dev Pulls funds from the request contract associated with the intent.
  ///      The intent must be in resolving state and have a request configured.
  function pull(uint256 id, uint256 amount) external override nonReentrant onlyRoles(FACILITATOR_ROLE) {
    // getting the initial request parameters
    (Intent storage _intent, address _request, address _asset) = _initialRequestParameters(id);

    // take snapshot before the operation
    BalanceSnapshot memory snapshot = LibIntent.takeBalanceSnapshot(_asset);

    // pulling funds from the request
    IRequestInteractions(_request).pullFunds(amount, bytes(""));

    // commit snapshot to record the balance change
    _intent.commitBalanceSnapshot(id, snapshot, _request);
  }

  /// @inheritdoc IFacilityRequests
  /// @dev Repays funds to the request contract associated with the intent.
  ///      The intent must be in resolving state and have a request configured.
  function repay(uint256 id, uint256 amount) external override nonReentrant onlyRoles(FACILITATOR_ROLE) {
    // getting the initial request parameters
    (Intent storage _intent, address _request, address _asset) = _initialRequestParameters(id);

    // take snapshot before the operation
    BalanceSnapshot memory snapshot = LibIntent.takeBalanceSnapshot(_asset);

    // approve the request to spend the asset
    _asset.safeApproveWithRetry(_request, amount);
    // repaying the request
    IRequestInteractions(_request).repay(amount);
    // reset approval to 0
    _asset.safeApproveWithRetry(_request, 0);

    // commit snapshot to record the balance change
    _intent.commitBalanceSnapshot(id, snapshot, _request);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Gets the initial request parameters for a given intent.
  /// @dev Retrieves the resolving intent, validates that the request contract address is set,
  ///      and fetches the related asset from the request contract.
  /// @param id The intent id.
  /// @return _intent Storage pointer to the retrieved intent struct.
  /// @return request Address of the request contract associated with the intent.
  /// @return asset Address of the asset handled by the request contract.
  function _initialRequestParameters(uint256 id)
    private
    view
    returns (Intent storage _intent, address request, address asset)
  {
    // check if the facility is paused
    LibStorage.checkNotPaused();
    // getting the intent
    _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // getting the request address
    request = _intent.request;
    // ensure the request is set
    if (request == address(0)) revert LibFacilityErrors.MissingRequest(id);

    // getting the request asset
    asset = IRequestInteractions(request).asset();
  }
}
