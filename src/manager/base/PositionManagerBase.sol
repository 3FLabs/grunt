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
  ///      Management fees are charged on the aggregate collateral of non-bad-debt positions
  ///      (`currentCollat`), not on the NAV. For a leveraged vault this is materially larger
  ///      than the NAV. The fee assets are still capped at `totalAssets_` so the fee-adjusted
  ///      base used for share conversion remains non-negative.
  ///
  ///      The performance fee basis is the levered-slice performance only:
  ///      `LTV_prev * Δcollat - Δdebt`, where `LTV_prev = lastDebt / lastCollat` is the LTV at the
  ///      previous snapshot. Algebraically the basis simplifies to
  ///      `mulDivUp(lastDebt, currentCollat, lastCollat) - currentDebt`. Anchoring on `LTV_prev` rather
  ///      than `LTV_cur` (a) defines the unlevered baseline at the start of the period (the natural
  ///      comparison for "extra return from leverage"), (b) fixes the multiplier at snapshot time so
  ///      the basis depends on snapshot state plus current debt/collat rather than live LTV, and
  ///      (c) biases the basis larger when collateral appreciates faster than debt accrues — the
  ///      common case — keeping the rounding direction consistent with the rest of the contract.
  ///      The management fee assets are then deducted from this basis before applying the
  ///      performance fee rate.
  ///
  ///      Debt rounding: `lastDebt` and `currentDebt` both originate from
  ///      `IBorrowPosition.totalBorrowed()`, which uses Morpho's `toAssetsDown` (see
  ///      `LibView.totalAssets` for the rationale). The basis therefore inherits Morpho's
  ///      rounding direction: debt is treated here exactly as the underlying market treats
  ///      it, with no additional bias on top of that accounting. As a consequence, the
  ///      performance fee is inherently rounded down.
  ///
  ///      Bootstrap: when `lastDebt == 0` (sentinel, e.g. immediately after upgrade), the
  ///      performance fee for this period is zero and only the management fee accrues. The
  ///      `lastDebt` slot is seeded in `_accrueFees` from the current debt.
  ///
  ///      Bad-debt recovery edge case: when every borrow module is underwater
  ///      (`debt > collateral`), `LibView.totalAssets()` excludes them all, so an accrual snapshots
  ///      `lastTotalAssets = 0` and `lastDebt = 0`. Because `lastDebt == 0` doubles as the bootstrap
  ///      sentinel, the first accrual after a subsequent recovery skips the performance fee and only
  ///      reseeds `lastDebt`. In effect, gains realised across the
  ///      `good -> bad-debt checkpoint -> recovery` transition are not performance-fee charged;
  ///      performance fees only apply to gains after the recovery checkpoint.
  /// @return totalAssets_ The current total assets across all borrow modules (`collateralQuoted - debt`)
  /// @return totalSupply_ The current total supply of shares (before fee minting)
  /// @return currentDebt The current aggregate debt across non-bad-debt positions
  /// @return managementFeeShares The shares that would be minted for management fees
  /// @return performanceFeeShares The shares that would be minted for performance fees
  function _pendingFees()
    internal
    view
    returns (
      uint256 totalAssets_,
      uint256 totalSupply_,
      uint256 currentDebt,
      uint256 managementFeeShares,
      uint256 performanceFeeShares
    )
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    FeeData memory fd = _storage.feeData;

    // Single iteration over borrow modules returns the NAV, the aggregate debt, and the
    // aggregate quoted collateral of non-bad-debt positions in one pass.
    uint256 currentCollat;
    (totalAssets_, currentDebt, currentCollat) = _storage.totalAssets();

    // Use ERC20.totalSupply() to bypass the nonReadReentrant override on the public totalSupply(),
    // since _pendingFees() is reachable from _accrueFees() during a guarded deposit/withdraw/burn.
    totalSupply_ = ERC20.totalSupply();

    if (fd.feeRecipient == address(0) || totalSupply_ == 0) {
      return (totalAssets_, totalSupply_, currentDebt, 0, 0);
    }

    uint256 _lastTotalAssets = _storage.lastTotalAssets;
    uint256 _lastDebt = _storage.lastDebt;
    uint256 virtualShareOffset_ = _storage.virtualShareOffset;
    uint256 managementFeeAssets;
    uint256 performanceFeeAssets;

    // Management fee: charged on the aggregate good-debt collateral, time-weighted, then capped
    // at totalAssets_ so the post-fee asset base stays non-negative for share conversion.
    if (fd.managementFee > 0) {
      uint256 elapsed = block.timestamp - _storage.lastFeeAccrualTimestamp;
      managementFeeAssets = currentCollat.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
      managementFeeAssets = managementFeeAssets.min(totalAssets_);
    }

    // Performance fee on the levered-slice basis.
    // Skipped when (a) no performance fee is configured, (b) lastDebt sentinel is zero (bootstrap),
    // or (c) lastCollat is zero (degenerate empty snapshot, no LTV_prev to anchor on — implied by
    // the lastDebt > 0 guard since lastCollat = lastTotalAssets + lastDebt).
    if (fd.performanceFee > 0 && _lastDebt > 0) {
      uint256 lastCollat = _lastTotalAssets + _lastDebt;
      // basis = mulDiv(lastDebt, currentCollat, lastCollat) - currentDebt
      //       = LTV_prev * currentCollat - currentDebt
      // Round up on the minuend (mulDivUp) so the basis is biased larger — favors the protocol,
      // consistent with conservative-to-protocol rounding elsewhere.
      uint256 scaledLastDebt = _lastDebt.mulDivUp(currentCollat, lastCollat);
      if (scaledLastDebt > currentDebt) {
        uint256 basis = scaledLastDebt - currentDebt;
        if (basis > managementFeeAssets) {
          performanceFeeAssets = (basis - managementFeeAssets).mulDiv(fd.performanceFee, BPS);
        }
      }
    }

    uint256 totalFeeAssets = managementFeeAssets + performanceFeeAssets;
    // Combined no-mint guard. Folds together three cases that all imply a zero share mint:
    //   - `totalFeeAssets == 0`: nothing to mint.
    //   - `totalFeeAssets == totalAssets_`: mgmt fee cap binds exactly; `feeAdjustedAssets` would be
    //     zero, and `convertToShares` against a zero base would mint an inflated share count to the
    //     fee recipient, confiscating the pool.
    //   - `totalFeeAssets > totalAssets_`: should not occur under current invariants
    //     (`managementFeeAssets` is capped at `totalAssets_`, and the perf basis is bounded by
    //     `totalAssets_` because `scaledLastDebt <= currentCollat` whenever `lastDebt <= lastCollat`
    //     and `performanceFee <= BPS`). Folding it in here makes the subsequent subtraction safe
    //     without depending on that invariant chain.
    // `_accrueFees` still refreshes `lastTotalAssets` / `lastDebt` / `lastFeeAccrualTimestamp` so
    // normal accrual resumes next call.
    if (totalFeeAssets >= totalAssets_) return (totalAssets_, totalSupply_, currentDebt, 0, 0);

    uint256 feeAdjustedAssets = totalAssets_ - totalFeeAssets;

    uint256 feeShares = totalFeeAssets.convertToShares(totalSupply_, feeAdjustedAssets, virtualShareOffset_, false);

    if (managementFeeAssets > 0) {
      managementFeeShares =
        managementFeeAssets.convertToShares(totalSupply_, feeAdjustedAssets, virtualShareOffset_, false);
    }
    if (performanceFeeAssets > 0) {
      performanceFeeShares = feeShares - managementFeeShares;
    }
  }

  /// @dev Accrues fees (management + performance) and mints shares to the fee recipient.
  ///      Uses `_pendingFees()` to compute the shares, then mints and writes the snapshot
  ///      (lastTotalAssets, lastDebt) plus the timestamp.
  ///
  ///      Bootstrap semantics: when `lastDebt` was zero on entry, the performance fee is zero
  ///      for this period and `lastDebt` is seeded here with the current debt. From the next
  ///      accrual onward the new basis applies normally.
  /// @return currentTotalAssets The total assets after fee accrual
  function _accrueFees() internal returns (uint256 currentTotalAssets) {
    uint256 currentDebt;
    uint256 managementFeeShares;
    uint256 performanceFeeShares;
    (currentTotalAssets,, currentDebt, managementFeeShares, performanceFeeShares) = _pendingFees();

    uint256 feeShares = managementFeeShares + performanceFeeShares;

    // Mint fee shares
    if (feeShares > 0) {
      address feeRecipient = LibStorage.positionManagerStorage().feeData.feeRecipient;
      _mint(feeRecipient, feeShares);
      emit IPositionManagerLP.FeesAccrued(feeRecipient, feeShares);
    }

    // Update snapshot to prevent double-counting performance fees on the same gains, and to
    // seed/refresh `lastDebt` (zero sentinel becomes the current debt on bootstrap).
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    _storage.lastTotalAssets = currentTotalAssets;
    _storage.lastDebt = currentDebt;
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);
  }
}
