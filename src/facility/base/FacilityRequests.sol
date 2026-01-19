// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {FacilityRoles} from "./FacilityRoles.sol";

import {IFacilityRequests} from "src/interfaces/facility/base/IFacilityRequests.sol";
import {IRequestInteractions} from "src/interfaces/request/IRequestInteractions.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";

/// @title FacilityRequests
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

    // pulling funds from the request
    IRequestInteractions(_request).pullFunds(amount, bytes(""));

    // marking the funds as received from the request contract
    _intent.receivedTokenFrom(id, _asset, _request, amount);
  }

  /// @inheritdoc IFacilityRequests
  /// @dev Repays funds to the request contract associated with the intent.
  ///      The intent must be in resolving state and have a request configured.
  function repay(uint256 id, uint256 amount) external override nonReentrant onlyRoles(FACILITATOR_ROLE) {
    // getting the initial request parameters
    (Intent storage _intent, address _request, address _asset) = _initialRequestParameters(id);

    // approve the request to spend the asset
    _asset.safeApproveWithRetry(_request, amount);
    // repaying the request
    IRequestInteractions(_request).repay(amount);

    // marking the assets as transferred to the request contract (safe to call after repaying since we are non reentrant)
    _intent.transferredTokenTo(id, _asset, _request, amount);
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
    // getting the intent
    _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // getting the request address
    request = _intent.request;
    // ensure the request is set
    if (request == address(0)) revert LibErrors.MissingRequest(id);

    // getting the request asset
    asset = IRequestInteractions(request).asset();
  }
}
