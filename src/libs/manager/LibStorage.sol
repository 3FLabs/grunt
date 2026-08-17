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
///        drawdowns stay inside the basis. The basis is then reduced by the pending management
///        fee deduction (`heldManagementFeeAssets` plus the current interval's charge).
///        Replaces the prior NAV-variation basis.
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
///        crystallizes (or on bootstrap); on capital flows it is rebased so the pending basis is
///        preserved (see `rebaseSnapshot`). It therefore only matches the live NAV right
///        after a crystallizing accrual; while the reference is held it deviates from the live
///        NAV by the carried (negative) pending basis, or sits below it by a preserved positive
///        pending gain (see `rebaseSnapshot`); after a seizure loss, flows convert the
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
///        lower than the live debt by the carried debt cost (or higher by a preserved pending
///        gain, see `rebaseSnapshot`). A value of zero acts as a bootstrap
///        sentinel: the first accrual after upgrade (or any other time `lastDebt` is zero) skips
///        the performance fee and seeds this slot with the current debt. Subsequent accruals
///        charge the new basis normally.
/// @param heldManagementFeeAssets Management fee assets charged while the performance reference
///        was held and not yet netted against a crystallized basis. The performance fee must be
///        net of management fees, so at the next crystallization this amount (plus the current
///        interval's management fee) is deducted from the basis. A crystallizing advance
///        consumes the accumulator only up to the basis and carries the excess (a dust-positive
///        basis must not write the whole deduction off, see `_pendingFees`); a reseed advance
///        (bootstrap, empty vault) or `resetPerformanceReference` clears it, as does a flow
///        that burns the last share (no holders left, so no one is owed the deduction —
///        Cantina #7). Capital flows
///        never rescale it: the supply ratio is a permissionless value-detached lever — up
///        would manufacture credit near zero NAV, down would let a deposit/exit round trip
///        grind the deduction away (see `rebaseSnapshot`). Appended to the struct so the layout
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
  ///      flow (deposit, withdraw, burn, rebalance, module add/remove) so the pending
  ///      performance basis is preserved instead of being reset to zero (the debt carry per
  ///      share, a held positive gain nominally).
  ///
  ///      The reference encodes `LTV_ref = lastDebt / (lastTotalAssets + lastDebt)`; the pending
  ///      basis at any state is `LTV_ref * collat - debt`. Flows change collateral, debt, and
  ///      share supply without realising a gain, so the reference must move with them: the carry
  ///      (the negative pending basis accumulated while the reference is held, typically accrued
  ///      debt interest under a flat collateral quote) is scaled by the share-supply change and
  ///      re-anchored on the post-flow state. The carry taken is the larger of the levered read
  ///      and the NAV deficit (mark minus pre-flow NAV): a seizure leaves NAV below the mark
  ///      while the levered read stays non-negative, and taking the deficit there keeps the
  ///      high-water mark that the NAV-gain cap in `_pendingFees` measures against intact
  ///      across any number of flows, even when the deficit exceeds the remaining debt (see
  ///      the oversized-carry encoding below); an ordinary drawdown (levered carry at or above
  ///      the deficit) keeps the pre-existing levered-carry semantics. Exits shed their
  ///      proportional slice of the carry, deposits re-attach it to the new shares, and
  ///      supply-neutral flows (rebalance, module changes) keep it unchanged. A holder
  ///      therefore cannot shed accrued debt carry by exiting and re-entering, and an exit
  ///      does not dump its carry slice on the stayers.
  ///
  ///      Called after `_accrueFees`, which crystallizes a positive basis except in two held
  ///      states: a NAV-capped basis (seizure loss, see the cap in `_pendingFees`) and a
  ///      performance entitlement that rounds to zero fee assets or shares. Both survive the
  ///      flow: the seizure as the carried deficit above, and the held entitlement as a
  ///      preserved pending gain (capped at the NAV gain above the mark), encoded as reference
  ///      debt above the live debt so the next accrual reads the same capped basis back.
  ///      Without that preservation, repeated economically empty flows (zero-op rebalances at
  ///      cooldown cadence) would forgive each interval's entitlement and erase the fee. The
  ///      gain is kept nominal across the flow, like the held management fee accumulator and
  ///      for the same reason (the supply ratio is a value-detached lever; see the gain
  ///      comment in the body), falling back to the supply-scaled read once it outgrows half
  ///      the post-flow NAV, so a supply-changing flow cannot leave a degenerate near-zero
  ///      mark (a supply-neutral flow that drops the NAV below the gain still truncates, as
  ///      before this fix: that path is rebalancer/owner-gated and owner-remediable). The
  ///      residual is
  ///      the mirror of the held-deduction one: an exit leaves its sub-share slice of the
  ///      pending entitlement with the stayers, remediable via `resetPerformanceReference`.
  ///      The held management fee accumulator nets against the next crystallization as
  ///      usual. Rounding matches `_pendingFees` (`mulDivUp` on the scaled reference debt), so
  ///      the carry is the exact complement of the fee basis and each flow can only shrink it
  ///      (or the preserved gain) by rounding dust, never create a spurious positive basis.
  ///
  ///      Partial bad-debt episode: while some (not all) modules are excluded as bad debt, the
  ///      accrual freezes the reference instead of crystallizing (see `_pendingFees`), so a
  ///      flow here compares the frozen full-universe mark with reduced aggregates and the
  ///      re-anchor is approximate. When the exclusion hides a loss, the seizure conversion
  ///      measures the deficit against the reduced universe and holds a mark near the frozen
  ///      full-universe one (the oversized-carry encoding keeps it even above the visible
  ///      debt), so the post-window recovery is charged only past that mark; when the visible
  ///      NAV sits above the frozen mark, the levered read can carry a phantom gain, preserved
  ///      only up to the visible NAV gain above the mark. Either way the re-anchor can under-
  ///      or over-read the later recovery. Remedies for a mis-anchored window flow: an owner
  ///      reset once the window has closed re-anchors at the live state, but it crystallizes
  ///      any positive pending basis first, so to avoid charging a mis-read recovery the
  ///      owner should instead set the performance fee rate to zero right after the flow,
  ///      let the first accrual with a positive basis advance the reference mintlessly (a
  ///      positive basis advances even at a zero rate), and then restore the rate. An
  ///      under-read needs no action (fees resume at a genuine new high, or an owner reset
  ///      re-anchors sooner).
  ///
  ///      The held management fee accumulator (`heldManagementFeeAssets`, the management fees
  ///      charged and not yet netted against a crystallized basis, deducted from the next
  ///      positive basis) is never rescaled by a flow: it counts fees actually charged, and
  ///      the supply ratio is a permissionless value-detached lever in both directions.
  ///      Scaling up would let a ratio minted near zero NAV — where the mint denominator is
  ///      the virtual asset base, reachable with a dust repay that lifts NAV one atom off
  ///      zero followed by a dust deposit that nearly doubles the supply — manufacture credit
  ///      far beyond the fees ever charged (Cantina #30), and the rescue flow out of a full
  ///      bad-debt episode has an equally unmoored ratio. Scaling down, even only on exits,
  ///      would let a deposit/exit round trip that restores the vault state grind the
  ///      deduction toward zero with reversible capital and overcharge the next
  ///      crystallization. The accumulator therefore stays nominal and the per-share
  ///      deduction dilutes or concentrates with the supply; the residual recipient-side
  ///      cost — a large exit leaves a deduction accrued mostly by the departed shares — is
  ///      bounded by fees the recipient already collected and remediable via
  ///      `resetPerformanceReference`, which clears it. The one flow that does write it is a
  ///      full exit (`newSupply == 0`): no holders, no one owed the deduction, and during a
  ///      bad-debt window the empty-vault reseed clear is suppressed, so without the terminal
  ///      clear a post-window depositor would inherit the departed cohort's credit
  ///      (Cantina #7). An exit that merely empties the good-debt universe while shares
  ///      remain (the reference-hold early return) leaves it nominal like any other exit.
  ///      In the fallback branches too: outside a
  ///      bad-debt window every such state (sentinel, empty vault) forces `advanceReference` on
  ///      the next accrual, which clears the accumulator before any performance fee can consume
  ///      it; during a window the accrual holds instead (see `_pendingFees`) and the accumulator
  ///      keeps accruing the window's management fees for the eventual post-window netting,
  ///      which matches its definition (fees charged since the last advance).
  ///
  ///      Edge cases collapse to a plain snapshot of the current state (zero carry): bootstrap
  ///      (`lastDebt == 0` sentinel), an empty vault before the flow, and a degenerate
  ///      zero-NAV reference (its leftover carry is forgiven through the zero floor as dust).
  ///      A carry at or above the post-flow debt, including a flow that unwinds the debt to
  ///      zero, no longer collapses to the sentinel: the oversized-carry encoding re-anchors
  ///      the mark at `NAV + carry` at the pre-flow reference LTV instead (see the write-out
  ///      branches). An empty good-debt universe after the flow instead holds the
  ///      reference (see the bad-debt episode below).
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
    // A flow that burns the last share clears the pending management fee deduction: with no
    // holders left no one is owed it, and it must not survive as a shield for a later cohort
    // that never paid the fees (Cantina #7). Outside a bad-debt window the next accrual's
    // empty-vault reseed clears the accumulator anyway; during a window that accrual holds
    // instead (see `_pendingFees`), so without this clear a post-window depositor would
    // inherit the departed cohort's credit. Unlike a supply-ratio rescale, the terminal clear
    // is not a permissionless lever: only the sole remaining holder can trigger it, and the
    // only shield it destroys is their own.
    if (newSupply == 0) self.heldManagementFeeAssets = 0;
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
    uint256 gain;
    if (refDebt > 0 && prevSupply > 0 && newSupply > 0) {
      uint256 refCollat = self.lastTotalAssets + refDebt;
      uint256 scaledRefDebt = refDebt.mulDivUp(prevCollat, refCollat);
      uint256 prevCarry = FixedPointMathLib.zeroFloorSub(prevDebt, scaledRefDebt);
      // Seizure state: a liquidation cuts collateral and debt in a ratio that leaves NAV below
      // the mark while the levered read stays non-negative, so the levered carry alone would
      // drop the mark toward the post-loss trough. Take the larger of the levered carry and
      // the NAV deficit (mark minus pre-flow NAV, zero when NAV is at or above the mark): the
      // deficit exceeds the levered carry exactly when quoted collateral sits below the
      // reference collateral (the seizure signature), so ordinary drawdowns keep the levered
      // carry semantics while a seizure holds the full NAV mark, including across repeated
      // flows (a converted deficit reads back through this same branch, not the levered one).
      // The empty pre-flow universe is excluded (full-episode re-anchor, see the header).
      if (prevCollat > 0) {
        uint256 deficit = FixedPointMathLib.zeroFloorSub(self.lastTotalAssets + prevDebt, prevCollat);
        if (deficit > prevCarry) prevCarry = deficit;
      }
      // Held positive pending basis (the zero-fee-share hold in `_pendingFees`): preserve it
      // across the flow instead of re-anchoring on top of it, or repeated economically empty
      // flows (e.g. zero-op rebalances at cooldown cadence) would forgive each interval's
      // entitlement and erase the performance fee. Capped at the NAV gain above the mark,
      // mirroring the cap in `_pendingFees`, so a seizure state (NAV at or below the mark)
      // never reads a preservable gain. Mutually exclusive with the carry by construction.
      // Kept nominal like the held management fee accumulator, and for the same reason: the
      // supply ratio is a value-detached lever, so scaling up would turn a dust entitlement
      // into a fee on fresh deposit principal (Cantina #32 follow-up) and scaling down would
      // let a deposit/exit round trip grind the entitlement away.
      if (prevCarry == 0) {
        gain = FixedPointMathLib.zeroFloorSub(scaledRefDebt, prevDebt)
          .min(FixedPointMathLib.zeroFloorSub(prevCollat - prevDebt, self.lastTotalAssets));
        // A gain at or above the post-flow NAV would leave a degenerate mark (the clamp
        // below zeroes it and the next accrual would read the entire NAV as basis): once the
        // gain outgrows half the post-flow NAV, shed it proportionally like a pre-hold exit
        // instead. The `min` never scales up, so deposits keep the nominal gain. A deposit and
        // exit round trip can still shed a gain in this region by the deposit-inflated ratio;
        // accepted: the loss lands on the fee recipient only, and the hold keeps a genuine
        // entitlement below one raw share's worth of fees.
        if (gain > (newCollat - newDebt) / 2) gain = gain.min(gain.mulDiv(newSupply, prevSupply));
      }
      // Preserve the per-share carry across the supply change.
      carry = prevCarry.mulDiv(newSupply, prevSupply);
      // Unlike the carry, the held management fee accumulator is deliberately not rescaled
      // either: it counts fees actually charged, and the supply ratio is a permissionless
      // value-detached lever in both directions (see the held-accumulator paragraph in the
      // header).
    }
    uint256 newRefDebt;
    uint256 newRefTotalAssets;
    if (gain > 0) {
      // Held positive basis: encode it as reference debt above the live debt, so the mark
      // (`lastTotalAssets`) lands at NAV minus the gain and the NAV-gain cap in `_pendingFees`
      // reads back exactly the preserved entitlement. Clamped at `newCollat` as a final guard
      // so the reference NAV stays non-negative (the supply-scaled fallback above normally
      // keeps the clamp slack).
      newRefDebt = (newDebt + gain).min(newCollat);
      newRefTotalAssets = newCollat - newRefDebt;
    } else if (carry >= newDebt && carry > 0 && self.lastTotalAssets > 0) {
      // Oversized carry (a seizure NAV deficit at or above the remaining debt, e.g. after a
      // near-full liquidation): the standard encoding would floor the reference debt at zero,
      // which is the bootstrap sentinel, and the next accrual would reseed the high-water mark
      // at the post-loss trough. Re-anchor the mark at `NAV + carry` and keep the pre-flow
      // reference LTV (reference debt proportional to the mark at the old debt-to-NAV ratio):
      // the mark survives, later flows read the full deficit back through the max branch
      // above, and the levered read turns positive again on the same terms as before the
      // flow, so fees resume once NAV clears the preserved mark instead of staying dormant
      // behind a diluted reference LTV. `refDebt` still holds the pre-flow stored value here.
      // Rounding up keeps the reference debt nonzero (never the sentinel) and biases the
      // levered read larger, consistent with `_pendingFees`.
      newRefTotalAssets = newCollat - newDebt + carry;
      newRefDebt = newRefTotalAssets.mulDivUp(refDebt, self.lastTotalAssets);
    } else {
      // `carry < newDebt` here (or a degenerate zero-NAV reference, whose leftover carry is
      // forgiven through the zero floor as dust): the subtraction cannot reach the sentinel.
      newRefDebt = FixedPointMathLib.zeroFloorSub(newDebt, carry);
      // Good-debt aggregation guarantees newCollat >= newDebt >= newRefDebt.
      newRefTotalAssets = newCollat - newRefDebt;
    }
    self.lastDebt = newRefDebt;
    self.lastTotalAssets = newRefTotalAssets;
  }
}
