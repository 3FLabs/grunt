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
  ///      Management fees are computed first based on time elapsed and total assets and are
  ///      unchanged from the prior mechanism. The performance fee basis is the levered-slice
  ///      performance only: `LTV * Δcollat - Δdebt`, where `LTV = currentDebt / currentCollat`.
  ///      Algebraically the basis simplifies to `lastDebt - mulDiv(currentDebt, lastCollat, currentCollat)`.
  ///      The management fee in assets is then deducted from this basis (matching prior behavior of
  ///      taking performance fees only on gains that exceed the management fee cost), and the
  ///      combined fee assets are converted to shares against the LP-owned post-fee asset base.
  ///
  ///      Bootstrap: when `lastDebt == 0` (sentinel, e.g. immediately after upgrade), the
  ///      performance fee for this period is zero and only the management fee accrues. The
  ///      `lastDebt` slot is seeded in `_accrueFees` from the current debt.
  /// @return totalAssets_ The current total assets across all borrow modules (`collateralQuoted - debt`)
  /// @return totalSupply_ The current total supply of shares (before fee minting)
  /// @return currentDebt The current aggregate debt across all borrow modules
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

    // Single iteration over borrow modules returns both NAV and the aggregate debt of the
    // non-bad-debt positions (the levered-slice debt used by the new basis).
    (totalAssets_, currentDebt) = _storage.totalAssets();

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

    // Management fee: based on time elapsed and total assets — unchanged.
    if (fd.managementFee > 0) {
      uint256 elapsed = block.timestamp - _storage.lastFeeAccrualTimestamp;
      managementFeeAssets = totalAssets_.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
      managementFeeAssets = managementFeeAssets.min(totalAssets_);
    }

    // Performance fee on the levered-slice basis.
    // Skipped when (a) no performance fee is configured, (b) lastDebt sentinel is zero (bootstrap),
    // or (c) currentCollat is zero (degenerate empty vault, no basis to compute).
    if (fd.performanceFee > 0 && _lastDebt > 0) {
      // currentCollat = currentTotalAssets + currentDebt (mirrors how lastCollat is reconstructed,
      // keeping the bad-debt floor symmetric across the two snapshots).
      uint256 currentCollat = totalAssets_ + currentDebt;
      if (currentCollat > 0) {
        uint256 lastCollat = _lastTotalAssets + _lastDebt;
        // basis = lastDebt - mulDiv(currentDebt, lastCollat, currentCollat)
        // Round down on the subtrahend (default mulDiv) so the basis is biased larger — favors
        // the protocol, consistent with conservative-to-protocol rounding elsewhere.
        uint256 hypotheticalDebt = currentDebt.mulDiv(lastCollat, currentCollat);
        if (_lastDebt > hypotheticalDebt) {
          uint256 basis = _lastDebt - hypotheticalDebt;
          if (basis > managementFeeAssets) {
            performanceFeeAssets = (basis - managementFeeAssets).mulDiv(fd.performanceFee, BPS);
          }
        }
      }
    }

    uint256 totalFeeAssets = managementFeeAssets + performanceFeeAssets;
    if (totalFeeAssets == 0) return (totalAssets_, totalSupply_, currentDebt, 0, 0);

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
