// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {SupplyQueueEntry} from "../../interfaces/manager/IPositionManager.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {STORAGE_SLOT} from "./LibConstants.sol";

/// @notice Fee configuration data for the PositionManager.
/// @param feeRecipient The address that receives fee payments
/// @param managementFee The management fee rate in basis points per year (e.g., 200 = 2%)
/// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%)
struct FeeData {
  address feeRecipient;
  uint24 managementFee;
  uint24 performanceFee;
}

/// @notice Storage struct containing all persistent state for the PositionManager contract.
/// @dev Storage packing: lltv (uint64) + lastFeeAccrualTimestamp (uint40) + maxRebalanceLoss (uint16) = 15 bytes in one slot
struct PositionManagerStorageData {
  FeeData feeData;
  SupplyQueueEntry[] supplyQueue;
  address[] withdrawalQueue;
  EnumerableSetLib.AddressSet borrowModules;
  string name;
  string symbol;
  uint8 decimals;
  address collateralAsset;
  address debtAsset;
  uint256 lastTotalAssets;
  uint64 lltv;
  uint40 lastFeeAccrualTimestamp;
  uint16 maxRebalanceLoss;
}

/// @title LibStorage
/// @notice Library providing storage accessor for PositionManager contracts.
/// @dev Uses a custom storage slot pattern for upgradeability.
library LibStorage {
  /// @dev Returns a reference to the contract's storage struct.
  function positionManagerStorage() internal pure returns (PositionManagerStorageData storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }
}
