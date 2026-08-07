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
/// @param managementFee The management fee rate in basis points per year (e.g., 200 = 2%), charged
///        on the aggregate quoted collateral of non-bad-debt positions — *not* on NAV. For a
///        leveraged vault this basis is materially larger than the NAV. The resulting fee assets
///        are capped at `totalAssets` so the post-fee asset base remains non-negative.
/// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%), charged on the
///        performance of the levered slice only — basis `LTV_ref * Δcollat - Δdebt` (equivalently
///        `mulDivUp(lastDebt, currentCollat, lastCollat) - currentDebt`), where
///        `LTV_ref = lastDebt / lastCollat` is the LTV at the performance reference. The reference
///        is held while the basis is non-positive (high-water mark) and advances only when a fee
///        crystallizes, so debt interest accrued under a flat collateral quote and collateral
///        drawdowns stay inside the basis. The basis is then reduced by the management fees
///        charged since the reference last advanced (`heldManagementFeeAssets` plus the current
///        interval's charge). Replaces the prior NAV-variation basis.
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
/// @param lastTotalAssets NAV component of the performance reference (`refCollat - refDebt`).
///        Together with `lastDebt` it encodes the reference loan-to-value
///        `LTV_ref = lastDebt / (lastTotalAssets + lastDebt)` that anchors the performance-fee
///        basis. The reference advances to the current state only when a positive basis
///        crystallizes (or on bootstrap); on capital flows it is rebased so the pending per-share
///        basis is preserved (see `rebaseSnapshot`). It therefore only matches the live NAV right
///        after a crystallizing accrual; while the reference is held it deviates from the live
///        NAV by the carried (negative) pending basis; after a seizure loss, flows convert the
///        NAV drawdown against it into that carry (see `rebaseSnapshot`). `lastCollat` is
///        reconstructed on the fly as `lastTotalAssets + lastDebt` rather than stored directly,
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
/// @param lastDebt Debt component of the performance reference. Used together with
///        `lastTotalAssets` to reconstruct `lastCollat = lastTotalAssets + lastDebt` for the
///        levered-slice performance fee basis. Advanced on crystallization and rebased on flows
///        alongside `lastTotalAssets` (see `rebaseSnapshot`), so while the reference is held it is
///        lower than the live debt by the carried debt cost. A value of zero acts as a bootstrap
///        sentinel: the first accrual after upgrade (or any other time `lastDebt` is zero) skips
///        the performance fee and seeds this slot with the current debt. Subsequent accruals
///        charge the new basis normally.
/// @param heldManagementFeeAssets Management fee assets charged while the performance reference
///        was held, accumulated since the reference last advanced. The performance fee must be
///        net of management fees, so at the next crystallization this amount (plus the current
///        interval's management fee) is deducted from the basis, and the accumulator is cleared
///        whenever the reference advances (crystallization, bootstrap, empty vault) or the owner
///        calls `resetPerformanceReference`. Flows scale it with the share-supply change so the
///        per-share deduction is preserved, except a rescue flow out of a full bad-debt episode,
///        which keeps it nominal (see `rebaseSnapshot`). Appended to the struct so the layout
///        stays append-only; reads zero on upgrade (a clean start).
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
  ///      flow (deposit, withdraw, burn, rebalance, module add/remove) so the pending per-share
  ///      performance basis is preserved instead of being reset to zero.
  ///
  ///      The reference encodes `LTV_ref = lastDebt / (lastTotalAssets + lastDebt)`; the pending
  ///      basis at any state is `LTV_ref * collat - debt`. Flows change collateral, debt, and
  ///      share supply without realising a gain, so the reference must move with them: the carry
  ///      (the negative pending basis accumulated while the reference is held, typically accrued
  ///      debt interest under a flat collateral quote) is scaled by the share-supply change and
  ///      re-anchored on the post-flow state. When the carry reads zero while NAV sits below
  ///      the mark (a seizure leaves a NAV deficit with a non-negative levered read), the
  ///      deficit is converted into carry form, so the high-water mark that the NAV-gain cap
  ///      in `_pendingFees` measures against survives flows; an ordinary drawdown (nonzero
  ///      carry) keeps the pre-existing semantics, under which a flow re-anchors the mark at
  ///      NAV plus the levered carry only. Exits shed their proportional slice of the carry,
  ///      deposits re-attach it to the new shares, and supply-neutral flows (rebalance, module
  ///      changes) keep it unchanged. A holder therefore cannot shed accrued debt carry by
  ///      exiting and re-entering, and an exit does not dump its carry slice on the stayers.
  ///
  ///      Called after `_accrueFees`, which crystallizes a positive basis except in two held
  ///      states: a NAV-capped basis (seizure loss, see the cap in `_pendingFees`) and a
  ///      performance entitlement that converts to zero fee shares. In both, the flow forgives
  ///      the pending levered gain (for the zero-share hold the forgiven entitlement is
  ///      bounded by one share's assets); for the seizure the converted deficit keeps the cap
  ///      suspending fees after the flow. The held management fee accumulator is not cleared
  ///      by the forgiveness and nets against the next crystallization. Rounding matches
  ///      `_pendingFees` (`mulDivUp` on the scaled reference debt), so the carry is the exact
  ///      complement of the fee basis and each flow can only shrink it by rounding dust, never
  ///      create a spurious positive basis.
  ///
  ///      Partial bad-debt episode: while some (not all) modules are excluded as bad debt, the
  ///      accrual freezes the reference instead of crystallizing (see `_pendingFees`), so a
  ///      flow here compares the frozen full-universe mark with reduced aggregates and the
  ///      re-anchor is approximate; the phantom gain itself is never preserved. When the
  ///      visible carry reads zero (the visible LTV sits below the frozen reference LTV), the
  ///      seizure conversion measures the deficit against the reduced universe; it typically
  ///      exceeds the post-flow debt, so the sentinel clamp writes the bootstrap sentinel and
  ///      the first post-window accrual reseeds the reference at the state it observes without
  ///      charging (the window recovery is forgiven, LP-favorable). With a positive visible
  ///      carry the ordinary carry semantics re-anchor instead, which can under- or over-read
  ///      the later recovery. Remedies for a mis-anchored window flow: an owner reset once the
  ///      window has closed re-anchors at the live state, but it crystallizes any positive
  ///      pending basis first, so to avoid charging a mis-read recovery the owner should
  ///      instead set the performance fee rate to zero right after the flow, let the first
  ///      accrual with a positive basis advance the reference mintlessly (a positive basis
  ///      advances even at a zero rate), and then restore the rate. An under-read needs no
  ///      action (fees resume at a genuine new high, or an owner reset re-anchors sooner).
  ///
  ///      The held management fee accumulator (`heldManagementFeeAssets`, the management fees
  ///      charged since the reference last advanced, deducted from the next positive basis) is
  ///      scaled by the same supply ratio: an exit takes its slice of the pending deduction along,
  ///      a deposit re-attaches it to the new shares. A rescue flow out of a full bad-debt
  ///      episode (`prevCollat == 0`) keeps it nominal instead: shares mint against a zero asset
  ///      base there, so the supply ratio is unmoored and scaling would inflate the deduction
  ///      beyond the fees ever charged. In the fallback branches it is left in place: outside a
  ///      bad-debt window every such state (sentinel, empty vault) forces `advanceReference` on
  ///      the next accrual, which clears the accumulator before any performance fee can consume
  ///      it; during a window the accrual holds instead (see `_pendingFees`) and the accumulator
  ///      keeps accruing the window's management fees for the eventual post-window netting,
  ///      which matches its definition (fees charged since the last advance).
  ///
  ///      Edge cases collapse to a plain snapshot of the current state (zero carry): bootstrap
  ///      (`lastDebt == 0` sentinel), an empty vault before the flow, and a carry exceeding the
  ///      post-flow debt (the reference debt floors at zero, which is the bootstrap sentinel, so
  ///      the excess is forgiven and the next accrual reseeds). The last case includes an
  ///      oversized converted seizure deficit, e.g. a flow that unwinds debt below the seizure
  ///      loss: the reseed then lands at the state the next accrual observes, and the recovery
  ///      from there is charged unless the owner applies the temporary zero-rate remedy above.
  ///      An empty good-debt universe after the flow instead holds the reference (see the
  ///      bad-debt episode below).
  ///
  ///      Bad-debt episode: whenever the flow leaves the good-debt universe empty
  ///      (`newCollat == 0` with a live reference), there is no good-debt state to re-anchor on,
  ///      so the reference is held unchanged, exactly like an accrual during the same episode.
  ///      This covers a flow executed while every position is already underwater and, just as
  ///      important, the flow that empties the universe itself: removing or draining the last
  ///      healthy module while the others stay underwater must not write the bootstrap sentinel,
  ///      or the first post-recovery accrual would reseed the high-water mark at the trough and
  ///      re-charge the recovery from there. A flow that brings the pool back above water
  ///      re-anchors the reference at the post-flow state (the pre-flow basis is not measurable
  ///      against empty aggregates), so gains recovered beyond that point are charged; this is a
  ///      documented limitation of the binary bad-debt exclusion in `LibView.totalAssets`.
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
    // Hold the reference across any flow that leaves the good-debt universe empty: with no
    // good-debt state to re-anchor on, rebasing would write the bootstrap sentinel and the next
    // accrual would reseed the high-water mark at the recovery trough, re-charging the recovery.
    // This covers a flow executed while every position is already underwater as well as the flow
    // that empties the universe itself (the last healthy module removed or drained while the
    // others stay underwater). A flow that empties the vault outright is held too; the next
    // accrual advances the reference anyway (empty vault), so no stale mark survives it.
    if (refDebt > 0 && newCollat == 0) return;
    uint256 carry;
    if (refDebt > 0 && prevSupply > 0 && newSupply > 0) {
      uint256 refCollat = self.lastTotalAssets + refDebt;
      uint256 scaledRefDebt = refDebt.mulDivUp(prevCollat, refCollat);
      uint256 prevCarry = FixedPointMathLib.zeroFloorSub(prevDebt, scaledRefDebt);
      // Seizure state: a liquidation leaves NAV below the mark while the levered read is
      // non-negative, so `prevCarry` reads zero and the re-anchor below would drop the mark to
      // the post-loss trough. Carry the NAV deficit (mark minus pre-flow NAV, zero when NAV is
      // at or above the mark) instead: the mark then lands at `NAV + deficit`, and later flows
      // read the same deficit back through the standard carry path. The empty pre-flow
      // universe is excluded (full-episode re-anchor, see the header); the oversized-deficit
      // edge is covered by the sentinel clamp below (see the header's edge cases).
      if (prevCarry == 0 && prevCollat > 0) {
        prevCarry = FixedPointMathLib.zeroFloorSub(self.lastTotalAssets + prevDebt, prevCollat);
      }
      // Preserve the per-share carry across the supply change.
      carry = prevCarry.mulDiv(newSupply, prevSupply);
      if (carry > newDebt) carry = newDebt;
      // Preserve the per-share pending management fee deduction the same way. Skipped when the
      // pre-flow good-debt universe is empty (a rescue flow out of a full bad-debt episode):
      // shares are then minted against a zero asset base, so the supply ratio is unmoored from
      // any price and scaling would inflate the deduction far beyond the fees ever charged. The
      // accumulator stays nominal instead, matching its definition (fees charged since the last
      // advance).
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
