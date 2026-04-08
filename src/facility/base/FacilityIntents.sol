// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityRoles} from "./FacilityRoles.sol";
import {EIP712} from "lib/solady/src/utils/EIP712.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {IFund} from "src/interfaces/funds/IFund.sol";
import {IPositionManager} from "src/interfaces/manager/IPositionManager.sol";
import {IRequestInteractions} from "src/interfaces/request/IRequestInteractions.sol";
import {LibIntent, Intent, IntentProperties, Asset} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibAddress} from "src/libs/facility/LibAddress.sol";
import {LibChecks} from "src/libs/common/LibChecks.sol";

/// @title FacilityIntents
/// @author 3F Protocol
/// @notice Abstract contract implementing intent management operations.
/// @dev Allows creating intents and updating their configuration.
abstract contract FacilityIntents is IFacilityIntents, EIP712, FacilityRoles {
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;
  using LibChecks for address;
  using LibAddress for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice EIP-712 typehash for setFund params.
  /// @dev keccak256("SetFundParams(uint256 id,address newFund,uint256 deadline)")
  bytes32 internal constant SET_FUND_PARAMS_TYPEHASH =
    0x5b29fe7a3c7ef719629449a6e2c108e8c6d692027b5327c7edbdc163a7ce1b0b;

  /// @notice EIP-712 typehash for setRequest params.
  /// @dev keccak256("SetRequestParams(uint256 id,address newRequest,uint256 deadline)")
  bytes32 internal constant SET_REQUEST_PARAMS_TYPEHASH =
    0x3fab97cdfeba7b67ca42aeebb63ab14ea67e6637d1e42acb3a06b721f7d72438;

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
  function createIntent(IntentProperties calldata params)
    external
    override
    onlyOwnerOrRoles(FACILITATOR_ROLE)
    returns (uint256 id)
  {
    LibStorage.checkNotPaused();
    if (params.resolveStart <= block.timestamp) {
      revert LibFacilityErrors.InvalidResolveStart(params.resolveStart, uint40(block.timestamp));
    }

    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent;
    (_intent, id) = _facilityStorage.createIntent(params.depositAsset, params.quorum, params.transferableIntent);

    _intent.updateTargetAsset(id, params.targetAsset, params.guardKey);
    _intent.updateDepositCap(id, params.depositCap);
    _intent.updateResolveStart(id, params.resolveStart);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Updates the target asset and guard key for an intent.
  ///      The new configuration must be compatible with the deposit asset.
  function updateTarget(uint256 id, Asset calldata newTargetAsset, address newGuardKey) external override onlyOwner {
    LibStorage.checkNotPaused();
    LibStorage.facilityStorage().getIntent(id).updateTargetAsset(id, newTargetAsset, newGuardKey);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Locks the intent by setting resolve start to current timestamp.
  ///      The intent must not already be resolving or resolved.
  function lock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    LibStorage.checkNotPaused();
    LibStorage.facilityStorage().getDepositingIntent(id).updateResolveStart(id, uint40(block.timestamp));
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Resolves the intent, enabling claims for users.
  ///      The intent must be in resolving state with no active order.
  ///      If a request is set, it must be repaid.
  function resolve(uint256 id) external override onlyRoles(FACILITATOR_ROLE) {
    LibStorage.checkNotPaused();
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // checks that the request is repaid
    _intent.checkRequestRepaid();

    // sync stale ended orders
    _intent.syncEndedOrder(id);

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
    LibStorage.checkNotPaused();
    LibStorage.facilityStorage().getDepositingIntent(id).updateDepositCap(id, newDepositCap);
  }

  /// @inheritdoc IFacilityIntents
  /// @dev Sets a new fund address for the intent.
  ///      The fund's asset and share must match the position manager's assets.
  ///      The intent must not have an active order.
  ///      If the fund is address(0), the fund is removed from the intent.
  function setFund(
    uint256 id,
    address newFund,
    uint256 deadline,
    address[] calldata signers,
    bytes[] calldata signatures
  ) external override onlyRoles(FACILITATOR_ROLE) {
    LibStorage.checkNotPaused();
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    // sync stale ended orders
    _intent.syncEndedOrder(id);

    // skip if the fund is already set to the same address
    if (_intent.fund == newFund) return;

    // ensure the intent has no pending order
    _intent.checkNoPendingOrder(id);

    if (newFund == address(0)) {
      // if the fund is address(0), remove the fund (no signature required)
      _intent.removeOrderAndFund(id);
      return;
    }

    if (block.timestamp > deadline) revert LibFacilityErrors.DeadlineExpired();

    _checkSignatures(
      _facilityStorage,
      _hashTypedData(keccak256(abi.encode(SET_FUND_PARAMS_TYPEHASH, id, newFund, deadline))),
      signers,
      signatures,
      _intent.properties.quorum
    );

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
  function setRequest(
    uint256 id,
    address newRequest,
    uint256 deadline,
    address[] calldata signers,
    bytes[] calldata signatures
  ) external override onlyRoles(FACILITATOR_ROLE) {
    LibStorage.checkNotPaused();
    FacilityStorageData storage _facilityStorage = LibStorage.facilityStorage();
    Intent storage _intent = _facilityStorage.getIntent(id);

    // skip if the request is already set to the same address
    if (_intent.request == newRequest) return;

    // ensure that there is no unpaid request bound to the intent
    _intent.checkRequestRepaid();

    if (newRequest != address(0)) {
      if (block.timestamp > deadline) revert LibFacilityErrors.DeadlineExpired();

      _checkSignatures(
        _facilityStorage,
        _hashTypedData(keccak256(abi.encode(SET_REQUEST_PARAMS_TYPEHASH, id, newRequest, deadline))),
        signers,
        signatures,
        _intent.properties.quorum
      );

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
