// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManagerAdmin, SupplyQueueEntry} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {LibChecks} from "../common/LibChecks.sol";
import {LibView} from "./LibView.sol";
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

/// @notice Metadata for the PositionManager share token and assets.
/// @param name The ERC20 name of the position manager share token.
/// @param symbol The ERC20 symbol of the position manager share token.
/// @param decimals The number of decimals for the share token (matches the collateral asset).
/// @param collateralAsset The address of the collateral asset (e.g., USDC) users deposit.
/// @param debtAsset The address of the debt asset borrowed against positions.
struct PositionManagerMetadata {
  string name;
  string symbol;
  uint8 decimals;
  address collateralAsset;
  address debtAsset;
}

/// @notice Storage struct containing all persistent state for the PositionManager contract.
/// @dev Uses ERC-7201 namespaced storage pattern at slot `keccak256(abi.encode(uint256(keccak256("positionmanager.main")) - 1)) & ~bytes32(uint256(0xff))`
///      for upgradeability. Fields are ordered to minimize storage slots.
/// @param feeData Fee configuration containing recipient address, management fee, and performance fee rates.
/// @param supplyQueue Ordered list of supply positions where assets are deposited.
///        Each entry contains a market identifier and allocation cap.
/// @param withdrawalQueue Ordered list of market addresses for withdrawal priority.
///        Assets are withdrawn in this order when processing redemptions.
/// @param borrowModules Set of approved borrow module addresses that can interact with positions.
///        Uses Solady's EnumerableSetLib for O(1) add/remove/contains operations.
/// @param metadata Token metadata and asset addresses for the position manager.
/// @param lastTotalAssets Cached total assets value from the last fee accrual, used for
///        calculating high water mark and performance fees.
/// @param lltv Liquidation loan-to-value ratio in 18-decimal fixed point (e.g., 0.86e18 = 86%).
///        Positions below this threshold are subject to liquidation.
/// @param lastFeeAccrualTimestamp Unix timestamp of the last fee accrual, used for
///        calculating time-weighted management fees.
/// @param maxRebalanceLoss Maximum allowed loss during rebalancing operations in basis points
///        (e.g., 100 = 1%). Protects against excessive slippage or manipulation.
/// @param transferGuard Address of the TransferGuard contract that validates share transfers
///        for compliance (blocklist/whitelist checks). Zero address disables transfer validation.
struct PositionManagerStorageData {
  FeeData feeData;
  SupplyQueueEntry[] supplyQueue;
  address[] withdrawalQueue;
  EnumerableSetLib.AddressSet borrowModules;
  PositionManagerMetadata metadata;
  uint256 lastTotalAssets;
  uint64 lltv;
  uint40 lastFeeAccrualTimestamp;
  uint16 maxRebalanceLoss;
  address transferGuard;
}

/// @title LibStorage
/// @author 3F Protocol
/// @notice Library providing storage accessor for PositionManager contracts.
/// @dev Uses a custom storage slot pattern for upgradeability.
library LibStorage {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       STORAGE ACCESS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns a reference to the contract's storage struct.
  function positionManagerStorage() internal pure returns (PositionManagerStorageData storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          SETTERS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Sets the LLTV value after validation.
  /// @param self The storage pointer to the PositionManagerStorageData struct.
  /// @param lltv_ The LLTV value to set (WAD precision).
  function setLltv(PositionManagerStorageData storage self, uint256 lltv_) internal {
    // LLTV must be > 0 (division by zero in availableCollateral) and <= WAD (100%)
    LibChecks.checkValidLltv(lltv_);
    unchecked {
      // Safe: lltv_ is WAD precision (1e18 max), which fits in uint64 (max ~1.8e19)
      // forge-lint: disable-next-line(unsafe-typecast)
      self.lltv = uint64(lltv_);
      emit IPositionManagerAdmin.LLTVSet(lltv_);
    }
  }

  /// @dev Updates the lastTotalAssets snapshot to the current total assets.
  /// @param self The storage pointer to the PositionManagerStorageData struct.
  function updateSnapshot(PositionManagerStorageData storage self) internal {
    self.lastTotalAssets = LibView.totalAssets(self);
  }
}
