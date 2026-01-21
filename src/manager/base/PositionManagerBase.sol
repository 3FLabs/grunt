// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManagerLP} from "../../interfaces/manager/base/IPositionManagerLP.sol";
import {FeeData, PositionManagerStorageData} from "../../libs/manager/LibStorage.sol";
import {LibStorage} from "../../libs/manager/LibStorage.sol";
import {LibView} from "../../libs/manager/LibView.sol";
import {BPS, SECONDS_PER_YEAR} from "../../libs/manager/LibConstants.sol";
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

  /// @dev Accrues fees (management + performance) and mints shares to the fee recipient.
  ///      Returns the current total assets after fee accrual for use in share calculations.
  /// @return currentTotalAssets The total assets after fee accrual
  function _accrueFees() internal returns (uint256 currentTotalAssets) {
    PositionManagerStorageData storage _storage = LibStorage.positionManagerStorage();
    FeeData memory fd = _storage.feeData;

    currentTotalAssets = _storage.totalAssets();

    if (fd.feeRecipient == address(0)) {
      _storage.lastTotalAssets = currentTotalAssets;
      // Safe: block.timestamp fits in uint40 for ~35,000 years
      // forge-lint: disable-next-line(unsafe-typecast)
      _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);
      return currentTotalAssets;
    }

    uint256 feeShares = 0;
    uint256 _totalSupply = totalSupply();

    // Management fee: based on time elapsed and total assets
    if (fd.managementFee > 0 && _totalSupply > 0) {
      uint256 elapsed = block.timestamp - _storage.lastFeeAccrualTimestamp;
      // Fee = totalAssets * managementFee * elapsed / (BPS * SECONDS_PER_YEAR)
      uint256 managementFeeAssets = currentTotalAssets.mulDiv(fd.managementFee * elapsed, BPS * SECONDS_PER_YEAR);
      if (managementFeeAssets > 0) {
        feeShares += managementFeeAssets.convertToShares(_totalSupply, currentTotalAssets);
      }
    }

    // Performance fee: based on gains since last snapshot
    if (fd.performanceFee > 0 && currentTotalAssets > _storage.lastTotalAssets && _totalSupply > 0) {
      uint256 gains = currentTotalAssets - _storage.lastTotalAssets;
      uint256 performanceFeeAssets = gains.mulDiv(fd.performanceFee, BPS);
      if (performanceFeeAssets > 0) {
        feeShares += performanceFeeAssets.convertToShares(_totalSupply, currentTotalAssets);
      }
    }

    // Mint fee shares
    if (feeShares > 0) {
      _mint(fd.feeRecipient, feeShares);
      emit IPositionManagerLP.FeesAccrued(fd.feeRecipient, feeShares);
    }

    // Update snapshot to prevent double-counting performance fees on the same gains
    _storage.lastTotalAssets = currentTotalAssets;
    // Safe: block.timestamp fits in uint40 for ~35,000 years
    // forge-lint: disable-next-line(unsafe-typecast)
    _storage.lastFeeAccrualTimestamp = uint40(block.timestamp);

    return currentTotalAssets;
  }
}
