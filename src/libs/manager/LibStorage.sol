// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IPositionManagerAdmin, SupplyQueueEntry} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {LibChecks} from "../common/LibChecks.sol";
import {LibView} from "./LibView.sol";
import {STORAGE_SLOT, MAX_REBALANCE_LOSS} from "./LibConstants.sol";
import {LibManagerErrors} from "./LibManagerErrors.sol";

/// @notice Fee configuration data for the PositionManager.
/// @param feeRecipient The address that receives fee payments
/// @param managementFee The management fee rate in basis points per year (e.g., 200 = 2%), charged
///        on the aggregate quoted collateral of non-bad-debt positions — *not* on NAV. For a
///        leveraged vault this basis is materially larger than the NAV. The resulting fee assets
///        are capped at `totalAssets` so the post-fee asset base remains non-negative.
/// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%), charged on the
///        performance of the levered slice only — basis `LTV_prev * Δcollat - Δdebt` (equivalently
///        `mulDivUp(lastDebt, currentCollat, lastCollat) - currentDebt`), where
///        `LTV_prev = lastDebt / lastCollat` is the LTV at the previous snapshot. The basis is then
///        reduced by the management fee assets accrued over the same period. Replaces the prior
///        NAV-variation basis.
struct FeeData {
  address feeRecipient;
  uint24 managementFee;
  uint24 performanceFee;
}

/// @notice Metadata for the PositionManager share token and assets.
/// @param name The ERC20 name of the position manager share token.
/// @param symbol The ERC20 symbol of the position manager share token.
/// @param collateralAsset The address of the collateral asset (e.g., USDC) users deposit.
/// @param debtAsset The address of the debt asset borrowed against positions.
struct PositionManagerMetadata {
  string name;
  string symbol;
  address collateralAsset;
  address debtAsset;
}

/// @notice Rebalance configuration and state for the PositionManager.
/// @param maxRebalanceLoss Maximum allowed loss during rebalancing operations in basis points
///        (e.g., 100 = 1%). Protects against excessive slippage or manipulation.
/// @param rebalanceCooldown Minimum seconds between consecutive rebalance calls. Zero disables.
/// @param lastRebalanceTimestamp Unix timestamp of the last rebalance, used for cooldown enforcement.
struct RebalanceConfig {
  uint16 maxRebalanceLoss;
  uint40 rebalanceCooldown;
  uint40 lastRebalanceTimestamp;
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
/// @param lastTotalAssets Cached `collateralQuoted - debt` (NAV) from the last fee accrual.
///        Still represents `collat - debt` as before; for the performance fee, `lastCollat` is
///        reconstructed on the fly as `lastTotalAssets + lastDebt` rather than storing it directly,
///        which keeps the storage layout append-only and existing integrations unchanged.
/// @param ltv Loan-to-value ratio in 18-decimal fixed point (e.g., 0.86e18 = 86%).
///        A small buffer above the target LTV that determines how much collateral can be withdrawn.
/// @param virtualShareOffset Virtual shares offset for inflation attack protection, derived from debt asset decimals.
///        Computed as 10^(18 - debtAsset.decimals()), so tokens with fewer decimals get stronger protection.
///        For 18-decimal tokens the offset is 1 (weakest); for 6-decimal tokens (e.g., USDC) the offset is 1e12.
///        @notice For debt assets with 18 decimals, the inflation front-running protection is low.
///        To protect against this attack, vault deployers should make an initial deposit of a non-trivial amount
///        in the vault, or depositors should check that the share price does not exceed a certain limit.
/// @param lastFeeAccrualTimestamp Unix timestamp of the last fee accrual, used for
///        calculating time-weighted management fees.
/// @param transferGuard Address of the TransferGuard contract that validates share transfers
///        for compliance (blocklist/whitelist checks). Zero address disables transfer validation.
/// @param rebalanceConfig Rebalance parameters packed in a single struct (maxRebalanceLoss, cooldown, timestamp).
/// @param lastDebt Cached aggregate debt at the last snapshot. Used together with `lastTotalAssets`
///        to reconstruct `lastCollat = lastTotalAssets + lastDebt` for the levered-slice performance
///        fee basis. A value of zero acts as a bootstrap sentinel: the first accrual after upgrade
///        (or any other time `lastDebt` is zero) skips the performance fee and seeds this slot with
///        the current debt. Subsequent accruals charge the new basis normally.
struct PositionManagerStorageData {
  FeeData feeData;
  SupplyQueueEntry[] supplyQueue;
  address[] withdrawalQueue;
  EnumerableSetLib.AddressSet borrowModules;
  PositionManagerMetadata metadata;
  uint256 lastTotalAssets;
  uint64 ltv;
  uint64 virtualShareOffset;
  uint40 lastFeeAccrualTimestamp;
  address transferGuard;
  RebalanceConfig rebalanceConfig;
  uint256 lastDebt;
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

  /// @dev Sets the LTV value after validation.
  /// @param self The storage pointer to the PositionManagerStorageData struct.
  /// @param ltv_ The LTV value to set (WAD precision).
  function setLtv(PositionManagerStorageData storage self, uint256 ltv_) internal {
    // LTV must be > 0 (division by zero in availableCollateral) and <= WAD (100%)
    LibChecks.checkValidLtv(ltv_);
    unchecked {
      // Safe: ltv_ is WAD precision (1e18 max), which fits in uint64 (max ~1.8e19)
      // forge-lint: disable-next-line(unsafe-typecast)
      self.ltv = uint64(ltv_);
      emit IPositionManagerAdmin.LTVSet(ltv_);
    }
  }

  /// @dev Sets the rebalance configuration (maxRebalanceLoss and cooldown).
  ///      Does not modify lastRebalanceTimestamp.
  /// @param self The storage pointer to the PositionManagerStorageData struct.
  /// @param maxRebalanceLoss_ The max rebalance loss in basis points (e.g., 100 = 1%).
  /// @param rebalanceCooldown_ The cooldown period in seconds (0 = disabled).
  function setRebalanceConfig(
    PositionManagerStorageData storage self,
    uint16 maxRebalanceLoss_,
    uint40 rebalanceCooldown_
  ) internal {
    if (maxRebalanceLoss_ > MAX_REBALANCE_LOSS) {
      revert LibManagerErrors.MaxRebalanceLossExceedsMax();
    }
    self.rebalanceConfig.maxRebalanceLoss = maxRebalanceLoss_;
    self.rebalanceConfig.rebalanceCooldown = rebalanceCooldown_;
    emit IPositionManagerAdmin.RebalanceConfigSet(maxRebalanceLoss_, rebalanceCooldown_);
  }

  /// @dev Updates the `lastTotalAssets` and `lastDebt` snapshots to their current values in a
  ///      single iteration over the borrow modules. `lastDebt` aggregates only non-bad-debt
  ///      positions (the same set whose NAV contributes to `lastTotalAssets`), so
  ///      `lastCollat = lastTotalAssets + lastDebt` represents the collateral of "good" positions.
  ///      The `totalCollateral` third return from `totalAssets` is discarded — only the
  ///      performance-fee snapshot needs to be persisted; the management fee re-reads collat live.
  /// @param self The storage pointer to the PositionManagerStorageData struct.
  function updateSnapshot(PositionManagerStorageData storage self) internal {
    (uint256 newTotalAssets, uint256 newDebt,) = LibView.totalAssets(self);
    self.lastTotalAssets = newTotalAssets;
    self.lastDebt = newDebt;
  }
}
