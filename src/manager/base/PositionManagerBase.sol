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
  ///      Management fees are computed first based on time elapsed and total assets.
  ///      Performance fees are then charged on the net gain: totalAssets - lastTotalAssets - managementFeeAssets.
  ///      This ensures performance fees are only taken on gains that exceed the management fee cost.
  /// @return totalAssets_ The current total assets across all borrow modules
  /// @return totalSupply_ The current total supply of shares (before fee minting)
  /// @return managementFeeShares The shares that would be minted for management fees
  /// @return performanceFeeShares The shares that would be minted for performance fees
  function _pendingFees()
    internal
    view
    returns (uint256 totalAssets_, uint256 totalSupply_, uint256 managementFeeShares, uint256 performanceFeeShares)
  {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    FeeData memory fd = _storage.feeData;

    totalAssets_ = _storage.totalAssets();
    totalSupply_ = totalSupply();

    if (fd.feeRecipient == address(0) || totalSupply_ == 0) return (totalAssets_, totalSupply_, 0, 0);

    uint256 _lastTotalAssets = _storage.lastTotalAssets;
    uint256 virtualShareOffset_ = _storage.virtualShareOffset;
    uint256 managementFeeAssets = 0;

    // Management fee: based on time elapsed and total assets
    if (fd.managementFee > 0) {
      uint256 elapsed = block.timestamp - _storage.lastFeeAccrualTimestamp;
      managementFeeAssets = totalAssets_.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
      if (managementFeeAssets > 0) {
        managementFeeShares =
          managementFeeAssets.convertToShares(totalSupply_, totalAssets_, virtualShareOffset_, false);
      }
    }

    // Performance fee: based on net gains (after management fee deduction) since last snapshot
    if (fd.performanceFee > 0 && totalAssets_ > _lastTotalAssets + managementFeeAssets) {
      uint256 gains = totalAssets_ - _lastTotalAssets - managementFeeAssets;
      uint256 performanceFeeAssets = gains.mulDiv(fd.performanceFee, BPS);
      if (performanceFeeAssets > 0) {
        performanceFeeShares =
          performanceFeeAssets.convertToShares(totalSupply_, totalAssets_, virtualShareOffset_, false);
      }
    }
  }

  /// @dev Accrues fees (management + performance) and mints shares to the fee recipient.
  ///      Uses `_pendingFees()` to compute the shares, then mints and updates snapshots.
  ///      Returns the current total assets after fee accrual for use in share calculations.
  /// @return currentTotalAssets The total assets after fee accrual
  function _accrueFees() internal returns (uint256 currentTotalAssets) {
    uint256 managementFeeShares;
    uint256 performanceFeeShares;
    (currentTotalAssets,, managementFeeShares, performanceFeeShares) = _pendingFees();

    uint256 feeShares = managementFeeShares + performanceFeeShares;

    // Mint fee shares
    if (feeShares > 0) {
      address feeRecipient = LibStorage.positionManagerStorage().feeData.feeRecipient;
      _mint(feeRecipient, feeShares);
      emit IPositionManagerLP.FeesAccrued(feeRecipient, feeShares);
    }

    // Update snapshot to prevent double-counting performance fees on the same gains
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    _storage.lastTotalAssets = currentTotalAssets;
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);
  }
}
