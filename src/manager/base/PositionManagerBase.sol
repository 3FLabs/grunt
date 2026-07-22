// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IPositionManagerLP} from "../../interfaces/manager/base/IPositionManagerLP.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {SECONDS_PER_YEAR} from "../../libs/manager/LibConstants.sol";
import {BPS} from "../../libs/Constants.sol";
import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PositionManagerBase
/// @author 3F Protocol
/// @notice Abstract base contract for PositionManager providing roles, fee accrual, and snapshot management.
/// @dev Inherits OwnableRoles for role-based access control, ERC20 for share token functionality,
///      and ReentrancyGuardTransient for reentrancy protection.
abstract contract PositionManagerBase is OwnableRoles, ERC20, ReentrancyGuardTransient {
  using FixedPointMathLib for uint256;
  using LibStorage for PositionManagerStorageData;
  using LibView for PositionManagerStorageData;
  using LibView for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSTANTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to mint/burn shares via deposit/withdraw/burn.
  uint256 internal constant MINTER_ROLE = _ROLE_0;

  /// @notice Role for addresses authorized to set supply/withdrawal queues.
  uint256 internal constant CURATOR_ROLE = _ROLE_1;

  /// @notice Role for addresses authorized to execute rebalancing operations.
  uint256 internal constant REBALANCER_ROLE = _ROLE_2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      FEE ACCRUAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Computes pending fee shares without mutating state.
  ///
  ///      Management fee: time-based on the aggregate collateral of non-bad-debt positions (not
  ///      on the NAV), capped at `totalAssets_` so the fee-adjusted base stays non-negative.
  ///      Performance fee: charged on the levered-slice basis `LTV_ref * currentCollat - currentDebt`
  ///      measured against the stored reference (`lastTotalAssets`, `lastDebt`), net of the
  ///      management fees charged since the reference last advanced. The reference advances only
  ///      on a positive basis (even when the configured rate is zero), bootstrap
  ///      (`lastDebt == 0`), or an empty vault; otherwise it is held as a high-water mark, and it
  ///      is frozen entirely while any module is excluded as bad debt. Full model, derivations,
  ///      and bad-debt episode semantics: see docs/position-manager.md#fees.
  /// @return totalAssets_ The current total assets across all borrow modules (`collateralQuoted - debt`)
  /// @return totalSupply_ The current total supply of shares (before fee minting)
  /// @return currentDebt The current aggregate debt across non-bad-debt positions
  /// @return managementFeeShares The shares that would be minted for management fees
  /// @return performanceFeeShares The shares that would be minted for performance fees
  /// @return advanceReference True when `_accrueFees` must advance the performance reference to
  ///         the current state (positive basis, bootstrap, or empty vault); false to hold it.
  ///         Always false while any module is excluded as bad debt
  /// @return heldManagementFees_ The value `_accrueFees` must persist as the held management fee
  ///         accumulator: zero when the reference advances (deduction consumed or forgiven),
  ///         otherwise the stored accumulator plus the management fee charged this interval
  function _pendingFees()
    internal
    view
    returns (
      uint256 totalAssets_,
      uint256 totalSupply_,
      uint256 currentDebt,
      uint256 managementFeeShares,
      uint256 performanceFeeShares,
      bool advanceReference,
      uint256 heldManagementFees_
    )
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();

    // Use ERC20.totalSupply() to bypass the nonReadReentrant override on the public totalSupply(),
    // since _pendingFees() is reachable from _accrueFees() during a guarded deposit/withdraw/burn.
    totalSupply_ = ERC20.totalSupply();

    uint256 managementFeeAssets;
    uint256 totalFeeAssets;
    {
      // Single iteration over borrow modules returns the NAV, the aggregate debt, the aggregate
      // quoted collateral, and the bad-debt exclusion flag of non-bad-debt positions in one pass.
      uint256 currentCollat;
      bool hasBadDebt;
      (totalAssets_, currentDebt, currentCollat, hasBadDebt) = _storage.totalAssets();

      // Levered-slice basis against the held reference. Computed regardless of the fee
      // configuration because it also drives the reference-advance decision. While any module is
      // excluded as bad debt (`hasBadDebt`) the basis is not measurable (the excluded debt is
      // missing from `currentDebt` and can flip the basis positive mid-drawdown), so the
      // reference is frozen for the whole window: no crystallization, advance, or bootstrap
      // seed. See docs/position-manager.md#the-reference-as-a-high-water-mark.
      uint256 basis;
      {
        uint256 _lastDebt = _storage.lastDebt;
        if (_lastDebt == 0 || totalSupply_ == 0) {
          // Bootstrap sentinel or empty vault: no reference to measure against (lastCollat would
          // be zero or meaningless); skip the performance fee and (re)seed the reference.
          advanceReference = !hasBadDebt;
        } else if (!hasBadDebt) {
          uint256 lastCollat = _storage.lastTotalAssets + _lastDebt;
          // basis = mulDiv(lastDebt, currentCollat, lastCollat) - currentDebt
          //       = LTV_ref * currentCollat - currentDebt
          // Round up on the minuend (mulDivUp) so the basis is biased larger; favors the
          // protocol, consistent with conservative-to-protocol rounding elsewhere.
          uint256 scaledLastDebt = _lastDebt.mulDivUp(currentCollat, lastCollat);
          if (scaledLastDebt > currentDebt) {
            basis = scaledLastDebt - currentDebt;
            advanceReference = true;
          }
        }
      }

      // Loaded after the basis block to keep the peak stack depth flat (the block above is at
      // the non-via-ir stack limit).
      FeeData memory fd = _storage.feeData;
      if (fd.feeRecipient == address(0) || totalSupply_ == 0) {
        // No fee is charged, so the accumulator carries over unchanged unless the reference
        // advances (a positive basis still consumes the pending deduction).
        heldManagementFees_ = advanceReference ? 0 : _storage.heldManagementFeeAssets;
        return (totalAssets_, totalSupply_, currentDebt, 0, 0, advanceReference, heldManagementFees_);
      }

      // Management fee: charged on the aggregate good-debt collateral, time-weighted, then capped
      // at totalAssets_ so the post-fee asset base stays non-negative for share conversion.
      if (fd.managementFee > 0) {
        uint256 elapsed = block.timestamp - _storage.lastFeeAccrualTimestamp;
        managementFeeAssets = currentCollat.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
        managementFeeAssets = managementFeeAssets.min(totalAssets_);
      }

      // Performance fee on the levered-slice basis, net of the management fees charged since the
      // reference last advanced: the held accumulator plus the current interval's charge.
      heldManagementFees_ = _storage.heldManagementFeeAssets;
      totalFeeAssets = managementFeeAssets;
      if (fd.performanceFee > 0 && basis > managementFeeAssets + heldManagementFees_) {
        totalFeeAssets += (basis - managementFeeAssets - heldManagementFees_).mulDiv(fd.performanceFee, BPS);
      }
      // While the reference is held, the current interval's management fee joins the accumulator
      // so the next crystallization deducts it; on advance the pending deduction is consumed (or,
      // for any excess above the basis, forgiven) and the accumulator restarts.
      heldManagementFees_ = advanceReference ? 0 : heldManagementFees_ + managementFeeAssets;
    }

    // Combined no-mint guard: zero fee assets, or fee assets consuming the entire asset base. At
    // equality `convertToShares` against a zero base would mint an inflated share count to the
    // fee recipient, confiscating the pool; the strict-greater case cannot occur under current
    // invariants and is folded in defensively so the later subtraction is safe. `_accrueFees`
    // still refreshes the timestamp (and the reference, per `advanceReference`); nothing is
    // minted, so this interval's management fee does not join the held accumulator either.
    if (totalFeeAssets >= totalAssets_) {
      return (
        totalAssets_,
        totalSupply_,
        currentDebt,
        0,
        0,
        advanceReference,
        advanceReference ? 0 : _storage.heldManagementFeeAssets
      );
    }

    // Convert the combined fee assets first so both components share the same fee-adjusted base
    // (`totalAssets_ - totalFeeAssets`), then split off the management component; the remainder is
    // the performance component.
    performanceFeeShares =
      totalFeeAssets.convertToShares(totalSupply_, totalAssets_ - totalFeeAssets, _storage.virtualShareOffset, false);
    if (managementFeeAssets > 0) {
      managementFeeShares = managementFeeAssets.convertToShares(
        totalSupply_, totalAssets_ - totalFeeAssets, _storage.virtualShareOffset, false
      );
      performanceFeeShares -= managementFeeShares;
    }
  }

  /// @dev Accrues fees (management + performance) and mints shares to the fee recipient.
  ///      Uses `_pendingFees()` to compute the shares, then mints, advances or holds the
  ///      performance reference (lastTotalAssets, lastDebt) per `advanceReference`, and writes
  ///      the timestamp.
  /// @return currentTotalAssets The total assets after fee accrual
  /// @return currentDebt The aggregate debt of non-bad-debt positions, returned so flow callers
  ///         can pass the pre-flow state to `LibStorage.rebaseSnapshot` after moving assets
  function _accrueFees() internal returns (uint256 currentTotalAssets, uint256 currentDebt) {
    uint256 managementFeeShares;
    uint256 performanceFeeShares;
    bool advanceReference;
    uint256 heldManagementFees_;
    (
      currentTotalAssets,, currentDebt, managementFeeShares, performanceFeeShares, advanceReference, heldManagementFees_
    ) = _pendingFees();

    uint256 feeShares = managementFeeShares + performanceFeeShares;

    // Mint fee shares
    if (feeShares > 0) {
      address feeRecipient = LibStorage.positionManagerStorage().feeData.feeRecipient;
      _mint(feeRecipient, feeShares);
      emit IPositionManagerLP.FeesAccrued(feeRecipient, feeShares);
    }

    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    // Advance the reference only on crystallization (positive basis), bootstrap, or empty vault.
    // Holding it on a non-positive basis keeps accrued debt carry and drawdowns inside the basis
    // (high-water mark) instead of writing them off every accrual.
    if (advanceReference) {
      _storage.lastTotalAssets = currentTotalAssets;
      _storage.lastDebt = currentDebt;
    }
    // Persist the held management fee accumulator computed by _pendingFees: cleared on advance,
    // grown by this interval's management fee while the reference is held.
    _storage.heldManagementFeeAssets = heldManagementFees_;
    // The management fee is time-based and independent of the performance reference, so the
    // timestamp advances on every accrual even when the reference is held.
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);
  }

  /// @dev Rebases the performance reference across a flow, reading the post-flow state live.
  ///      Thin wrapper around `LibStorage.rebaseSnapshot` for callers that do not already have
  ///      the post-flow aggregates on hand (burn, rebalance, module add/remove).
  /// @param totalAssetsBefore The total assets before the flow (from `_accrueFees`)
  /// @param debtBefore The aggregate good-debt debt before the flow (from `_accrueFees`)
  /// @param prevSupply The share supply before the flow (including freshly minted fee shares)
  /// @return totalAssetsAfter The total assets after the flow
  function _rebaseReference(uint256 totalAssetsBefore, uint256 debtBefore, uint256 prevSupply)
    internal
    returns (uint256 totalAssetsAfter)
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    uint256 debtAfter;
    uint256 collatAfter;
    (totalAssetsAfter, debtAfter, collatAfter,) = _storage.totalAssets();
    _storage.rebaseSnapshot(
      totalAssetsBefore + debtBefore, debtBefore, prevSupply, collatAfter, debtAfter, ERC20.totalSupply()
    );
  }
}
