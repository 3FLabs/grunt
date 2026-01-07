// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagerStorageData} from "./PositionManagerTypes.sol";
import {PM_STORAGE_SLOT} from "./LibPositionManagerConstants.sol";

/// @title LibPositionManagerStorage
/// @notice Library providing storage accessor for PositionManager contracts.
/// @dev Uses a custom storage slot pattern for upgradeability.
library LibPositionManagerStorage {
  /// @dev Returns a reference to the contract's storage struct.
  function positionManagerStorage() internal pure returns (PositionManagerStorageData storage data) {
    assembly ("memory-safe") {
      data.slot := PM_STORAGE_SLOT
    }
  }
}
