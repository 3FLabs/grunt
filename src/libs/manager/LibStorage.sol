// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IPositionManagerAdmin, SupplyQueueEntry} from "../../interfaces/manager/base/IPositionManagerAdmin.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {LibChecks} from "../common/LibChecks.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {STORAGE_SLOT, MAX_REBALANCE_LOSS} from "./LibConstants.sol";
import {LibManagerErrors} from "./LibManagerErrors.sol";

/// @notice Fee configuration data for the PositionManager.
/// @param feeRecipient The address that receives fee payments
/// @param managementFee The management fee rate in basis points per year (e.g., 200 = 2%),
///        charged on the aggregate quoted collateral of non-bad-debt positions, not on NAV
/// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%), charged on
///        the levered-slice basis against a held reference (high-water mark);
///        see docs/position-manager.md#fees
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
/// @param lastTotalAssets NAV component of the performance reference. The reference collateral
///        is reconstructed as `lastTotalAssets + lastDebt` rather than stored, keeping the
///        storage layout append-only. See docs/position-manager.md#fees.
/// @param ltv Loan-to-value ratio in 18-decimal fixed point (e.g., 0.86e18 = 86%).
///        A small buffer above the target LTV that determines how much collateral can be withdrawn.
/// @param virtualShareOffset Virtual share offset for inflation attack protection, computed as
///        10^(18 - debtAsset.decimals()); fewer decimals give stronger protection. For 18-decimal
///        debt assets the protection is weak and deployers must seed the vault with an initial
///        deposit (see docs/known-issues.md#position-manager).
/// @param lastFeeAccrualTimestamp Unix timestamp of the last fee accrual, used for
///        calculating time-weighted management fees.
/// @param transferGuard Address of the TransferGuard contract that validates share transfers
///        for compliance (blocklist/whitelist checks). Zero address disables transfer validation.
/// @param rebalanceConfig Rebalance parameters packed in a single struct (maxRebalanceLoss, cooldown, timestamp).
/// @param lastDebt Debt component of the performance reference. Zero is the bootstrap sentinel:
///        the next accrual skips the performance fee and reseeds the reference.
///        See docs/position-manager.md#the-reference-as-a-high-water-mark.
/// @param heldManagementFeeAssets Management fees charged while the performance reference was
///        held; deducted from the next crystallization and cleared when the reference advances
///        or is reset. Scaled with the share supply across flows (see `rebaseSnapshot`).
///        See docs/position-manager.md#the-reference-as-a-high-water-mark.
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
  uint256 heldManagementFeeAssets;
}

/// @title LibStorage
/// @author 3F Protocol
/// @notice Library providing storage accessor for PositionManager contracts.
/// @dev Uses a custom storage slot pattern for upgradeability.
library LibStorage {
  using FixedPointMathLib for uint256;

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

  /// @dev Rebases the performance reference (`lastTotalAssets`, `lastDebt`) across a capital
  ///      flow (deposit, withdraw, burn, rebalance, module add/remove): the carried pending
  ///      basis is scaled by the share-supply change and re-anchored on the post-flow state, so
  ///      exits shed their slice of the carry and deposits re-attach it to the new shares.
  ///      Called after `_accrueFees` has crystallized any positive basis, so outside a bad-debt
  ///      window the carry is non-positive; rounding matches `_pendingFees` (`mulDivUp` on the
  ///      scaled reference debt), so a flow can only shrink the carry by rounding dust, never
  ///      create a spurious positive basis. Flows inside a partial bad-debt window can
  ///      mis-anchor the reference; for the mis-anchoring cases and their remedies see
  ///      docs/position-manager.md#the-reference-as-a-high-water-mark.
  /// @param self The storage pointer to the PositionManagerStorageData struct.
  /// @param prevCollat The aggregate good-debt collateral before the flow (post fee accrual).
  /// @param prevDebt The aggregate good-debt debt before the flow (post fee accrual).
  /// @param prevSupply The share supply before the flow (including freshly minted fee shares).
  /// @param newCollat The aggregate good-debt collateral after the flow.
  /// @param newDebt The aggregate good-debt debt after the flow.
  /// @param newSupply The share supply after the flow.
  function rebaseSnapshot(
    PositionManagerStorageData storage self,
    uint256 prevCollat,
    uint256 prevDebt,
    uint256 prevSupply,
    uint256 newCollat,
    uint256 newDebt,
    uint256 newSupply
  ) internal {
    uint256 refDebt = self.lastDebt;
    // No good-debt state to re-anchor on: hold the reference. Writing the bootstrap sentinel
    // here would let the next accrual reseed the high-water mark at the recovery trough. A flow
    // that empties the vault outright is held too; the next accrual advances anyway (empty vault).
    if (refDebt > 0 && newCollat == 0) return;
    uint256 carry;
    // When this branch is skipped (bootstrap sentinel, empty pre- or post-flow supply), the held
    // management fee accumulator is deliberately left in place: outside a bad-debt window every
    // such state forces the next accrual to advance the reference, which clears the accumulator
    // before any performance fee can consume it; during a window the accrual holds instead and
    // the accumulator keeps collecting that window's management fees for post-window netting.
    if (refDebt > 0 && prevSupply > 0 && newSupply > 0) {
      uint256 refCollat = self.lastTotalAssets + refDebt;
      uint256 scaledRefDebt = refDebt.mulDivUp(prevCollat, refCollat);
      uint256 prevCarry = FixedPointMathLib.zeroFloorSub(prevDebt, scaledRefDebt);
      // Preserve the per-share carry across the supply change.
      carry = prevCarry.mulDiv(newSupply, prevSupply);
      if (carry > newDebt) carry = newDebt;
      // Preserve the per-share pending management fee deduction the same way. Skipped when the
      // pre-flow good-debt universe is empty (a rescue flow out of a full bad-debt episode): the
      // supply ratio is then unmoored and scaling would inflate the deduction; it stays nominal.
      if (newSupply != prevSupply && prevCollat > 0) {
        uint256 heldManagementFeeAssets = self.heldManagementFeeAssets;
        if (heldManagementFeeAssets > 0) {
          self.heldManagementFeeAssets = heldManagementFeeAssets.mulDiv(newSupply, prevSupply);
        }
      }
    }
    uint256 newRefDebt = newDebt - carry;
    self.lastDebt = newRefDebt;
    // Good-debt aggregation guarantees newCollat >= newDebt >= newRefDebt.
    self.lastTotalAssets = newCollat - newRefDebt;
  }
}
