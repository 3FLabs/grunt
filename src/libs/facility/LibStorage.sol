// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Intent} from "./LibIntent.sol";
import {IIntentDescriptor} from "../../interfaces/facility/IIntentDescriptor.sol";
import {STORAGE_SLOT} from "./LibConstants.sol";

/// @notice Storage struct containing all persistent state for the Facility contract.
/// @dev Uses ERC-7201 namespaced storage pattern for proxy compatibility. All fields are grouped
///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
/// @param intents Mapping from intent ID to Intent struct.
/// @param descriptor The intent descriptor contract for generating token metadata.
/// @param lastIntentId The most recent intent ID assigned.
/// @param usedSwapDigests Mapping of used swap digests to prevent replay attacks.
struct FacilityStorageData {
  mapping(uint256 => Intent) intents;
  IIntentDescriptor descriptor;
  uint256 lastIntentId;
  mapping(bytes32 => bool) usedSwapDigests;
}

/// @title LibStorage
/// @notice Library providing storage accessor for Facility contracts.
/// @dev Uses a custom storage slot pattern for upgradeability.
library LibStorage {
  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures consistent storage layout when used behind proxies.
  /// @return data A storage pointer to the FacilityStorageData struct
  function facilityStorage() internal pure returns (FacilityStorageData storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }
}
