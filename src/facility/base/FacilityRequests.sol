// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

import {IFacilityRequests} from "src/interfaces/facility/base/IFacilityRequests.sol";
import {IRequestInteractions} from "src/interfaces/request/IRequestInteractions.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibTokenBalances} from "src/libs/facility/LibTokenBalances.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";

/// @title FacilityRequests
/// @notice Abstract contract implementing request operations for intents.
/// @dev Allows pulling funds from and repaying to request contracts.
abstract contract FacilityRequests is IFacilityRequests, ReentrancyGuardTransient {
  using SafeTransferLib for address;
  using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;
  using LibTokenBalances for EnumerableMapLib.AddressToUint256Map;
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityRequests
  /// @dev Pulls funds from the request contract associated with the intent.
  ///      The intent must be in resolving state and have a request configured.
  function pull(uint256 id, uint256 amount) external override nonReentrant {
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    if (!_intent.isResolving()) revert LibErrors.NotResolving(id);
    if (_intent.request == address(0)) revert LibErrors.MissingRequest(id);

    address asset = IRequestInteractions(_intent.request).asset();

    IRequestInteractions(_intent.request).pullFunds(amount, bytes(""));
    _intent.amounts.add(asset, amount);

    // TODO - Emits event
  }

  /// @inheritdoc IFacilityRequests
  /// @dev Repays funds to the request contract associated with the intent.
  ///      The intent must be in resolving state and have a request configured.
  function repay(uint256 id, uint256 amount) external override nonReentrant {
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    if (!_intent.isResolving()) revert LibErrors.NotResolving(id);
    if (_intent.request == address(0)) revert LibErrors.MissingRequest(id);

    address asset = IRequestInteractions(_intent.request).asset();

    _intent.amounts.sub(asset, amount);
    asset.safeApproveWithRetry(_intent.request, amount);
    IRequestInteractions(_intent.request).repay(amount);

    // TODO - Emits event
  }
}
