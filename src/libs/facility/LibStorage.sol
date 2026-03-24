// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Intent, LibIntent, Asset} from "./LibIntent.sol";
import {IIntentDescriptor} from "../../interfaces/facility/IIntentDescriptor.sol";
import {STORAGE_SLOT} from "./LibConstants.sol";
import {LibFacilityErrors} from "./LibFacilityErrors.sol";
import {LibCommonErrors as CommonErrors} from "../common/LibCommonErrors.sol";
import {LibPause} from "../common/LibPause.sol";

/// @notice Storage struct containing all persistent state for the Facility contract.
/// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
/// @param intents Mapping from intent ID to Intent struct.
/// @param descriptor The intent descriptor contract for generating token metadata.
/// @param lastIntentId The most recent intent ID assigned.
/// @param usedDigests Mapping of used digests to prevent replay attacks across swaps and intent updates.
/// @param fundsIntent Mapping from fund address to intent ID.
/// @param requestsIntent Mapping from request address to intent ID.
/// @param pausedUntil Pause-until timestamp (0 = not paused, type(uint40).max = permanent pause).
struct FacilityStorageData {
  mapping(uint256 => Intent) intents;
  IIntentDescriptor descriptor;
  uint256 lastIntentId;
  mapping(bytes32 => bool) usedDigests;
  mapping(address => uint256) fundsIntent;
  mapping(address => uint256) requestsIntent;
  uint40 pausedUntil;
}

/// @title LibStorage
/// @author 3F Protocol
/// @notice Library providing storage accessor for Facility contracts.
/// @dev Uses a custom storage slot pattern for upgradeability.
library LibStorage {
  using LibIntent for Intent;
  using LibPause for uint40;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       STORAGE ACCESS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return data A storage pointer to the FacilityStorageData struct
  function facilityStorage() internal pure returns (FacilityStorageData storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INTENT GETTERS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns a reference to the intent struct for the given ID, reverting if the intent does not exist.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param id The ID of the intent.
  /// @return _intent A reference to the intent struct.
  function getIntent(FacilityStorageData storage self, uint256 id) internal view returns (Intent storage _intent) {
    if (id == 0 || id > self.lastIntentId) revert LibFacilityErrors.IntentNotFound(id);
    _intent = self.intents[id];
  }

  /// @dev Returns a reference to the intent struct for the given ID, reverting if the intent does not exist
  ///      or is not in the resolving state.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param id The ID of the intent.
  /// @return _intent A reference to the intent struct.
  function getResolvingIntent(FacilityStorageData storage self, uint256 id)
    internal
    view
    returns (Intent storage _intent)
  {
    _intent = getIntent(self, id);
    if (!LibIntent.isResolving(_intent)) revert LibFacilityErrors.NotResolving(id);
  }

  /// @dev Returns a reference to the intent struct for the given ID, reverting if the intent does not exist
  ///      or is not in the depositing state.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param id The ID of the intent.
  /// @return _intent A reference to the intent struct.
  function getDepositingIntent(FacilityStorageData storage self, uint256 id)
    internal
    view
    returns (Intent storage _intent)
  {
    _intent = getIntent(self, id);
    if (!LibIntent.isDepositing(_intent)) revert LibFacilityErrors.NotDepositing(id);
  }

  /// @dev Returns a reference to the intent struct for the given ID, reverting if the intent does not exist
  ///      or is not in the resolved state.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param id The ID of the intent.
  /// @return _intent A reference to the intent struct.
  function getResolvedIntent(FacilityStorageData storage self, uint256 id)
    internal
    view
    returns (Intent storage _intent)
  {
    _intent = getIntent(self, id);
    if (!LibIntent.isResolved(_intent)) revert LibFacilityErrors.NotResolved(id);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Allocates a new intent ID, sets the deposit asset and quorum, and returns a reference to the intent struct.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param depositAsset The deposit asset configuration.
  /// @param quorum The quorum threshold for guard approvals.
  /// @param transferableIntent Whether intent token transfers are allowed.
  /// @return _intent A reference to the newly allocated intent struct.
  /// @return id The newly allocated intent ID.
  function createIntent(
    FacilityStorageData storage self,
    Asset calldata depositAsset,
    uint8 quorum,
    bool transferableIntent
  ) internal returns (Intent storage _intent, uint256 id) {
    id = self.lastIntentId + 1;
    self.lastIntentId = id;
    _intent = self.intents[id];
    _intent.init(id, depositAsset, quorum, transferableIntent);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         VALIDATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Checks if the facility is paused. Reverts with `Paused` error if paused.
  function checkNotPaused() internal view {
    if (facilityStorage().pausedUntil.paused()) revert CommonErrors.Paused();
  }

  /// @dev Checks if a digest has been used and marks it as used. Reverts if already used.
  ///      Sets the digest as used in the mapping if not already used.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param digest The digest to check and mark as used.
  function checkDigest(FacilityStorageData storage self, bytes32 digest) internal {
    if (self.usedDigests[digest]) revert LibFacilityErrors.DigestUsed(digest);
    self.usedDigests[digest] = true;
  }

  /// @dev Checks if a fund is already in use and sets it to the target intent ID if not.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param fund The fund address.
  /// @param targetIntentId The target intent ID.
  function checkFundIntent(FacilityStorageData storage self, address fund, uint256 targetIntentId) internal {
    uint256 intentId = self.fundsIntent[fund];
    if (intentId == 0) {
      self.fundsIntent[fund] = targetIntentId;
      return;
    }
    if (intentId != targetIntentId) revert LibFacilityErrors.FundAlreadyInUse(fund, intentId);
  }

  /// @dev Checks if a request is already in use and sets it to the target intent ID if not.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param request The request address.
  /// @param targetIntentId The target intent ID.
  function checkRequestIntent(FacilityStorageData storage self, address request, uint256 targetIntentId) internal {
    uint256 intentId = self.requestsIntent[request];
    if (intentId == 0) {
      self.requestsIntent[request] = targetIntentId;
      return;
    }
    if (intentId != targetIntentId) revert LibFacilityErrors.RequestAlreadyInUse(request, intentId);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          UPDATES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Abandons a fund and removes it from the mapping.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param fund The fund address.
  function abandonFund(FacilityStorageData storage self, address fund) internal {
    delete self.fundsIntent[fund];
  }

  /// @dev Abandons a request and removes it from the mapping.
  /// @param self The storage pointer to the FacilityStorageData struct.
  /// @param request The request address.
  function abandonRequest(FacilityStorageData storage self, address request) internal {
    delete self.requestsIntent[request];
  }
}
